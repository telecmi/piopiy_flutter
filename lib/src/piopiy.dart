// PIOPIY — the SDK facade. Method-for-method and event-for-event parity with
// @telecmi/piopiy-native (React Native) — see the README's API table.
//
// Architecture (same as React Native):
//   OUTBOUND — SIP over WSS (sip_ua, the Dart jsSIP port).
//   INBOUND  — push-delivered LiveKit room: the native layer rings the OS
//              call UI (CallKit / Telecom), and on answer the SDK joins the
//              room carried by the push payload. Retryable by design.
//   NOTIFY   — the TeleCMI notify socket (transfer, recording, forced
//              sign-out), opened with the REST token after login.

import 'dart:async';
import 'dart:io' show Platform;

import 'call_audio.dart';
import 'events.dart';
import 'livekit_call.dart';
import 'native_call.dart';
import 'options.dart';
import 'push_manager.dart';
import 'rest.dart';
import 'sip_engine.dart';
import 'socket.dart';

class Piopiy extends PiopiyEvents implements InboundCallHost {
  Piopiy([PiopiyOptions options = const PiopiyOptions()]) : _options = options {
    _rest = PiopiyRest(apiBase: options.apiBase)..log = _dbg;
    _audio = CallAudio(log: _dbg);
    _native = NativeCall(log: _dbg);
    _sip = SipEngine(this, _audio, log: _dbg)
      ..onRegistered = () => _push.ensureRegistered();
    _livekit = LiveKitEngine(this, _audio, this,
        ringTime: options.ringTime, fallbackUrl: options.livekitUrl, log: _dbg);
    _push = PushManager(
      events: this,
      native: _native,
      rest: _rest,
      autoBackgroundPush: options.autoBackgroundPush,
      log: _dbg,
    )..onCallPush = (data) => handleIncomingPush(data);
    // Native handlers are wired before anything else: a killed-state launch
    // replays the call push and the user's Answer as soon as Dart attaches.
    _wireNative();
    _native.setup(_setupArgs());
    if (options.autoPushToken) _push.start();
  }

  /// SDK version.
  static const String version = '0.2.0';

  final PiopiyOptions _options;
  late final PiopiyRest _rest;
  late final CallAudio _audio;
  late final NativeCall _native;
  late final SipEngine _sip;
  late final LiveKitEngine _livekit;
  late final PushManager _push;
  SocketCMI? _socket;

  String? _authToken;
  String _region = 'sbcsg.telecmi.com';

  String? _parkedAnswerUuid; // native answer that arrived before the invite
  DateTime? _parkedAnswerAt;
  final List<String> _answeredHere = []; // dedupe native/app answer echoes
  final List<String> _handledCancels = []; // a cancel can arrive twice
  final List<String> _missedReported = [];

  static const Duration _maxParkedAnswerAge = Duration(seconds: 60);

  void _dbg(String line) {
    if (_options.debug) {
      // ignore: avoid_print
      print('[piopiy] $line');
    }
    emit('log', line);
  }

  static void _remember(List<String> list, String uuid) {
    if (list.contains(uuid)) return;
    list.add(uuid);
    if (list.length > 20) list.removeAt(0);
  }

  Map<String, dynamic> _setupArgs() => {
        'appName': _options.callKeep.ios.appName ?? _options.name,
        'accountLabel': _options.name,
        'ringTime': _options.ringTime,
        'autoPushToken': _options.autoPushToken,
        'ios': _options.callKeep.ios.toMap(),
        'android': _options.callKeep.android.toMap(),
      };

  // ---------------------------------------------------------------- session

