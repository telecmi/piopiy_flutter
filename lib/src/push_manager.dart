// Push wake-ups and device-token registration — the Flutter port of
// pushToken.native.js + PIOPIY.registerToken/unregisterToken:
//   Android: FCM data messages (firebase_messaging) — the registration TOKEN
//            (getToken/onTokenRefresh), which is what TeleCMI's push server
//            sends to. Foreground pushes arrive via onMessage; background and
//            killed wake-ups via the FCM background handler, which the SDK
//            registers itself (autoBackgroundPush).
//   iOS:     PushKit, owned by the plugin's native side; the token and
//            payloads arrive through the native event channel.
//
// Carries the 0.26.3 stale-ring guard: FCM redelivers undelivered data pushes
// for DAYS — invites older than 45 s are dropped (cancels always pass; APNs
// pushes expire server-side instead).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';

import 'events.dart';
import 'native_call.dart';
import 'rest.dart';

const int kStaleRingSeconds = 45;

/// True when an FCM invite is a stale redelivery (sent > 45 s ago).
bool isStaleRing(RemoteMessage msg) {
  final type = msg.data['type'] ?? 'incoming_call';
  if (type != 'incoming_call') return false;
  final sent = msg.sentTime;
  if (sent == null) return false;
  return DateTime.now().difference(sent).inSeconds > kStaleRingSeconds;
}

/// Voice-call payload types (typeless = legacy invite).
bool isCallPush(Map<String, dynamic> data) {
  final type = data['type'];
  return type == null || type == 'incoming_call' || type == 'cancel_call';
}

class _PendingRegister {
  _PendingRegister(this.provider, this.token, this.platform, this.done);
  final String provider;
  final String token;
  final String? platform;
  final Completer<Map<String, dynamic>> done;
}

class PushManager {
  PushManager({
    required PiopiyEvents events,
    required NativeCall native,
    required PiopiyRest rest,
    required this.autoBackgroundPush,
    this.log,
  })  : _events = events,
        _native = native,
        _rest = rest;

  final PiopiyEvents _events;
  final NativeCall _native;
  final PiopiyRest _rest;
  final bool autoBackgroundPush;
  final void Function(String line)? log;

  /// Current device token — survives logout so the next sign-in can
  /// re-register without waiting for an OS event that will never come.
  String? deviceToken;
  String? _provider;
  String? _platform;

  /// Last token handed to registration (the OS re-emits the same token on
  /// every launch — only changes are sent).
  String? _lastToken;

  /// Token actually registered with TeleCMI (the JS SDK's `_pushToken`).
  String? sentToken;

  String? _authToken;
  String _sbc = '';
  bool _signedOut = false;
  _PendingRegister? _pending;

  bool _autoStarted = false;
  bool _fcmListening = false;
  bool _fcmHasToken = false;
  Future<void>? _fcmStarting;
  bool _bgRegistered = false;
  Timer? _noTokenTimer;

  /// A voice-call payload (any source) — handled by the facade.
  void Function(Map<String, dynamic> payload)? onCallPush;

  /// A push no TeleCMI call owns (the app's own FCM messages).
  void Function(Map<String, dynamic> payload)? onOtherPush;

  void _dbg(String line) => log?.call('[push] $line');

  static String _short(String t) => '${t.substring(0, t.length > 10 ? 10 : t.length)}…';

  // ---------------------------------------------------------- auto token

  /// Begin watching for the device push token. Idempotent; on Android it is
  /// retried at login when Firebase was not initialized yet.
  Future<void> start() async {
    if (!_autoStarted) {
      _autoStarted = true;
      // Visibility for the silent failure modes: a missing Push Notifications
      // capability or google-services.json otherwise shows NOTHING.
      _noTokenTimer = Timer(const Duration(seconds: 10), () {
        if (deviceToken == null) {
          _dbg('no device push token after 10s — check the Push Notifications '
              'capability (iOS), google-services.json (Android), and network');
        }
      });
    }
    if (Platform.isAndroid) await _startAndroid();
  }

  // Constructor and login() may both start it — one attempt at a time, or
  // the foreground listener would subscribe twice and dispatch every push
  // twice.
  Future<void> _startAndroid() {
    if (_fcmHasToken) return Future.value();
    return _fcmStarting ??= _startFcm().whenComplete(() => _fcmStarting = null);
  }

