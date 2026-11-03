// SIP engine — SIP over WSS via sip_ua (the Dart port of jsSIP, the engine
// the browser and React Native SDKs use). The Flutter port of userAgent.js +
// session.native.js: registration proves the sign-in, outbound calls INVITE
// through the SBC, and every guard, error code and event payload matches the
// React Native SDK.
//
// Inbound on mobile is push-delivered (livekit_call.dart): the SBC never
// INVITEs a mobile agent. A SIP INVITE that does arrive is still surfaced as
// 'inComingCall' and can be answered from the app, like the RN SDK.

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart' show Level;
import 'package:sip_ua/sip_ua.dart';
// ignore: implementation_imports
import 'package:sip_ua/src/event_manager/internal_events.dart'
    show EventNewDTMF, EventPeerConnection;

import 'call_audio.dart';
import 'events.dart';
import 'rtc_monitor.dart';

/// TeleCMI's STUN server — the ICE server every PIOPIY SDK offers.
const List<Map<String, String>> kPiopiyIceServers = [
  {'urls': 'stun:stunind.telecmi.com'},
];

class SipEngine implements SipUaHelperListener {
  SipEngine(this._events, this._audio, {this.log});

  final PiopiyEvents _events;
  final CallAudio _audio;
  final void Function(String line)? log;

  /// Fired on each transition to REGISTERED (the facade re-checks the push
  /// token registration there, like the RN SDK's 'login' hook).
  void Function()? onRegistered;

  SIPUAHelper? _helper;
  UaSettings? _settings;
  bool _debug = false;

  Call? _call;
  bool _registered = false;
  bool _connected = false;
  bool _stopping = false;
  bool _answeredEmitted = false;
  String? _sipCallId; // SIP Call-ID of the live session ('call_id')
  String? _cmiCallId; // TeleCMI call id ('call_ID')
  Timer? _netStatsTimer;
  Timer? _watchdogTimer;
  RtcMonitor? _rtc;

  void _dbg(String line) => log?.call('[sip] $line');

  void _error(int code, String status) =>
      _events.emit('error', {'code': code, 'status': status});

  bool get isRegistered => _registered;
  bool get isConnected => _helper?.connected ?? false;
  bool get hasActiveCall => _call != null;
  bool get hasIncomingRinging =>
      _call != null &&
      _call!.direction == Direction.incoming &&
      !_call!.session.isEstablished() &&
      !_call!.session.isEnded();

  // ---------------------------------------------------------------- session

  /// REGISTER to the SBC over WSS. 'login' fires on 200 OK — the same signal
  /// the JS SDK uses.
  void start({
    required String userId,
    required String password,
    required String region,
    String? displayName,
    required int registerExpires,
    required bool debug,
  }) {
    if (_helper != null && _registered) {
      _error(1001, 'Please logout before you login');
      return;
    }
    _shutdownHelper();
    _debug = debug;
    final settings = UaSettings()
      // Same socket the JS/RN SDKs open: wss://<region> on 443, no path.
      ..webSocketUrl = 'wss://$region'
      ..uri = 'sip:$userId@$region'
      ..authorizationUser = userId
      ..password = password
      ..displayName = displayName
      // The RN SDK's mobile User-Agent — the SBC identifies mobile clients by it.
      ..userAgent = 'piopiy_mobile'
      ..transportType = TransportType.WS
      ..register = true
      // A short registration clears a killed app's stale contact quickly.
      ..register_expires = registerExpires
      ..sessionTimers = false
      // sip_ua releases the SDP this long after the FIRST candidate (or at
      // gathering complete). flutter_webrtc reads the native description, so
      // the INVITE always carries the gathered candidates.
      ..iceGatheringTimeout = 1200
      ..dtmfMode = DtmfMode.RFC2833
      ..iceServers = kPiopiyIceServers;
    settings.webSocketSettings.allowBadCertificate = false;
    _settings = settings;
    _dbg('start(): user $userId → wss://$region, register_expires: $registerExpires');
    _startHelper(settings);
  }

