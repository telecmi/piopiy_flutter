// PIOPIY — the SDK facade. API parity with @telecmi/piopiy-native:
//   login / logout / call / answer / reject / terminate / mute / unMute /
//   speaker / sendDtmf / getAuthToken + the same event names.
//
// Architecture (same as React Native):
//   OUTBOUND — SIP over WSS (sip_ua, the Dart jsSIP port).
//   INBOUND  — push-delivered LiveKit room: the native layer rings the OS
//              call UI (CallKit / Telecom), and on answer the SDK joins the
//              room carried by the push payload. Retryable by design.

import 'dart:async';
import 'dart:io' show Platform;

import 'events.dart';
import 'livekit_call.dart';
import 'native_call.dart';
import 'push_manager.dart';
import 'rest.dart';
import 'sip_engine.dart';

class PiopiyOptions {
  const PiopiyOptions({
    this.name = 'PIOPIY',
    this.debug = false,
    this.apiBase,
    this.autoPushToken = true,
  });

  /// Shown on the native call UI / phone account.
  final String name;

  /// Mirror SDK logs to debugPrint (and the `log` event).
  final bool debug;

  /// Override the TeleCMI REST base (staging). Default: rest.telecmi.com/v2.
  final String? apiBase;

  /// Fetch + register the device push token automatically at login.
  final bool autoPushToken;
}

class Piopiy extends PiopiyEvents {
  Piopiy([PiopiyOptions options = const PiopiyOptions()]) : _options = options {
    _rest = PiopiyRest(apiBase: options.apiBase)..log = _dbg;
    _native = NativeCall(log: _dbg);
    _sip = SipEngine(this, log: _dbg);
    _livekit = LiveKitEngine(this, log: _dbg);
    _push = PushManager(events: this, native: _native, rest: _rest, log: _dbg)
      ..onCallPush = _onCallPush;
    _wireNative();
  }

  final PiopiyOptions _options;
  late final PiopiyRest _rest;
  late final NativeCall _native;
  late final SipEngine _sip;
  late final LiveKitEngine _livekit;
  late final PushManager _push;

  String? _authToken;
  String _region = '';
  bool _setupDone = false;

  // The inbound call lifecycle.
  InboundCall? _pendingIncoming; // ringing, not yet answered
  InboundCall? _activeIncoming; // answered / connecting
  String? _parkedAnswerUuid; // native answer arrived before the invite
  DateTime? _parkedAnswerAt;
  final Set<String> _answeredHere = {}; // dedupe native/app answer echoes

  static const Duration _maxParkedAnswerAge = Duration(seconds: 60);

  void _dbg(String line) {
    if (_options.debug) {
      // ignore: avoid_print
      print('[piopiy] $line');
    }
    emit('log', line);
  }

  // ---------------------------------------------------------------- session

  /// Sign in: SIP REGISTER to the SBC (fires 'login'/'loginFailed') and, in
  /// parallel, the REST token fetch that powers push registration and
  /// [getAuthToken]. Same two-track flow as the JS SDK.
  Future<void> login(String userId, String password, [String? region]) async {
    _region = (region == null || region.isEmpty) ? 'sbcsg.telecmi.com' : region;

    if (!_setupDone) {
      _setupDone = true;
      await _native.setup(appName: _options.name);
      if (_options.autoPushToken) await _push.start();
    }

    _sip.start(
      userId: userId,
      password: password,
      region: _region,
      displayName: _options.name,
    );

    final res = await _rest.getToken(userId, password);
    if (res['code'] == 200) {
      _authToken = res['token'] as String;
      if (_options.autoPushToken) {
        _push.onLogin(authToken: _authToken!, sbc: _region);
      }
    } else {
      emit('loginFailed', {'code': 407, 'status': 'Token generation failed'});
    }
  }

  /// Sign out. Unregisters the device push token first (retried inside), so
  /// the platform stops waking this device, then tears the session down.
  Future<void> logout() async {
    await _push.onLogout();
    await _livekit.hangup();
    _sip.stop();
    _pendingIncoming = null;
    _activeIncoming = null;
    emit('logout', {'code': 200});
  }

  /// The TeleCMI REST auth token of the signed-in agent (the /user/login
  /// bearer) — for apps calling TeleCMI REST APIs themselves. null until
  /// login completes; the next login replaces it.
  String? getAuthToken() => _authToken;

  // ---------------------------------------------------------------- outbound

  /// Dial a number/extension through the SBC (native dialer UI not involved —
  /// outbound stays in the app, same as React Native).
  Future<void> call(String to, {Map<String, dynamic>? extraHeaders}) async {
    await _sip.makeCall(to, extraHeaders: extraHeaders);
  }

  void sendDtmf(String tones) => _sip.sendDtmf(tones);

  // ---------------------------------------------------------------- inbound

  /// Answer the ringing incoming call from the APP's UI. (Answers from the
  /// native call screen arrive automatically — nothing to call.)
  Future<void> answer() async {
    final call = _pendingIncoming;
    if (call == null) {
      emit('error', {'code': 1005, 'status': 'No incoming call'});
      return;
    }
    _answeredHere.add(call.uuid);
    // Flip the native call to answered too, or iOS overlays its own UI.
    await _native.answerCall(call.uuid);
    await _connectInbound(call);
  }