  /// Sign in: SIP REGISTER to the SBC (fires 'login' / 'loginFailed') and, in
  /// parallel, the REST token fetch that powers push registration, the notify
  /// socket and [getAuthToken]. [region] is the SBC host (default
  /// `sbcsg.telecmi.com`).
  Future<void> login(String userId, String password, [String? region]) async {
    if (_sip.isRegistered) {
      emit('error', {'code': 1001, 'status': 'Please logout before you login'});
      return;
    }
    _push.onLoginStarted();
    _region = (region == null || region.isEmpty) ? 'sbcsg.telecmi.com' : region;
    // Android: Firebase may not have been initialized at construction.
    if (_options.autoPushToken) _push.start();

    _sip.start(
      userId: userId,
      password: password,
      region: _region,
      displayName: _options.name,
      registerExpires: _options.registerExpires,
      debug: _options.debug,
    );

    final res = await _rest.getToken(userId, password);
    if (res['code'] == 200) {
      final token = res['token'] as String;
      _authToken = token;
      _socket?.dispose();
      _socket = SocketCMI(
        token,
        onTransfer: _onTransfer,
        onRecord: (data) => emit('record', data),
        onForceLogout: (data) {
          logout();
          emit('sbc_logout', data);
        },
        onNetChanged: () {
          emit('net_changed', {'code': 400, 'msg': 'network changed'});
          _sip.onNetChanged();
        },
        log: _dbg,
      );
      _push.setAuth(token, _region);
    } else {
      emit('loginFailed', {'code': 407, 'status': 'Token generation failed'});
      _push.authFailed();
    }
  }

  /// Sign out. The device push token is unregistered from TeleCMI first
  /// (retried once), so this device stops being woken for calls; then the
  /// session is torn down. Returns the unregister response (`{code: 200}` on
  /// success) — the React Native SDK's logout callback.
  Future<Map<String, dynamic>> logout() async {
    final res = await _push.onLogout();
    _livekit.end('logout');
    _socket?.dispose();
    _socket = null;
    final emitted = await _sip.stop();
    if (!emitted) emit('logout', {'code': 200, 'status': 'logout successfully'});
    return res;
  }

  /// The TeleCMI REST auth token of the signed-in agent (the /user/login
  /// bearer) — for apps calling TeleCMI REST APIs themselves. null until the
  /// 'login' flow completes; the next login replaces it.
  String? getAuthToken() => _authToken;

  /// Re-send the SIP REGISTER if the registration lapsed.
  void reRegister() => _sip.reRegister();

  bool isLogedIn() => _sip.isRegistered;

  /// The SIP transport (WSS) is connected.
  bool isConnected() => _sip.isConnected;

  // ------------------------------------------------------------ push tokens

  /// Register a device push token with TeleCMI (only needed with
  /// `autoPushToken: false`). Queued until login completes. Returns the
  /// response (`{code: 200, ...}`; 1006 bad args, 1007 request failed).
  Future<Map<String, dynamic>> registerToken({
    required String provider,
    required String token,
    String? platform,
  }) =>
      _push.registerToken(provider: provider, token: token, platform: platform);

  /// Remove the registered push token (e.g. Do-Not-Disturb).
  Future<Map<String, dynamic>> unregisterToken() => _push.unregisterToken();

  /// Android: register the FCM background handler for call pushes that
  /// arrive while the app is backgrounded or killed. Done automatically
  /// (`autoBackgroundPush`); safe to call again; no-op on iOS.
  bool registerBackgroundPushHandler() => _push.registerBackgroundHandler();

  /// Receive pushes that are not TeleCMI calls (your app's own FCM data
  /// messages). Also emitted as the 'otherPush' event.
  void onOtherPush(void Function(Map<String, dynamic> data) callback) {
    _push.onOtherPush = callback;
  }

