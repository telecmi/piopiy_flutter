# PIOPIY Flutter — Example

Sign in with TeleCMI agent credentials, dial out, receive calls on the
native OS call UI. Credentials are saved — later launches sign in
automatically.

## Run — Android

```bash
flutter run
```

(or `flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk`)

## Run — iPhone (one-time signing first)

1. `open ios/Runner.xcworkspace` → Runner target → Signing & Capabilities →
   choose your team; add the **Push Notifications** capability.
2. `flutter run`

## Test flow

1. Sign in (grant mic + notification permissions)
2. Outbound: enter a number → **Call**
3. Incoming: call the agent — rings on the OS call screen in every app state
   (for killed-state, swipe the app away first)
4. The Log pane shows every SDK event (`📲 push token registered`,
   `📞 incoming`, …)

If incoming calls don't ring, see [doc/troubleshooting.md](../doc/troubleshooting.md)
— calling-account enablement and OEM battery settings are the usual causes.