  /// Decline the ringing call on THIS device (the caller keeps ringing other
  /// devices until the server times out — same semantics as RN).
  Future<void> reject() async {
    final call = _pendingIncoming;
    if (call == null) return;
    _pendingIncoming = null;
    await _native.endCall(call.uuid, reason: 6);
    emit('ended', {'uuid': call.uuid, 'reason': 'rejected'});
  }

  /// Hang up whatever call is live (outbound SIP or inbound LiveKit).
  Future<void> terminate() async {
    if (_sip.hasActiveCall) {
      _sip.hangup();
      return;
    }
    final uuid = _activeIncoming?.uuid ?? _pendingIncoming?.uuid;
    _activeIncoming = null;
    _pendingIncoming = null;
    await _livekit.hangup();
    if (uuid != null) await _native.endCall(uuid, reason: 2);
  }

  // ---------------------------------------------------------------- controls

  Future<void> mute() => _setMuted(true);
  Future<void> unMute() => _setMuted(false);

  Future<void> _setMuted(bool muted) async {
    if (_sip.hasActiveCall) {
      _sip.setMuted(muted);
    } else {
      await _livekit.setMuted(muted);
    }
    final uuid = _activeIncoming?.uuid;
    if (uuid != null) await _native.setMuted(uuid, muted);
  }

  Future<void> speaker(bool on) => _livekit.setSpeaker(on);

  // ------------------------------------------------------------ push inbound

  void _onCallPush(Map<String, dynamic> data) {
    final type = (data['type'] ?? 'incoming_call').toString();
    final uuid =
        (data['uuid'] ?? data['call_id'] ?? '').toString().toLowerCase();
    if (uuid.isEmpty) return;

    if (type == 'cancel_call') {
      _dbg('cancel for $uuid');
      if (_answeredHere.contains(uuid)) return; // multi-device dismissal echo
      if (_pendingIncoming?.uuid == uuid) _pendingIncoming = null;
      _livekit.endByUuid(uuid);
      _native.endCall(uuid, reason: 2);
      emit('ended', {'uuid': uuid, 'reason': 'cancelled'});
      return;
    }

    final call = InboundCall.fromPayload(data);
    if (call == null) {
      _dbg('invite missing room/token/url — ignored');
      return;
    }
    _dbg('incoming from ${call.from} | room ${call.room} | uuid ${call.uuid}');
    _pendingIncoming = call;
    emit('inComingCall', {
      'uuid': call.uuid,
      'from': call.from,
      'name': call.name,
      'team': call.team,
    });

    // A native Answer tapped before the payload reached Dart (cold start):
    // complete it now.
    final parked = _parkedAnswerUuid;
    if (parked == call.uuid) {
      _parkedAnswerUuid = null;
      final age = DateTime.now().difference(_parkedAnswerAt ?? DateTime.now());
      if (age > _maxParkedAnswerAge) {
        _dbg('stale parked answer dropped: $parked');
        _native.endCall(call.uuid, reason: 3);
        _pendingIncoming = null;
        return;
      }
      _dbg('completing parked answer: $parked');
      _answeredHere.add(call.uuid);
      _connectInbound(call);
      return;
    }

    // Warm Android path: ring the native OS call UI. (iOS already rang from
    // the PushKit callback; Android cold path rang from the bg isolate.)
    if (Platform.isAndroid && data['_alreadyRang'] != true) {
      _native.displayIncomingCall(
        uuid: call.uuid,
        handle: call.from,
        callerName: call.name.isNotEmpty ? call.name : call.from,
        payload: data,
      );
    }
  }

  Future<void> _connectInbound(InboundCall call) async {
    _pendingIncoming = null;
    _activeIncoming = call;
    final ok = await _livekit.answer(call);
    if (ok) {
      await _native.setCallActive(call.uuid);
    } else {
      _activeIncoming = null;
      await _native.endCall(call.uuid, reason: 2);
    }
  }

  // ---------------------------------------------------------------- native

  void _wireNative() {
    _native.onAnswer = (uuid) {
      _dbg('native answer: $uuid');
      if (_answeredHere.contains(uuid)) return; // echo of an app answer
      final pending = _pendingIncoming;
      if (pending != null && pending.uuid == uuid) {
        _answeredHere.add(uuid);
        _connectInbound(pending);
      } else {
        // Invite hasn't reached Dart yet (killed-state answer): park it —
        // completed by _onCallPush when the payload lands.
        _dbg('native answer parked (invite not ready): $uuid');
        _parkedAnswerUuid = uuid;
        _parkedAnswerAt = DateTime.now();
      }
    };
    _native.onEnd = (uuid) {
      _dbg('native end: $uuid');
      if (_parkedAnswerUuid == uuid) _parkedAnswerUuid = null;
      if (_pendingIncoming?.uuid == uuid) {
        _pendingIncoming = null;
        emit('ended', {'uuid': uuid, 'reason': 'declined'});
        return;
      }
      if (_activeIncoming?.uuid == uuid) {
        _activeIncoming = null;
        _livekit.endByUuid(uuid);
      }
    };
    _native.onAudioActivated = () {
      // iOS: CallKit activated the AVAudioSession — WebRTC audio may start.
      _dbg('audio session activated');
    };
  }
}
