# PIOPIY Flutter — Android Setup

Everything native merges into your app automatically from the SDK — you
hand-copy **nothing** into your manifest. The checklist below is the complete
list of project files you touch.

## Requirements

- `minSdkVersion` **24** or higher
- `compileSdk` **36** or higher (androidx requirement)

## 1. Install

```yaml
dependencies:
  piopiy_flutter: ^0.2.0
```

Foreground calls (app open) now work with no further setup — sign in and
dial. The steps below add **incoming calls while backgrounded or killed**.

## 2. Firebase (incoming-call wake-ups)

Incoming calls reach a backgrounded/killed app through a high-priority FCM
data message. Firebase is **your app's**, set up the standard way:

| # | What | Where | Missing it looks like |
| :--- | :--- | :--- | :--- |
| 1 | `google-services.json` from your Firebase project — the package name must match your `applicationId` | `android/app/` | build fails `No matching client found for package name` |
| 2 | Google services plugin | `android/settings.gradle(.kts)`: `id("com.google.gms.google-services") version "4.4.2" apply false`; `android/app/build.gradle(.kts)` plugins block: `id("com.google.gms.google-services")` | no FCM token in the logs |
| 3 | `Firebase.initializeApp()` in `main()`, **before** the `Piopiy` instance is created | `lib/main.dart` | SDK logs `FCM unavailable — call Firebase.initializeApp()…` |

```dart
import 'package:firebase_core/firebase_core.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MyApp());
}
```

That's all the push code. The SDK registers its FCM background handler
itself (`autoBackgroundPush`, on by default): a call push that arrives while
the app is backgrounded or killed rings the native OS call screen, and when
the user answers there the SDK brings your app up — over the lock screen —
and connects the call. Your `MainActivity` needs no changes.

> **Your app already owns `FirebaseMessaging.onBackgroundMessage`?**
> Android allows one handler per app. Set `autoBackgroundPush: false` and
> forward from your handler: `await piopiyBackgroundPushHandler(message);`

The SDK registers the FCM **registration token** (`getToken()`) — the
target TeleCMI's push server sends to — and re-registers it on rotation.

> Also upload your Firebase **service account JSON** in the Connly dashboard
> (Push Notifications) so TeleCMI can send to your app — see the
> [push notifications guide](push-notifications.md).

## 3. Runtime permissions

Request microphone (and on Android 13+, notifications) before the first
call — the example does this at sign-in:

```dart
await [Permission.microphone, Permission.notification].request();
```

(with the `permission_handler` package, or your own flow.)

## 4. During a call

While a call is live the SDK runs a foreground service with an ongoing-call
notification, so the microphone keeps working with the app in the
background. Customize it with
`PiopiyOptions(callKeep: PiopiyCallKeepOptions(android: PiopiyAndroidCallOptions(...)))`
(channel id/name, title, small-icon drawable). The OS call screen's mute and
speaker buttons drive the SDK (`onMute()` / `onSpeaker()` follow them).

## 5. First run, on the device

Android requires the user's **calling account** to be enabled once for apps
that place calls through the system UI. Most devices enable it silently; if
a push arrives but no call UI shows: Settings → search **"Calling
accounts"** → enable your app. One-time.

See [troubleshooting](troubleshooting.md) for the OEM battery-manager
checklist (Oppo / OnePlus / Xiaomi / vivo) and every field-diagnosed symptom.