  void _startHelper(UaSettings settings) {
    final helper = SIPUAHelper();
    helper.loggingLevel = _debug ? Level.debug : Level.warning;
    _helper = helper;
    helper.addSipUaHelperListener(this);
    helper.start(settings);
  }

  void _shutdownHelper() {
    final helper = _helper;
    _helper = null;
    if (helper == null) return;
    helper.removeSipUaHelperListener(this);
    try {
      if (helper.registered) helper.unregister();
    } catch (_) {}
    try {
      helper.stop();
    } catch (_) {}
  }

  /// Unregister and stop. Emits 'logout' once when a registration existed;
  /// returns whether it did.
  Future<bool> stop() async {
    final helper = _helper;
    if (helper == null) return false;
    final wasRegistered = _registered;
    _stopping = true;
    try {
      _call?.hangup();
    } catch (_) {}
    _clearCall();
    try {
      if (helper.registered) await helper.unregister();
    } catch (_) {}
    helper.removeSipUaHelperListener(this);
    try {
      helper.stop();
    } catch (_) {}
    if (identical(_helper, helper)) _helper = null;
    _registered = false;
    _connected = false;
    _stopping = false;
    if (wasRegistered) {
      _events.emit('logout', {'code': 200, 'status': 'logout successfully'});
    }
    return wasRegistered;
  }

  void reRegister() {
    final helper = _helper;
    if (helper != null && !_registered) helper.register();
  }

  /// The notify socket saw the transport drop (network change): reconnect
  /// now instead of waiting for sip_ua's recovery backoff. A live call is
  /// left alone — restarting the UA would end it.
  void onNetChanged() {
    final settings = _settings;
    if (settings == null || !_registered || _call != null) return;
    _dbg('network changed → reconnecting the SIP transport');
    _shutdownHelper();
    _registered = false;
    _startHelper(settings);
  }

  // --------------------------------------------------------------- outbound

