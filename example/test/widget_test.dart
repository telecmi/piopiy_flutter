// Smoke test: the SDK constructs and the example's call options are valid.
// (The example app itself needs Firebase and a device — run it with
// `flutter run`.)

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piopiy_flutter/piopiy_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the SDK constructs with the example options', () {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.telecmi.piopiy/call'), (_) async => null);
    final piopiy = Piopiy(const PiopiyOptions(name: 'PiopiyExample', autoPushToken: false));
    expect(piopiy.isLogedIn(), isFalse);
    expect(Piopiy.version, isNotEmpty);
  });
}
