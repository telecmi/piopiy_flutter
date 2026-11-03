// Behaviour tests for the push-delivered call path and the public API
// contract shared with @telecmi/piopiy-native. The native layer is mocked at
// the platform-channel boundary.

import 'package:fake_async/fake_async.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piopiy_flutter/piopiy_flutter.dart';
import 'package:piopiy_flutter/src/push_manager.dart' show isStaleRing;

const _uuid = '6f1c2a9e-3b7d-4e21-9a55-0c8d2f4e7b10';

Map<String, dynamic> _invite({String uuid = _uuid}) => {
      'type': 'incoming_call',
      'uuid': uuid,
      'room': 'room-1',
      'token': 'jwt',
      'url': 'wss://media.example',
      'caller': '+919900000000', // FCM renames the reserved 'from' key
      'name': 'Priya Sharma',
      'team': 'support3',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const callChannel = MethodChannel('com.telecmi.piopiy/call');
  const eventChannel = EventChannel('com.telecmi.piopiy/events');
  late List<MethodCall> calls;
  MockStreamHandlerEventSink? nativeEvents;

  setUp(() {
    calls = [];
    nativeEvents = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(callChannel, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (_, events) => nativeEvents = events),
    );
  });

  Iterable<Map> endCalls() => calls
      .where((c) => c.method == 'endCall')
      .map((c) => c.arguments as Map);

  Piopiy create() => Piopiy(const PiopiyOptions(autoPushToken: false));

  group('incoming push', () {
    test('inComingCall carries the React Native payload', () {
      final p = create();
      final got = <dynamic>[];
      p.on('inComingCall', got.add);
      expect(p.handleIncomingPush(_invite()), isTrue);
      expect(got, [
        {
          'from': '+919900000000',
          'name': 'Priya Sharma',
          'team_name': 'support3',
          'call_id': _uuid,
          'transfer': false,
          'transport': 'push',
        }
      ]);
    });

    test('a push delivered twice rings once', () {
      final p = create();
      var rings = 0;
      p.on('inComingCall', (_) => rings++);
      p.handleIncomingPush(_invite());
      p.handleIncomingPush(_invite());
      expect(rings, 1);
    });

    test('an invite without room/token is rejected', () {
      final p = create();
      expect(p.handleIncomingPush({'uuid': _uuid, 'from': 'x'}), isFalse);
    });

    test('caller cancel dismisses the ring and reports a missed call', () {
      final p = create();
      final ended = <dynamic>[];
      final missed = <dynamic>[];
      final cancels = <dynamic>[];
      p.on('ended', ended.add);
      p.on('missedCall', missed.add);
      p.on('callkeepCancel', cancels.add);
      p.handleIncomingPush(_invite());
      p.handleIncomingPush({'type': 'cancel_call', 'uuid': _uuid, 'caller': '+91'});
      p.handleIncomingPush({'type': 'cancel_call', 'uuid': _uuid}); // redelivery
      expect(ended.single['reason'], 'caller cancelled');
      expect(ended.single['transport'], 'push');
      expect(cancels.single, {'uuid': _uuid, 'reason': 'caller cancelled'});
      expect(missed, [
        {'uuid': _uuid, 'from': '+919900000000', 'reason': 'cancelled', 'transport': 'push'}
      ]);
      expect(endCalls().single, {'uuid': _uuid, 'reason': 2});
    });

    test('a cancel for a call Dart never saw still reports it missed', () {
      final p = create();
      final missed = <dynamic>[];
      p.on('missedCall', missed.add);
      p.handleIncomingPush({'type': 'cancel_call', 'uuid': _uuid, 'caller': '+9188'});
      expect(missed.single['from'], '+9188');
      expect(missed.single['reason'], 'cancelled');
      expect(endCalls().single['reason'], 3);
    });

    test('ringing stops after ringTime and is a missed call', () {
      fakeAsync((async) {
        final p = Piopiy(const PiopiyOptions(autoPushToken: false, ringTime: 40));
        final missed = <dynamic>[];
        final ended = <dynamic>[];
        p.on('missedCall', missed.add);
        p.on('ended', ended.add);
        p.handleIncomingPush(_invite());
        async.elapse(const Duration(seconds: 39));
        expect(missed, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(missed.single['reason'], 'ring_timeout');
        expect(ended.single['reason'], 'ring timeout');
        expect(endCalls().single['reason'], 3);
        async.flushTimers();
      });
    });

    test('reject() declines without a missed call', () async {
      final p = create();
      final ended = <dynamic>[];
      final missed = <dynamic>[];
      p.on('ended', ended.add);
      p.on('missedCall', missed.add);
      p.handleIncomingPush(_invite());
      await p.reject();
      expect(ended.single['reason'], 'rejected');
      expect(missed, isEmpty);
      expect(endCalls().single['reason'], 6);
    });

    test('after logout() invite pushes are refused', () async {
      final p = create();
      var rings = 0;
      p.on('inComingCall', (_) => rings++);
      final res = await p.logout();
      expect(res['code'], 200);
      expect(calls.any((c) => c.method == 'setSignedOut' && c.arguments['signedOut'] == true), isTrue);
      expect(p.handleIncomingPush(_invite()), isFalse);
      expect(rings, 0);
      expect(endCalls().single['uuid'], _uuid);
    });

    test('pushes that are not calls go to onOtherPush and otherPush', () async {
      final p = create();
      final cb = <dynamic>[];
      final ev = <dynamic>[];
      p.onOtherPush(cb.add);
      p.on('otherPush', ev.add);
      await Future<void>.delayed(Duration.zero);
      nativeEvents!.success({
        'event': 'push',
        'payload': {'type': 'promo', 'id': '7'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(cb.single, {'type': 'promo', 'id': '7'});
      expect(ev.single, {'type': 'promo', 'id': '7'});
    });
  });

  group('native events', () {
    test('a native ring timeout while Dart was not running is a missed call', () async {
      final p = create();
      final missed = <dynamic>[];
      p.on('missedCall', missed.add);
      await Future<void>.delayed(Duration.zero);
      nativeEvents!.success({
        'event': 'end',
        'uuid': _uuid,
        'reason': 'ring_timeout',
        'from': '+9177',
      });
      await Future<void>.delayed(Duration.zero);
      expect(missed, [
        {'uuid': _uuid, 'from': '+9177', 'reason': 'ring_timeout', 'transport': 'push'}
      ]);
    });

    test('declining on the native call screen ends the ringing call', () async {
      final p = create();
      final ended = <dynamic>[];
      final missed = <dynamic>[];
      p.on('ended', ended.add);
      p.on('missedCall', missed.add);
      await Future<void>.delayed(Duration.zero);
      p.handleIncomingPush(_invite());
      nativeEvents!.success({'event': 'end', 'uuid': _uuid, 'reason': 'user'});
      await Future<void>.delayed(Duration.zero);
      expect(ended.single['reason'], 'callkit endCall');
      expect(missed, isEmpty);
    });
  });

  group('API contract', () {
    test('idle state matches the React Native SDK', () async {
      final p = create();
      expect(p.isLogedIn(), isFalse);
      expect(p.isConnected(), isFalse);
      expect(p.onHold(), isFalse);
      expect(p.onMute(), isFalse);
      expect(p.onSpeaker(), isFalse);
      expect(p.getCallId(), isNull);
      expect(p.getCallID(), isNull);
      expect(p.getAuthToken(), isNull);
      expect(await p.transfer('101'), {'error': 'SocketCMI is not initialized'});
      expect(await p.teamTransfer('sales'), {'error': 'SocketCMI is not initialized'});
    });

    test('answer() with nothing ringing reports call not found', () async {
      final p = create();
      final errors = <dynamic>[];
      p.on('error', errors.add);
      await p.answer();
      expect(errors.single, {'code': 1002, 'status': 'call not found'});
    });

    test('registerToken validates its arguments', () async {
      final p = create();
      final res = await p.registerToken(provider: '', token: '');
      expect(res['code'], 1006);
    });

    test('unregisterToken without a registered token', () async {
      final p = create();
      final res = await p.unregisterToken();
      expect(res, {'code': 1008, 'status': 'no push token registered'});
    });

    test('setup forwards the call-UI options', () {
      Piopiy(const PiopiyOptions(
        name: 'Acme',
        autoPushToken: false,
        ringTime: 30,
        callKeep: PiopiyCallKeepOptions(
          ios: PiopiyIosCallOptions(ringtoneSound: 'ring.caf'),
        ),
      ));
      final setup = calls.firstWhere((c) => c.method == 'setup').arguments as Map;
      expect(setup['appName'], 'Acme');
      expect(setup['ringTime'], 30);
      expect(setup['autoPushToken'], false);
      expect((setup['ios'] as Map)['ringtoneSound'], 'ring.caf');
      expect((setup['android'] as Map)['channelId'], 'com.piopiy.callkeep');
    });
  });

  group('events', () {
    test('once() fires a single time and off() removes it', () {
      final p = create();
      var n = 0;
      void handler(dynamic _) => n++;
      p.once('x', handler);
      p.emit('x');
      p.emit('x');
      expect(n, 1);
      p.once('y', handler);
      p.off('y', handler);
      p.emit('y');
      expect(n, 1);
    });
  });

  group('stale FCM redelivery', () {
    test('invites older than 45 s are stale, cancels never', () {
      final old = DateTime.now().subtract(const Duration(seconds: 60));
      expect(isStaleRing(RemoteMessage(sentTime: old, data: _invite())), isTrue);
      expect(
          isStaleRing(RemoteMessage(
              sentTime: old, data: const {'type': 'cancel_call', 'uuid': _uuid})),
          isFalse);
      expect(isStaleRing(RemoteMessage(sentTime: DateTime.now(), data: _invite())),
          isFalse);
    });
  });
}
