// Push wake-ups — the Flutter port of pushToken.native.js:
//   Android: FCM data messages (firebase_messaging). The app adds ONE line in
//            main() — Piopiy.registerBackgroundHandler() — so killed-state
//            pushes ring natively from the background isolate.
//   iOS:     PushKit, owned entirely by the plugin's native side; the token
//            and payloads arrive through the native event channel.
//
// Carries the 0.26.3 stale-ring guard: FCM redelivers undelivered data pushes
// for DAYS — invites older than the ring window are dropped (cancels always
// pass; APNs pushes expire server-side instead).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';

import 'events.dart';
import 'livekit_call.dart';
import 'native_call.dart';
import 'rest.dart';

const int kStaleRingSeconds = 45;

/// True when an FCM invite is a stale redelivery (sent > 45 s ago).
bool isStaleRing(RemoteMessage msg) {
  final type = msg.data['type'] ?? 'incoming_call';
  if (type != 'incoming_call') return false;
  final sent = msg.sentTime;
  if (sent == null) return false;
  final age = DateTime.now().difference(sent).inSeconds;
  return age > kStaleRingSeconds;
}

class PushManager {
  PushManager({
    required PiopiyEvents events,
    required NativeCall native,
    required PiopiyRest rest,
    this.log,
  })  : _events = events,
        _native = native,
        _rest = rest;

  final PiopiyEvents _events;
  final NativeCall _native;
  final PiopiyRest _rest;
  final void Function(String line)? log;

  String? deviceToken; // survives logout — re-registered on next login
  String? _provider; // 'apns' | 'fcm'
  String? _sentToken; // last token actually registered (dedupe)
  String? _authToken;
  String _sbc = '';
  bool _signedOut = false;
  bool _started = false;

  /// Called by Piopiy when a payload arrives from any source (FCM foreground,
  /// native iOS push event, background isolate replay).
  void Function(Map<String, dynamic> payload)? onCallPush;

  void _dbg(String line) => log?.call('[push] $line');

  Future<void> start() async {
    if (_started) return;
    _started = true;

    // iOS: PushKit token + payloads flow from the native side.
    _native.onPushToken = (token) {
      _dbg(
          'device token (apns): ${token.substring(0, token.length > 16 ? 16 : token.length)}…');
      deviceToken = token;
      _provider = 'apns';
      _registerIfReady();
    };
    _native.onPush = (payload) => _dispatch(payload);

    if (Platform.isAndroid) {
      try {
        final messaging = FirebaseMessaging.instance;
        // v17 API: register() triggers token issuance; onRegistered delivers
        // the initial token AND every rotation.
        messaging.onRegistered.listen((token) {
          _dbg(
              'device token (fcm): ${token.substring(0, token.length > 16 ? 16 : token.length)}…');
          if (deviceToken != token) _sentToken = null;
          deviceToken = token;
          _provider = 'fcm';
          _registerIfReady();
        });
        await messaging.register();
        FirebaseMessaging.onMessage.listen((msg) {
          if (isStaleRing(msg)) {
            _dbg('stale call push dropped — uuid ${msg.data['uuid'] ?? '-'}');
            return;
          }
          _dispatch(Map<String, dynamic>.from(msg.data));
        });
      } catch (e) {
        _dbg(
            'FCM unavailable (is Firebase configured? google-services.json?): $e');
      }
    }

    // Visibility for the silent failure modes (missing capability/config).
    Timer(const Duration(seconds: 10), () {
      if (deviceToken == null) {
        _dbg('no device push token after 10s — check the Push Notifications '
            'capability (iOS) / google-services.json (Android), and network');
      }
    });
  }

  /// login() succeeded: keep the auth context and (re)register the token.
  void onLogin({required String authToken, required String sbc}) {
    _authToken = authToken;
    _sbc = sbc;
    _signedOut = false;
    _sentToken = null; // always re-send on a fresh login
    _registerIfReady();
  }

  Future<void> onLogout() async {
    _signedOut = true;
    final auth = _authToken;
    final token = deviceToken;
    _authToken = null;
    _sentToken = null;
    if (auth != null && token != null) {
      final res = await _rest.unregisterPush(auth, token: token);
      _dbg('push token unregistered: ${res['code']}');
    }
  }

  bool get signedOut => _signedOut;

  Future<void> _registerIfReady() async {
    final token = deviceToken;
    final auth = _authToken;
    if (token == null || auth == null || _signedOut) return;
    if (_sentToken == token) return; // already registered
    final res = await _rest.registerPush(
      auth,
      token: token,
      provider: _provider ?? (Platform.isIOS ? 'apns' : 'fcm'),
      platform: Platform.isIOS ? 'ios' : 'android',
      sbc: _sbc,
    );
    if (res['code'] == 200) {
      _sentToken = token;
      _events.emit('pushRegistered', res);
      _dbg('push token registered');
    } else {
      _events.emit('error',
          {'code': 1007, 'status': 'push token register failed', 'data': res});
    }
  }

  void _dispatch(Map<String, dynamic> data) {
    final type = (data['type'] ?? 'incoming_call').toString();
    if (type == 'incoming_call' || type == 'cancel_call') {
      if (_signedOut && type == 'incoming_call') {
        // Explicitly signed out: refuse invites; dismiss any native ring the
        // cold path may have shown.
        final uuid = (data['uuid'] ?? data['call_id'] ?? '').toString();
        if (uuid.isNotEmpty) _native.endCall(uuid, reason: 2);
        _dbg('invite refused — signed out');
        return;
      }
      onCallPush?.call(data);
    } else {
      _events.emit('otherPush', data);
    }
  }
}

/// Killed-state Android wake-ups: FCM runs this in a background isolate. The
/// native Telecom ring works from there — the user answers on the OS call UI
/// and the app launches into the live call. Registered from the app's main():
///
///   FirebaseMessaging.onBackgroundMessage(piopiyBackgroundPushHandler);
///
/// (Must be a top-level function — a Flutter/FCM requirement.)
@pragma('vm:entry-point')
Future<void> piopiyBackgroundPushHandler(RemoteMessage msg) async {
  final data = msg.data;
  final type = data['type'] ?? 'incoming_call';
  final uuid = (data['uuid'] ?? data['call_id'] ?? '').toString();
  if (uuid.isEmpty) return;

  final native = NativeCall();
  if (type == 'cancel_call') {
    await native.endCall(uuid, reason: 2);
    return;
  }
  if (type != 'incoming_call') return;
  if (isStaleRing(msg)) return; // FCM redelivery of a dead call

  await native.setup(appName: 'PIOPIY');
  // Stash the payload natively so the launched app can pick the call up and
  // join its LiveKit room when the user answers.
  await native.displayIncomingCall(
    uuid: uuid,
    handle: (data['from'] ?? 'Incoming call').toString(),
    callerName: (data['name'] ?? data['from'] ?? 'Incoming call').toString(),
    payload: data,
  );
}

/// Re-exported for apps that want the payload shape.
typedef PiopiyInboundCall = InboundCall;
