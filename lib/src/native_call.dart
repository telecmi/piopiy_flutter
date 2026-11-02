// Bridge to the plugin's native call layer:
//   iOS     — CallKit (CXProvider) + PushKit, both owned by the plugin. The
//             plugin reports the incoming call to CallKit synchronously inside
//             the PushKit callback (an iOS 13+ requirement) BEFORE Dart ever
//             runs, then delivers the payload and user actions here.
//   Android — Telecom ConnectionService (system-managed phone account): the
//             OS shows its native call UI for ring AND in-call, like the
//             React Native SDK's voice calls.
//
// Events delivered to Dart (EventChannel):
//   {event: 'answer', uuid}            — user tapped Answer on the native UI
//   {event: 'end', uuid}               — user ended/declined natively
//   {event: 'pushToken', token}        — iOS PushKit token (issued/rotated)
//   {event: 'push', payload: {...}}    — iOS VoIP push payload (incl. ones
//                                        that arrived before Dart attached)
//   {event: 'audioActivated'}          — iOS AVAudioSession activated by
//                                        CallKit (start WebRTC audio now)

import 'dart:async';

import 'package:flutter/services.dart';

class NativeCall {
  NativeCall({this.log}) {
    _events.receiveBroadcastStream().listen(_onEvent, onError: (Object e) {
      _dbg('event stream error: $e');
    });
  }

  static const MethodChannel _channel =
      MethodChannel('com.telecmi.piopiy/call');
  static const EventChannel _events = EventChannel('com.telecmi.piopiy/events');

  final void Function(String line)? log;

  void Function(String uuid)? onAnswer;
  void Function(String uuid)? onEnd;
  void Function(String token)? onPushToken;
  void Function(Map<String, dynamic> payload)? onPush;
  void Function()? onAudioActivated;

  void _dbg(String line) => log?.call('[native] $line');

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final map = Map<String, dynamic>.from(raw);
    final event = (map['event'] ?? '').toString();
    _dbg('event: $event ${map['uuid'] ?? ''}');
    switch (event) {
      case 'answer':
        onAnswer?.call((map['uuid'] ?? '').toString().toLowerCase());
        break;
      case 'end':
        onEnd?.call((map['uuid'] ?? '').toString().toLowerCase());
        break;
      case 'pushToken':
        onPushToken?.call((map['token'] ?? '').toString());
        break;
      case 'push':
        final p = map['payload'];
        if (p is Map) onPush?.call(Map<String, dynamic>.from(p));
        break;
      case 'audioActivated':
        onAudioActivated?.call();
        break;
    }
  }

  /// One-time native setup. [appName] labels the phone account / CallKit
  /// provider. Also registers for PushKit on iOS (token arrives as a
  /// 'pushToken' event) and replays any events cached before Dart attached.
  Future<void> setup({required String appName}) async {
    try {
      await _channel.invokeMethod('setup', {'appName': appName});
    } on PlatformException catch (e) {
      _dbg('setup failed: ${e.message}');
    }
  }

  /// Ring the native incoming-call UI (Android warm path; on iOS ringing
  /// happens natively inside the PushKit callback, so this is a no-op there).
  Future<void> displayIncomingCall({
    required String uuid,
    required String handle,
    required String callerName,
    Map<String, dynamic>? payload,
  }) async {
    try {
      await _channel.invokeMethod('displayIncomingCall', {
        'uuid': uuid,
        'handle': handle,
        'callerName': callerName,
        // Stored natively with the Telecom call: a cold-launched app reads it
        // back (a 'push' event replays it) to join the LiveKit room on answer.
        if (payload != null) 'payload': payload,
      });
    } on PlatformException catch (e) {
      _dbg('displayIncomingCall failed: ${e.message}');
    }
  }

  /// The call connected — tell the OS (Telecom setActive / CallKit fulfilled)
  /// so the native UI shows the live call and audio routing engages.
  Future<void> setCallActive(String uuid) async {
    try {
      await _channel.invokeMethod('setCallActive', {'uuid': uuid});
    } on PlatformException catch (_) {}
  }

  /// End the native call (remote hangup / cancel push / SDK hangup).
  /// [reason]: 2 = remote ended, 3 = unanswered/missed, 6 = declined.
  Future<void> endCall(String uuid, {int reason = 2}) async {
    try {
      await _channel.invokeMethod('endCall', {'uuid': uuid, 'reason': reason});
    } on PlatformException catch (_) {}
  }

  /// Report an app-UI answer back to the OS so the native call doesn't stay
  /// "ringing" (iOS would otherwise overlay its own UI).
  Future<void> answerCall(String uuid) async {
    try {
      await _channel.invokeMethod('answerCall', {'uuid': uuid});
    } on PlatformException catch (_) {}
  }

  Future<void> setMuted(String uuid, bool muted) async {
    try {
      await _channel.invokeMethod('setMuted', {'uuid': uuid, 'muted': muted});
    } on PlatformException catch (_) {}
  }
}