  /// Hand a call push to the SDK — only needed when your app owns the push
  /// pipeline. Forward the raw data payload:
  ///  - invite `{uuid, room, token, url, from, ...}` rings ('inComingCall')
  ///  - cancel `{type: 'cancel_call', uuid}` — the caller hung up while
  ///    ringing; dismisses the ring and emits 'missedCall'.
  /// Returns true when the push was accepted.
  bool handleIncomingPush(Map<String, dynamic> info) {
    final type = info['type'];
    final uuid = (info['uuid'] ?? info['call_id'] ?? '').toString().toLowerCase();

    // Explicitly signed out: refuse invites — the payload alone (room + JWT)
    // could join the call. Dismiss a natively reported ring. Cancels still
    // process — dismissing is always safe.
    if (_push.signedOut && uuid.isNotEmpty && type != 'cancel_call') {
      _dbg('invite push refused — user is signed out');
      _native.endCall(uuid, reason: EndReason.remote);
      emit('callkeepCancel', {'uuid': uuid, 'reason': 'signed out'});
      return false;
    }

    if (type == 'cancel_call') {
      if (uuid.isEmpty) return false;
      // The same cancel can arrive twice; the second must not log a second
      // missed call.
      if (_handledCancels.contains(uuid)) return true;
      _remember(_handledCancels, uuid);
      // This device answered: the cancel is our own multi-device dismissal
      // (or a duplicate of the room teardown) — never end the call for it.
      if (_answeredHere.contains(uuid)) return true;
      if (_parkedAnswerUuid == uuid) _parkedAnswerUuid = null;
      if (_livekit.isCall(uuid)) {
        _livekit.end('caller cancelled');
      } else {
        // Nothing pending in the engine (cold start — only the native ring
        // happened): dismiss the native UI directly.
        _native.endCall(uuid, reason: EndReason.missed);
        emit('callkeepCancel', {'uuid': uuid, 'reason': 'caller cancelled'});
        _emitMissed(uuid, (info['from'] ?? info['caller'])?.toString(), 'cancelled');
      }
      return true;
    }

    final call = InboundCall.fromPayload(info, fallbackUrl: _options.livekitUrl);
    if (call == null) {
      _dbg('invite rejected — uuid, room and token are required');
      // Unusable payload: don't leave a natively reported ring up with
      // nothing behind it.
      if (uuid.isNotEmpty) _native.endCall(uuid, reason: EndReason.remote);
      return false;
    }
    if (_livekit.isCall(call.uuid)) return true; // duplicate delivery
    if (!_livekit.setPending(call)) return false;

    // A native Answer that landed before the payload reached Dart (cold
    // start): complete it now.
    if (_parkedAnswerUuid == call.uuid) {
      _parkedAnswerUuid = null;
      final age = DateTime.now().difference(_parkedAnswerAt ?? DateTime.now());
      if (age > _maxParkedAnswerAge) {
        _dbg('stale parked answer dropped: ${call.uuid}');
        _livekit.end('answer expired');
        return true;
      }
      _dbg('completing parked answer: ${call.uuid}');
      _remember(_answeredHere, call.uuid);
      _connectInbound();
      return true;
    }

    // Android has no native pre-report: ring the OS call UI now with the
    // push's uuid, so answer/cancel/end all correlate. (iOS rang from the
    // PushKit callback; a payload the background isolate rang carries
    // _alreadyRang.)
    if (Platform.isAndroid && info['_alreadyRang'] != true) {
      _native.displayIncomingCall(
        uuid: call.uuid,
        handle: call.from,
        callerName: call.display,
        payload: info,
      );
    }
    return true;
  }

  /// Deprecated alias of [handleIncomingPush].
  @Deprecated('Renamed to handleIncomingPush().')
  bool livekitIncoming(Map<String, dynamic> info) => handleIncomingPush(info);

  void _emitMissed(String uuid, String? from, String reason) {
    if (_missedReported.contains(uuid)) return;
    _remember(_missedReported, uuid);
    emit('missedCall', {
      'uuid': uuid,
      'from': from,
      'reason': reason,
      'transport': 'push',
    });
  }

  // ---------------------------------------------------------------- calls

  /// Dial a number/extension through the SBC. [extraParam] is delivered to
  /// the platform as the X-cmi-extra_param header (the React Native SDK's
  /// `extra_param`).
  Future<void> call(
    String to, {
    String? extraParam,
    Map<String, dynamic>? extraHeaders,
  }) async {
    if (to.trim().isEmpty) {
      emit('error', {'code': 1002, 'status': 'Invalid type to call'});
      return;
    }
    await _sip.makeCall(to.trim(), extraParam: extraParam, extraHeaders: extraHeaders);
  }