  Future<void> _startFcm() async {
    final FirebaseMessaging messaging;
    try {
      messaging = FirebaseMessaging.instance;
    } catch (e) {
      _dbg('FCM unavailable — call Firebase.initializeApp() before creating '
          'Piopiy / login, and check google-services.json: $e');
      return;
    }
    if (!_fcmListening) {
      _fcmListening = true;
      // ignore: deprecated_member_use
      messaging.onTokenRefresh.listen((t) => _onToken(t, 'fcm', 'android'));
      FirebaseMessaging.onMessage.listen((msg) {
        if (isStaleRing(msg)) {
          _dbg('stale call push dropped — uuid ${msg.data['uuid'] ?? '-'}');
          return;
        }
        dispatch(Map<String, dynamic>.from(msg.data));
      });
      if (autoBackgroundPush) registerBackgroundHandler();
      _dbg('watching for the Android FCM token');
    }
    try {
      // The FCM registration TOKEN — the push server sends to message.token.
      // (register()/onRegistered return the Firebase Installation ID, which
      // is not a valid FCM send target for TeleCMI.)
      // ignore: deprecated_member_use
      final token = await messaging.getToken();
      if (token != null) {
        _fcmHasToken = true;
        _onToken(token, 'fcm', 'android');
      }
    } catch (e) {
      // No Firebase app / no network: retried at the next login().
      _dbg('FCM getToken failed — $e');
    }
  }

  /// Android: register the FCM background handler (killed/background
  /// wake-ups). Android allows one per app. Idempotent.
  bool registerBackgroundHandler() {
    if (!Platform.isAndroid) return false;
    if (_bgRegistered) return true;
    try {
      FirebaseMessaging.onBackgroundMessage(piopiyBackgroundPushHandler);
      _bgRegistered = true;
      _dbg('Android background push handler registered');
      return true;
    } catch (e) {
      _dbg('background handler setup failed: $e');
      return false;
    }
  }

  /// iOS PushKit token from the native layer.
  void onNativeToken(String token) => _onToken(token, 'apns', 'ios');

  void _onToken(String token, String provider, String platform) {
    if (token.isEmpty) return;
    deviceToken = token;
    _provider = provider;
    _platform = platform;
    if (token == _lastToken) {
      _dbg('push token unchanged, skipping re-registration');
      return;
    }
    _lastToken = token;
    _dbg('device token ($provider): ${_short(token)}');
    if (_signedOut) {
      _dbg('signed out — token kept, registered at the next sign-in');
      return;
    }
    // registerToken() queues until the login auth token exists.
    registerToken(provider: provider, token: token, platform: platform)
        .then((res) => _dbg('/push/register response → $res'));
  }

  // ------------------------------------------------------------ routing

  /// A push arrived (FCM foreground, iOS native, background replay): voice
  /// payloads go to the facade, everything else to the app.
  void dispatch(Map<String, dynamic> data) {
    if (isCallPush(data)) {
      onCallPush?.call(data);
      return;
    }
    _events.emit('otherPush', data);
    onOtherPush?.call(data);
  }

  // ------------------------------------------------------ auth lifecycle

  bool get signedOut => _signedOut;

  /// login() started: invites are accepted again.
  void onLoginStarted() {
    _signedOut = false;
    _native.setSignedOut(false);
  }

  /// The REST auth token arrived: flush a queued registration, and make sure
  /// this sign-in registered the device token (the first registration on a
  /// fresh install can be lost; logout→login must re-send).
  void setAuth(String authToken, String sbc) {
    _authToken = authToken;
    _sbc = sbc;
    final pending = _pending;
    _pending = null;
    if (pending != null) {
      _register(pending.provider, pending.token, pending.platform)
          .then(pending.done.complete);
    } else {
      ensureRegistered();
    }
  }

  /// Register the kept device token unless it was actually sent this
  /// session ("sent", not "seen" — the 0.23.1 fix).
  void ensureRegistered() {
    final token = deviceToken;
    if (token == null || _signedOut || _authToken == null) return;
    if (sentToken == token) return;
    _dbg('(re)registering the device token after sign-in');
    _lastToken = null;
    _onToken(token, _provider ?? (Platform.isIOS ? 'apns' : 'fcm'),
        _platform ?? (Platform.isIOS ? 'ios' : 'android'));
  }

