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
  piopiy_flutter: ^0.1.0
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
| 3 | The background handler — **one line** in `main()` (below) | `lib/main.dart` | calls only ring while the app is open |

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:piopiy_flutter/piopiy_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(piopiyBackgroundPushHandler);
  runApp(const MyApp());
}
```

`piopiyBackgroundPushHandler` rings the native OS call screen from the
background isolate — the user answers there and your app launches straight
into the live call.

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

## 4. First run, on the device

Android requires the user's **calling account** to be enabled once for apps
that place calls through the system UI. Most devices enable it silently; if
a push arrives but no call UI shows: Settings → search **"Calling
accounts"** → enable your app. One-time.

See [troubleshooting](troubleshooting.md) for the OEM battery-manager
checklist (Oppo / OnePlus / Xiaomi / vivo) and every field-diagnosed symptom.