  /// Outbound call to a number/extension.
  Future<void> makeCall(
    String to, {
    String? extraParam,
    Map<String, dynamic>? extraHeaders,
  }) async {
    final helper = _helper;
    if (helper == null || !_registered) {
      _dbg('make() BLOCKED — not registered (login first)');
      _error(1002, 'Please login to call');
      return;
    }
    if (_call != null) {
      _error(1002, 'already in call');
      return;
    }
    final headers = <String>[
      if (extraParam != null) 'X-cmi-extra_param:$extraParam',
      if (extraHeaders != null)
        for (final e in extraHeaders.entries) 'X-${e.key}: ${e.value}',
    ];
    await _audio.startSip();
    _dbg('make(): dialing $to');
    final ok = await helper.call(to, voiceOnly: true, headers: headers);
    if (!ok) {
      await _audio.stopSip();
      _error(1002, 'Please login to call');
      return;
    }

    // No SIP response at all within 5 s → tell the app the network is slow;
    // within 10 s → give up and restart the UA (the RN auto-hangup).
    _netStatsTimer?.cancel();
    _netStatsTimer = Timer(const Duration(seconds: 5), () {
      if (_isInviteSent) {
        _dbg('make(): 5 s and no SIP response → NETStats 408');
        _events.emit('NETStats', {'code': 408, 'msg': 'Request timeout'});
      }
    });
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 10), () {
      if (!_isInviteSent) return;
      _dbg('make(): 10 s WATCHDOG — no response to INVITE → terminating + restarting UA');
      try {
        _call?.hangup();
      } catch (_) {}
      final settings = _settings;
      if (settings != null) {
        _shutdownHelper();
        _registered = false;
        _startHelper(settings);
      }
    });
  }

  bool get _isInviteSent {
    final call = _call;
    return call != null && call.session.status == 1; // STATUS_INVITE_SENT
  }

  // ---------------------------------------------------------------- inbound

  /// Answer a SIP INVITE (foreground SIP inbound).
  Future<void> answer() async {
    final helper = _helper;
    if (helper == null || !_registered) {
      _error(1002, 'Please login');
      return;
    }
    final call = _call;
    if (call == null) {
      _error(1002, 'call not found');
      return;
    }
    if (call.session.isEstablished()) {
      _error(1002, 'call already answered');
      return;
    }
    await _audio.startSip();
    final options = helper.buildCallOptions(true);
    call.answer(options);
  }

  void reject() {
    final call = _call;
    if (call == null || call.session.isEnded()) return; // nothing to reject
    call.hangup();
  }

  void terminate() {
    if (!_requireLogin()) return;
    final call = _call;
    if (call == null || call.session.isEnded()) return; // nothing to terminate
    call.hangup();
  }

  // --------------------------------------------------------------- controls

  bool _requireLogin() {
    if (_helper != null && !_registered) {
      _error(1002, 'Please login');
      return false;
    }
    return true;
  }

  /// Guards shared by hold/mute/dtmf: a live, established session.
  Call? _established(String notAllowed) {
    if (!_requireLogin()) return null;
    final call = _call;
    if (call == null) {
      _error(1002, 'call not found');
      return null;
    }
    if (!call.session.isEstablished()) {
      _error(1002, notAllowed);
      return null;
    }
    return call;
  }

  void sendDtmf(String tone) {
    if (!_requireLogin()) return;
    if (tone.isEmpty) {
      _error(1005, 'invalid dtmf type');
      return;
    }
    final call = _established('dtmf not allowed');
    call?.sendDTMF(tone);
  }

  void hold() {
    final call = _established('hold not allowed');
    if (call == null) return;
    if (call.session.isOnHold()['local'] == true) {
      _error(1002, 'call already in hold');
      return;
    }
    call.hold();
  }

  void unhold() {
    final call = _established('hold not allowed');
    if (call == null) return;
    if (call.session.isOnHold()['local'] != true) {
      _error(1002, 'call not in hold');
      return;
    }
    call.unhold();
  }

  void mute() {
    final call = _established('mute not allowed');
    if (call == null) return;
    if (call.session.isMuted()['audio'] == true) {
      _error(1002, 'call already in mute');
      return;
    }
    call.mute(true, false);
  }

  void unmute() {
    final call = _established('mute not allowed');
    if (call == null) return;
    if (call.session.isMuted()['audio'] != true) {
      _error(1002, 'call not in mute');
      return;
    }
    call.unmute(true, false);
  }

  bool get isMuted {
    final call = _call;
    if (!_registered || call == null || !call.session.isEstablished()) {
      return false;
    }
    return call.session.isMuted()['audio'] == true;
  }

  bool get isOnHold {
    final call = _call;
    if (!_registered || call == null || !call.session.isEstablished()) {
      return false;
    }
    return call.session.isOnHold()['local'] == true;
  }

  /// SIP Call-ID of the live call, or null.
  String? getCallId() {
    if (!_registered || _call == null) return null;
    return _sipCallId;
  }

  /// TeleCMI call id of the live call (X-Call-ID / X-cmi-uuid for inbound,
  /// the Call-ID for outbound), or null.
  String? getCallID() {
    final call = _call;
    if (!_registered || call == null) return null;
    if (!call.session.isEstablished() && !call.session.isInProgress()) {
      return null;
    }
    return _cmiCallId;
  }

  void _restartIce() {
    final call = _call;
    if (call == null || call.session.isEnded()) return;
    call.renegotiate(options: {
      'mediaConstraints': {'audio': true, 'video': false},
      'rtcOfferConstraints': {
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': false,
          'IceRestart': true,
        },
        'optional': [],
      },
    });
  }

  // ----------------------------------------------------------- call state

  void _bindCall(Call call) {
    _call = call;
    _answeredEmitted = false;
    final rtc = RtcMonitor(_events, restartIce: _restartIce, log: log);
    _rtc = rtc;
    final pc = call.peerConnection;
    if (pc != null) rtc.attach(pc);
    call.session.on(EventPeerConnection(null), (EventPeerConnection e) {
      final p = e.peerConnection;
      if (p != null && identical(_call, call)) rtc.attach(p);
    });
    call.session.on(EventNewDTMF(), (EventNewDTMF e) {
      _events.emit('dtmf', {
        'code': 200,
        'dtmf': e.dtmf?.tone ?? '',
        'type': e.originator == Originator.local ? 'incoming' : 'outgoing',
      });
    });
  }

  void _clearCall() {
    _netStatsTimer?.cancel();
    _netStatsTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _rtc?.dispose();
    _rtc = null;
    _call = null;
    _answeredEmitted = false;
    _sipCallId = null;
    _cmiCallId = null;
  }

  void _endCall() {
    _clearCall();
    _audio.stopSip();
  }

  void _onIncoming(Call call) {
    // One call at a time: a second INVITE is turned away.
    if (_call != null) {
      _dbg('second inbound INVITE while busy — rejecting');
      try {
        call.hangup({'status_code': 486, 'reason_phrase': 'Busy Here'});
      } catch (_) {}
      return;
    }
    _bindCall(call);
    final request = call.session.request;
    String header(String name) {
      try {
        final v = request?.getHeader(name) ?? request?.getHeader(name.toLowerCase());
        return v == null ? '' : v.toString();
      } catch (_) {
        return '';
      }
    }

    final cmiUuid = header('X-cmi-uuid');
    final teamName = header('X-Team-Name');
    final toNumber = header('X-To-Number');
    final xCallId = header('X-Call-ID');
    final transferFrom = header('X-Transfer-From');
    final transfer = RegExp(r'^(true|1|yes)$', caseSensitive: false)
        .hasMatch(header('X-Transfer'));
    String? sipCallId;
    try {
      sipCallId = request?.call_id as String?;
    } catch (_) {}
    _sipCallId = sipCallId;
    _cmiCallId = xCallId.isNotEmpty ? xCallId : (cmiUuid.isNotEmpty ? cmiUuid : null);

    final displayName = call.remote_display_name;
    final payload = <String, dynamic>{
      'from': (displayName != null && displayName.isNotEmpty) ? displayName : 'unknown',
      if (teamName.isNotEmpty) 'team_name': teamName,
      if (toNumber.isNotEmpty) 'to_number': toNumber,
      if (transferFrom.isNotEmpty) 'transfer_from': transferFrom,
      'transfer': transfer,
    };
    final finalCallId = xCallId.isNotEmpty ? xCallId : (sipCallId ?? '');
    if (finalCallId.isNotEmpty) payload['call_id'] = finalCallId;
    _dbg('INCOMING SIP from ${payload['from']}');
    _events.emit('inComingCall', payload);
  }

  void _emitAnswered() {
    if (_answeredEmitted) return;
    _answeredEmitted = true;
    _netStatsTimer?.cancel();
    _watchdogTimer?.cancel();
    _events.emit('answered', {'code': 200, 'status': 'answered'});
  }

  // ---- SipUaHelperListener ----

  @override
  void registrationStateChanged(RegistrationState state) {
    _dbg('registration: ${state.state} ${state.cause ?? ''}');
    switch (state.state) {
      case RegistrationStateEnum.REGISTERED:
        if (!_registered) {
          _registered = true;
          _events.emit('login', {'code': 200, 'status': 'login successfully'});
          onRegistered?.call();
        }
        break;
      case RegistrationStateEnum.UNREGISTERED:
        if (_registered) {
          _registered = false;
          if (!_stopping) {
            _events.emit('logout', {'code': 200, 'status': 'logout successfully'});
          }
        }
        break;
      case RegistrationStateEnum.REGISTRATION_FAILED:
        _registered = false;
        final code = state.cause?.status_code;
        if (code == 401) {
          _events.emit('loginFailed', {'code': 401, 'status': 'invalid user'});
        } else if (code == 503) {
          _events.emit('loginFailed', {'code': 405, 'status': 'too many connections'});
        } else if (code == 407) {
          _events.emit('loginFailed', {'code': 407, 'status': 'invalid IP'});
        }
        break;
      default:
        break;
    }
  }

  @override
  void transportStateChanged(TransportState state) {
    _dbg('transport: ${state.state}');
    switch (state.state) {
      case TransportStateEnum.CONNECTED:
        if (!_connected) {
          _connected = true;
          _events.emit('connected', {'code': 200, 'status': 'connected'});
        }
        break;
      case TransportStateEnum.DISCONNECTED:
        if (_connected) {
          _connected = false;
          _events.emit('disconnected', {'code': 1000, 'status': 'disconnected'});
        }
        break;
      default:
        break;
    }
  }

  @override
  void callStateChanged(Call call, CallState state) {
    _dbg('call ${call.id}: ${state.state}');
    final ours = identical(_call, call);
    switch (state.state) {
      case CallStateEnum.CALL_INITIATION:
        if (call.direction == Direction.incoming) {
          _onIncoming(call);
        } else {
          _bindCall(call);
          String? callId;
          try {
            callId = call.session.request?.call_id as String?;
          } catch (_) {}
          _sipCallId = callId;
          _cmiCallId = callId;
          _events.emit('trying', {'code': 100, 'status': 'trying', 'type': 'outgoing'});
        }
        break;
      case CallStateEnum.PROGRESS:
        if (!ours) return;
        _events.emit('ringing', {
          'code': 183,
          'status': 'ringing',
          'type': state.originator == Originator.local ? 'incoming' : 'outgoing',
        });
        break;
      case CallStateEnum.ACCEPTED:
      case CallStateEnum.CONFIRMED:
        if (ours) _emitAnswered();
        break;
      case CallStateEnum.HOLD:
        if (!ours) return;
        _events.emit('hold', {
          'code': 200,
          'status': 'call on hold',
          'whom': state.originator == Originator.local ? 'myself' : 'other',
        });
        break;
      case CallStateEnum.UNHOLD:
        if (!ours) return;
        _events.emit('unhold', {
          'code': 200,
          'status': 'call on active',
          'whom': state.originator == Originator.local ? 'myself' : 'other',
        });
        break;
      case CallStateEnum.STREAM:
        if (!ours || state.originator != Originator.remote) return;
        final MediaStream? stream = state.stream;
        if (stream != null) {
          _events.emit('callStream', {'code': 200, 'status': stream});
        }
        break;
      case CallStateEnum.FAILED:
        if (!ours) return;
        final cause = state.cause;
        _endCall();
        if (cause?.cause == 'User Denied Media Access') {
          _events.emit('mediaFailed', {'code': 415, 'status': 'user media failed'});
        }
        if (cause?.status_code == 407) {
          _events.emit('loginFailed', {'code': 407, 'status': 'invalid user'});
        }
        if (state.originator == Originator.local) {
          _events.emit('hangup', {'code': cause?.status_code ?? 200, 'status': 'call hangup'});
        } else {
          _events.emit('ended', {
            'code': cause?.status_code ?? 200,
            'status': cause?.reason_phrase ?? 'call ended',
          });
        }
        break;
      case CallStateEnum.ENDED:
        if (!ours) return;
        _endCall();
        if (state.originator == Originator.local) {
          _events.emit('hangup', {'code': 200, 'status': 'call hangup'});
        } else {
          _events.emit('ended', {'code': 200, 'status': 'call ended'});
        }
        break;
      default:
        break;
    }
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {}

  @override
  void onNewNotify(Notify ntf) {}

  @override
  void onNewReinvite(ReInvite event) {}
}