  /// The REST login failed: fail a queued registration.
  void authFailed() {
    final pending = _pending;
    _pending = null;
    pending?.done.complete({'code': 1008, 'status': 'auth token unavailable'});
  }

  // ---------------------------------------------------------- manual API

  /// Register a device push token with TeleCMI (queued until login
  /// completes).
  Future<Map<String, dynamic>> registerToken({
    required String provider,
    required String token,
    String? platform,
  }) {
    if (provider.isEmpty || token.isEmpty) {
      final err = {
        'code': 1006,
        'status': 'invalid push options: provider and token are required',
      };
      _events.emit('error', err);
      return Future.value(err);
    }
    if (_authToken == null) {
      // Only the latest queued registration matters.
      _pending?.done.complete({'code': 1008, 'status': 'superseded'});
      final pending = _PendingRegister(provider, token, platform, Completer());
      _pending = pending;
      return pending.done.future;
    }
    return _register(provider, token, platform);
  }

  Future<Map<String, dynamic>> _register(
      String provider, String token, String? platform) async {
    final auth = _authToken;
    if (auth == null) return {'code': 1008, 'status': 'auth token unavailable'};
    sentToken = token;
    final res = await _rest.registerPush(auth,
        token: token, provider: provider, platform: platform, sbc: _sbc);
    if (res['code'] == 200) {
      _events.emit('pushRegistered', res);
      _dbg('push token registered');
    } else {
      // Not sent after all — the next sign-in retries.
      if (sentToken == token) sentToken = null;
      _events.emit('error', {'code': 1007, 'status': 'push token register failed', 'data': res});
    }
    return res;
  }

  /// Remove the registered token from TeleCMI (stops push wake-ups).
  Future<Map<String, dynamic>> unregisterToken() async {
    final token = sentToken;
    final auth = _authToken;
    if (token == null || auth == null) {
      final err = {'code': 1008, 'status': 'no push token registered'};
      _events.emit('error', err);
      return err;
    }
    final res = await _rest.unregisterPush(auth, token: token);
    if (res['code'] == 200) {
      sentToken = null;
      _events.emit('pushUnregistered', res);
    } else {
      _events.emit('error', {'code': 1007, 'status': 'push token unregister failed', 'data': res});
    }
    return res;
  }

  /// logout(): refuse invites from now on, and unregister the token. The
  /// unregister MUST land or the platform keeps pushing calls to a
  /// signed-out device — retried once, logged loudly on final failure (the
  /// client-side guard still refuses any call that arrives meanwhile).
  Future<Map<String, dynamic>> onLogout() async {
    _signedOut = true;
    _lastToken = null;
    _native.setSignedOut(true);
    _pending?.done.complete({'code': 1008, 'status': 'signed out'});
    _pending = null;
    if (sentToken == null || _authToken == null) {
      return {'code': 200, 'status': 'no push token to unregister'};
    }
    var res = await unregisterToken();
    if (res['code'] == 200) return res;
    _dbg('push unregister failed ($res) — retrying in 2s');
    await Future<void>.delayed(const Duration(seconds: 2));
    res = await unregisterToken();
    if (res['code'] != 200) {
      _dbg('push unregister FAILED after retry — token may linger server-side; '
          'invite pushes are refused client-side until next sign-in');
    }
    return res;
  }

  void dispose() {
    _noTokenTimer?.cancel();
  }
}

/// Android background/killed wake-ups: FCM runs this in a background isolate.
/// The native layer rings the OS call screen (or dismisses it for a cancel)
/// and hands the payload to the app — which the SDK launches into the call
/// when the user answers.
///
/// The SDK registers it automatically (`autoBackgroundPush`). An app that owns
/// `FirebaseMessaging.onBackgroundMessage` calls it from its own handler:
///
///   await piopiyBackgroundPushHandler(message);
///
/// (Must be a top-level function — a Flutter/FCM requirement.)
@pragma('vm:entry-point')
Future<void> piopiyBackgroundPushHandler(RemoteMessage msg) async {
  final data = Map<String, dynamic>.from(msg.data);
  if (!isCallPush(data)) return; // not a TeleCMI call push
  if (isStaleRing(msg)) return; // FCM redelivery of a dead call
  await NativeCall(listen: false).backgroundPush(data);
}