  /// Answer the ringing call from the app's UI. (Answers on the native call
  /// screen arrive automatically — nothing to call.)
  Future<void> answer() async {
    final call = _livekit.pending;
    if (call != null) {
      _remember(_answeredHere, call.uuid);
      // Flip the native call to answered too — iOS: CallKit leaves its
      // ringing UI and activates the audio session.
      await _native.answerCall(call.uuid);
      await _connectInbound();
      return;
    }
    if (_sip.hasIncomingRinging) {
      await _sip.answer();
      return;
    }
    emit('error', {'code': 1002, 'status': 'call not found'});
  }

  /// Decline the ringing call on this device. The caller keeps ringing other
  /// devices until the platform's no-answer timeout routes the call onward.
  Future<void> reject() async {
    if (_livekit.hasPending()) {
      _livekit.end('rejected');
      return;
    }
    _sip.reject();
  }

  /// Hang up the live call (outbound SIP or inbound), or decline a ringing
  /// one.
  Future<void> terminate() async {
    if (_livekit.isCall()) {
      _livekit.end('terminate');
      return;
    }
    _sip.terminate();
  }

  Future<void> _connectInbound() async {
    final call = _livekit.pending;
    if (call == null) return;
    final ok = await _livekit.answer();
    if (ok) await _native.setCallActive(call.uuid);
  }

  // -------------------------------------------------------------- controls

  /// Send DTMF tones on the live outbound call.
  void sendDtmf(String tone) => _sip.sendDtmf(tone);

  void hold() => _sip.hold();
  void unHold() => _sip.unhold();
  bool onHold() => _sip.isOnHold;

  Future<void> mute() => _setMuted(true);
  Future<void> unMute() => _setMuted(false);

  Future<void> _setMuted(bool muted, {bool fromNative = false}) async {
    final active = _livekit.active;
    if (active != null) {
      if (_livekit.isMuted == muted) return;
      final ok = await _livekit.setMuted(muted);
      // Keep the native call screen's mute button in sync (iOS).
      if (ok && !fromNative) await _native.setMuted(active.uuid, muted);
      return;
    }
    if (muted) {
      _sip.mute();
    } else {
      _sip.unmute();
    }
  }

  bool onMute() => _livekit.active != null ? _livekit.isMuted : _sip.isMuted;

  /// Route call audio to the loudspeaker (true) or earpiece (false).
  Future<bool> speaker(bool on) async {
    final ok = await _audio.setSpeaker(on);
    final active = _livekit.active;
    if (active != null && Platform.isAndroid) {
      // Telecom owns the route of an OS-managed call; this also updates the
      // OS call screen.
      await _native.setAudioRoute(active.uuid, on);
    }
    return ok;
  }

  bool onSpeaker() => _audio.speakerOn;

  // -------------------------------------------------------------- transfer

  /// Transfer the live call to [to] (extension or number). Returns the
  /// platform's response, or `{error: ...}`.
  Future<Map<String, dynamic>> transfer(String to) async {
    final socket = _socket;
    if (socket == null) return {'error': 'SocketCMI is not initialized'};
    final callId = _sip.getCallId();
    if (callId == null) return {'error': 'No active call found'};
    return socket.transfer(callId, to);
  }

  /// Transfer the live call to a team.
  Future<Map<String, dynamic>> teamTransfer(String to) async {
    final socket = _socket;
    if (socket == null) return {'error': 'SocketCMI is not initialized'};
    final callId = _sip.getCallId();
    if (callId == null) return {'error': 'No active call found'};
    return socket.teamTransfer(callId, to);
  }

  /// Attended transfer: merge the consulted party into the call.
  void merge() => _sip.sendDtmf('0');

  /// Attended transfer: cancel the consultation and return to the caller.
  void cancel() => _sip.sendDtmf('#');

  /// The live call's SIP Call-ID (outbound calls), or null.
  String? getCallId() => _sip.getCallId();

