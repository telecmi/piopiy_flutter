# PIOPIY Flutter SDK

Official **PIOPIY voice SDK for Flutter** — high-quality voice calls over the
TeleCMI network with the **native call UI** (iOS CallKit / Android Telecom)
for ring **and** in-call, plus push wake-ups so calls arrive with the app
backgrounded or killed.

Same architecture as `@telecmi/piopiy-native` (React Native): outbound calls
are SIP over WSS; incoming calls are push-delivered — the payload carries the
call's room and join token, so answering works even from a cold start.

## Install

```yaml
dependencies:
  piopiy_flutter: ^0.1.0
```

## Quick start

```dart
import 'package:piopiy_flutter/piopiy_flutter.dart';

final piopiy = Piopiy(const PiopiyOptions(name: 'MyApp', debug: true));

piopiy.on('login', (_) => print('signed in'));
piopiy.on('inComingCall', (c) => print('incoming from ${c['from']}'));
piopiy.on('answered', (_) => print('connected'));
piopiy.on('ended', (_) => print('call over'));

await piopiy.login('5159_2224257', 'password', 'sbcsg.telecmi.com');

// Outbound
await piopiy.call('9199XXXXXXXX');

// Controls
await piopiy.mute();
await piopiy.unMute();
await piopiy.speaker(true);
piopiy.sendDtmf('1');
await piopiy.terminate();

// The agent's REST auth token (for your own TeleCMI REST calls)
final token = piopiy.getAuthToken();
```

Incoming calls ring on the **OS call screen** — the user answers there and
the SDK connects the call; your app needs no incoming-call UI (listen to the
events to update state).

## Push wake-ups

### Android (FCM)

1. Set up Firebase in your app (`google-services.json` with your
   `applicationId`, the google-services Gradle plugin) — the standard
   `firebase_messaging` setup.
2. Add **one line** in `main()` so killed-state pushes ring natively:

```dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:piopiy_flutter/piopiy_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FirebaseMessaging.onBackgroundMessage(piopiyBackgroundPushHandler);
  runApp(const MyApp());
}
```

Everything in the manifest (permissions, the Telecom `ConnectionService`)
merges in from the SDK automatically — **hand-copy nothing**.

> First run: if a push arrives but no call UI shows, enable the app's
> **calling account** once — Settings → search "Calling accounts" → enable.
> On Oppo/OnePlus/Xiaomi/vivo also set battery usage to **Unrestricted**.

### iOS (PushKit)

The plugin owns PushKit and CallKit — **no AppDelegate code**. In Xcode:

1. Capabilities: **Push Notifications** + **Background Modes → Voice over IP**
2. `Info.plist`: add `NSMicrophoneUsageDescription`

The VoIP token is fetched and registered with TeleCMI automatically at
`login()`.

## Events

| Event | When |
| :--- | :--- |
| `login` / `loginFailed` / `logout` | session lifecycle |
| `trying` / `ringing` | outbound progress |
| `inComingCall` | incoming ring (`{uuid, from, name, team}`) |
| `answered` | media connected (either direction) |
| `ended` / `hangup` | call finished |
| `pushRegistered` | device token registered with TeleCMI |
| `error` | anything that failed (`{code, status}`) |

## Documentation

- [Android setup](doc/android-setup.md) — Firebase checklist, permissions, first-run calling account
- [iOS setup](doc/ios-setup.md) — Xcode capabilities, APNs key, audio-session rules
- [Push notifications](doc/push-notifications.md) — credentials, how the flow works, built-in guards
- [Troubleshooting](doc/troubleshooting.md) — every field-diagnosed symptom and its fix
- [Changelog](CHANGELOG.md)

## License

Apache-2.0 © [TeleCMI](https://telecmi.com)
