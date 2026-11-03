// Bridge to the plugin's native call layer:
//   iOS     — CallKit (CXProvider) + PushKit, owned by the plugin and set up
//             at app launch (before Dart runs): the incoming call is reported
//             to CallKit synchronously inside the PushKit callback, then the
//             payload and user actions are delivered here.
//   Android — Telecom ConnectionService (system-managed phone account): the
//             OS shows its native call UI for ring AND in-call.
//
// Events delivered to Dart (EventChannel; queued natively until Dart attaches
// and replayed then — killed-state answers arrive before Flutter boots):
//   {event: 'answer', uuid}             user tapped Answer on the native UI
//   {event: 'end', uuid, reason, from}  native call ended: reason 'user'
//                                       (declined / hung up natively),
//                                       'ring_timeout' (native backstop),
//                                       'failed'
//   {event: 'mute', uuid, muted}        mute toggled on the native UI
//   {event: 'hold', uuid, hold}         hold toggled on the native UI
//   {event: 'dtmf', uuid, digits}       keypad on the native UI
//   {event: 'audioRoute', output, speaker}  audio route changed natively
//   {event: 'pushToken', token}         iOS PushKit token (issued/rotated)
//   {event: 'push', payload}            a call push the native layer handled
//   {event: 'audioActivated'} / {event: 'audioDeactivated'}
//                                       iOS: CallKit (de)activated the
//                                       AVAudioSession
//   {event: 'reset'}                    iOS: CallKit provider reset

import 'dart:async';

import 'package:flutter/services.dart';

/// CallKit/Telecom end reasons for [NativeCall.endCall].
class EndReason {
  static const int local = 1; // ended on this device (hang up / decline)
  static const int remote = 2; // the other side ended / cancelled
  static const int missed = 3; // rang out unanswered
  static const int rejected = 6; // declined on this device
}

class NativeCall {
  /// [listen]: subscribe to native events. Only the app's main isolate
  /// listens — the Android FCM background isolate must not, or it would
  /// swallow the call events meant for the app.
  NativeCall({this.log, bool listen = true}) {
    if (listen) {
      _events.receiveBroadcastStream().listen(_onEvent, onError: (Object e) {
        _dbg('event stream error: $e');
      });
    }
  }

  static const MethodChannel _channel = MethodChannel('com.telecmi.piopiy/call');
  static const EventChannel _events = EventChannel('com.telecmi.piopiy/events');

  final void Function(String line)? log;

  void Function(String uuid)? onAnswer;
  void Function(String uuid, String reason, String? from)? onEnd;
  void Function(String uuid, bool muted)? onMute;
  void Function(String uuid, bool hold)? onHold;
  void Function(String uuid, String digits)? onDtmf;
  void Function(String output, bool speaker)? onAudioRoute;
  void Function(String token)? onPushToken;
  void Function(Map<String, dynamic> payload)? onPush;
  void Function()? onAudioActivated;
  void Function()? onAudioDeactivated;
  void Function()? onReset;

  void _dbg(String line) => log?.call('[native] $line');

  static String _uuid(Map<String, dynamic> map) =>
      (map['uuid'] ?? '').toString().toLowerCase();

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final map = Map<String, dynamic>.from(raw);
    final event = (map['event'] ?? '').toString();
    _dbg('event: $event ${map['uuid'] ?? ''}');
    switch (event) {
      case 'answer':
        onAnswer?.call(_uuid(map));
        break;
      case 'end':
        onEnd?.call(_uuid(map), (map['reason'] ?? 'user').toString(),
            map['from']?.toString());
        break;
      case 'mute':
        onMute?.call(_uuid(map), map['muted'] == true);
        break;
      case 'hold':
        onHold?.call(_uuid(map), map['hold'] == true);
        break;
      case 'dtmf':
        onDtmf?.call(_uuid(map), (map['digits'] ?? '').toString());
        break;
      case 'audioRoute':
        onAudioRoute?.call((map['output'] ?? '').toString(), map['speaker'] == true);
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
      case 'audioDeactivated':
        onAudioDeactivated?.call();
        break;
      case 'reset':
        onReset?.call();
        break;
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      _dbg('$method failed: ${e.message}');
    } on MissingPluginException {
      _dbg('$method: native plugin not available');
    }
    return null;
  }

  /// Native setup: CallKit provider / Telecom phone account configuration,
  /// persisted natively so a killed-state launch uses the same settings.
  Future<void> setup(Map<String, dynamic> settings) =>
      _invoke<void>('setup', settings);

  /// Ring the native incoming-call UI (Android; iOS rings natively inside the
  /// PushKit callback, so this is a no-op there). The payload is stored with
  /// the call so a cold-launched app can join its room on answer.
  Future<void> displayIncomingCall({
    required String uuid,
    required String handle,
    required String callerName,
    Map<String, dynamic>? payload,
  }) =>
      _invoke<void>('displayIncomingCall', {
        'uuid': uuid,
        'handle': handle,
        'callerName': callerName,
        'payload': ?payload,
      });

  /// Android background isolate: hand a call push to the native layer, which
  /// rings (invite) or dismisses (cancel) the native UI and forwards the
  /// payload to the app's isolate when it is running.
  Future<bool> backgroundPush(Map<String, dynamic> payload) async =>
      (await _invoke<bool>('backgroundPush', {'payload': payload})) ?? false;

  /// The call connected — tell the OS so the native UI shows the live call.
  Future<void> setCallActive(String uuid) =>
      _invoke<void>('setCallActive', {'uuid': uuid});

  /// End the native call. See [EndReason].
  Future<void> endCall(String uuid, {int reason = EndReason.remote}) =>
      _invoke<void>('endCall', {'uuid': uuid, 'reason': reason});

  /// Report an app-UI answer back to the OS so the native call leaves the
  /// ringing state (iOS would otherwise keep its own ringing UI up).
  Future<void> answerCall(String uuid) =>
      _invoke<void>('answerCall', {'uuid': uuid});

  /// Keep the native call screen's mute button in sync (iOS).
  Future<void> setMuted(String uuid, bool muted) =>
      _invoke<void>('setMuted', {'uuid': uuid, 'muted': muted});

  /// Route the call to the loudspeaker or back (Android Telecom route, which
  /// also updates the OS call screen).
  Future<void> setAudioRoute(String uuid, bool speaker) =>
      _invoke<void>('setAudioRoute', {'uuid': uuid, 'speaker': speaker});

  /// Persist the signed-out state so the background push path refuses
  /// invites after logout (Android).
  Future<void> setSignedOut(bool signedOut) =>
      _invoke<void>('setSignedOut', {'signedOut': signedOut});
}