  /// The live call's TeleCMI call id, or null.
  String? getCallID() => _sip.getCallID();

  void _onTransfer(Map<String, dynamic> data) {
    if (data['state'] == 'init') sendDtmf('*9');
    emit('transfer', data);
  }

  // -------------------------------------------------------- InboundCallHost

  @override
  void dismissRinging(String uuid, String reason) {
    final int code;
    switch (reason) {
      case 'caller cancelled':
        code = EndReason.remote;
        break;
      case 'ring timeout':
      case 'busy':
        code = EndReason.missed;
        break;
      case 'rejected':
        code = EndReason.rejected;
        break;
      default:
        code = EndReason.local;
    }
    if (reason == 'caller cancelled' || reason == 'ring timeout') {
      _remember(_missedReported, uuid);
    }
    _native.endCall(uuid, reason: code);
  }

  @override
  void endConnected(String uuid, {required bool remote}) {
    _native.endCall(uuid, reason: remote ? EndReason.remote : EndReason.local);
  }

  // ---------------------------------------------------------------- native

  void _wireNative() {
    _native.onAnswer = (uuid) {
      _dbg('native answer: $uuid');
      if (_answeredHere.contains(uuid)) return; // echo of an app answer
      final pending = _livekit.pending;
      if (pending != null && pending.uuid == uuid) {
        _remember(_answeredHere, uuid);
        _connectInbound();
      } else if (_livekit.active?.uuid != uuid) {
        // The invite hasn't reached Dart yet (killed-state answer): park it —
        // completed by handleIncomingPush when the payload lands.
        _dbg('native answer parked (invite not ready): $uuid');
        _parkedAnswerUuid = uuid;
        _parkedAnswerAt = DateTime.now();
      }
    };
    _native.onEnd = (uuid, reason, from) {
      _dbg('native end: $uuid ($reason)');
      if (_parkedAnswerUuid == uuid) _parkedAnswerUuid = null;
      if (reason == 'failed') {
        // The OS refused the call screen (calling account disabled, Do Not
        // Disturb): the call still rings in the app ('inComingCall') and can
        // be answered from its UI until ringTime.
        _dbg('native call UI unavailable for $uuid — answer from the app UI');
        return;
      }
      if (reason == 'ring_timeout') {
        // The native backstop ended an unanswered ring.
        if (_livekit.isCall(uuid)) {
          _livekit.end('ring timeout');
        } else {
          // It rang while Dart wasn't running: surface the missed call now.
          _emitMissed(uuid, from, 'ring_timeout');
        }
        return;
      }
      if (_livekit.isCall(uuid)) _livekit.end('callkit endCall');
    };
    _native.onMute = (uuid, muted) {
      if (_livekit.active?.uuid == uuid) {
        _setMuted(muted, fromNative: true);
      } else if (_sip.hasActiveCall && _sip.isMuted != muted) {
        muted ? _sip.mute() : _sip.unmute();
      }
    };
    _native.onHold = (uuid, hold) {
      if (!_sip.hasActiveCall) return; // inbound calls have no hold yet
      hold ? _sip.hold() : _sip.unhold();
    };
    _native.onDtmf = (uuid, digits) {
      if (_sip.hasActiveCall && digits.isNotEmpty) _sip.sendDtmf(digits);
    };
    _native.onAudioRoute = (output, speaker) {
      if (_livekit.isCall()) _audio.syncSpeaker(speaker);
    };
    _native.onPushToken = (token) {
      // autoPushToken: false — the app registers tokens itself.
      if (_options.autoPushToken) _push.onNativeToken(token);
    };
    _native.onPush = _push.dispatch;
    _native.onAudioActivated = () {
      _dbg('CallKit audio session activated');
      _audio.onCallKitActivated();
    };
    _native.onAudioDeactivated = () {
      _dbg('CallKit audio session deactivated');
      _audio.onCallKitDeactivated();
    };
    _native.onReset = () {
      if (_livekit.isCall()) _livekit.end('callkit reset');
    };
  }
}
