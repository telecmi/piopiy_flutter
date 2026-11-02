// Outbound SIP engine — SIP over WSS via sip_ua (the Dart port of jsSIP, the
// same engine the browser and React Native SDKs use). Registration proves the
// sign-in; outbound calls INVITE through the SBC.
//
// Inbound is NOT handled here — incoming calls arrive the gateway way (push →
// LiveKit room, see livekit_call.dart), exactly like the React Native SDK.

import 'package:sip_ua/sip_ua.dart';

import 'events.dart';

class SipEngine implements SipUaHelperListener {
  SipEngine(this._events, {this.log});

  final PiopiyEvents _events;
  final void Function(String line)? log;

  SIPUAHelper? _helper;
  Call? _call;
  bool _registered = false;
  bool _loginEmitted = false;
  bool _muted = false;

  void _dbg(String line) => log?.call('[sip] $line');

  bool get isRegistered => _registered;
  bool get hasActiveCall => _call != null;

  /// REGISTER to the SBC over WSS. The 'login' event fires on 200 OK — same
  /// signal the JS SDK uses.
  void start({
    required String userId,
    required String password,
    required String region,
    required String displayName,
  }) {
    stop();
    final helper = SIPUAHelper();
    _helper = helper;
    _loginEmitted = false;
    final settings = UaSettings()
      // Same socket the JS/RN SDKs open: wss://<region> on 443, no path.
      ..webSocketUrl = 'wss://$region'
      ..uri = 'sip:$userId@$region'
      ..authorizationUser = userId
      ..password = password
      ..displayName = displayName
      ..userAgent = 'PIOPIY Flutter SDK'
      ..transportType = TransportType.WS
      ..register = true
      ..sessionTimers = false
      ..iceGatheringTimeout = 1200
      ..dtmfMode = DtmfMode.RFC2833;
    settings.webSocketSettings.allowBadCertificate = false;
    helper.addSipUaHelperListener(this);
    helper.start(settings);
  }

  void stop() {
    try {
      _helper?.removeSipUaHelperListener(this);
      _helper?.unregister();
      _helper?.stop();
    } catch (_) {}
    _helper = null;
    _call = null;
    _registered = false;
  }

  /// Outbound call to a number/extension. sip_ua waits for ICE gathering
  /// before sending the INVITE (iceGatheringTimeout above) — the 0.26.1
  /// zero-candidates/488 bug class cannot happen here.
  Future<bool> makeCall(String to, {Map<String, dynamic>? extraHeaders}) async {
    final helper = _helper;
    if (helper == null || !_registered) {
      _events.emit('error', {'code': 1003, 'status': 'Not signed in'});
      return false;
    }
    if (_call != null) {
      _events.emit('error', {'code': 1004, 'status': 'Call already active'});
      return false;
    }
    final headers = <String>[
      if (extraHeaders != null)
        for (final e in extraHeaders.entries) 'X-${e.key}: ${e.value}',
    ];
    return helper.call(
      to,
      voiceOnly: true,
      customOptions: {
        if (headers.isNotEmpty) 'extraHeaders': headers,
      },
    );
  }

  void hangup() {
    try {
      _call?.hangup();
    } catch (_) {}
  }

  void setMuted(bool muted) {
    _muted = muted;
    try {
      if (muted) {
        _call?.mute(true, false);
      } else {
        _call?.unmute(true, false);
      }
      _events.emit(muted ? 'mute' : 'unMute', null);
    } catch (_) {}
  }

  bool get isMuted => _muted;

  void sendDtmf(String tones) {
    try {
      _call?.sendDTMF(tones);
    } catch (_) {}
  }

  // ---- SipUaHelperListener ----

  @override
  void registrationStateChanged(RegistrationState state) {
    _dbg('registration: ${state.state}');
    switch (state.state) {
      case RegistrationStateEnum.REGISTERED:
        _registered = true;
        if (!_loginEmitted) {
          _loginEmitted = true;
          _events.emit('login', {'code': 200, 'status': 'ok'});
        }
        break;
      case RegistrationStateEnum.REGISTRATION_FAILED:
        _registered = false;
        _events.emit('loginFailed', {
          'code': 401,
          'status': state.cause?.cause ?? 'registration failed'
        });
        break;
      case RegistrationStateEnum.UNREGISTERED:
        if (_registered) {
          _registered = false;
          _events.emit('logout', {'code': 200});
        }
        break;
      default:
        break;
    }
  }

  @override
  void callStateChanged(Call call, CallState state) {
    _dbg('call ${call.id}: ${state.state}');
    switch (state.state) {
      case CallStateEnum.CALL_INITIATION:
        _call = call;
        _muted = false;
        _events.emit('trying', {'id': call.id, 'to': call.remote_identity});
        break;
      case CallStateEnum.PROGRESS:
        _events.emit('ringing', {'id': call.id});
        break;
      case CallStateEnum.CONFIRMED:
        _events.emit('answered', {'id': call.id});
        break;
      case CallStateEnum.ENDED:
        _call = null;
        _events.emit('ended', {'id': call.id});
        break;
      case CallStateEnum.FAILED:
        _call = null;
        _events.emit(
            'hangup', {'id': call.id, 'cause': state.cause?.cause ?? 'failed'});
        break;
      default:
        break;
    }
  }

  @override
  void transportStateChanged(TransportState state) {
    _dbg('transport: ${state.state}');
  }

  @override
  void onNewMessage(SIPMessageRequest msg) {}

  @override
  void onNewNotify(Notify ntf) {}

  @override
  void onNewReinvite(ReInvite event) {}
}
