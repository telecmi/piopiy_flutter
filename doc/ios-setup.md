# PIOPIY Flutter — iOS Setup

The plugin owns **PushKit and CallKit** — there is no AppDelegate code to
write. Both start natively **at app launch** (before any Flutter engine
exists), so a VoIP push that launches the app in the background is reported
to CallKit inside the push callback — an iOS 13+ requirement handled for
you.

## Requirements

- iOS **13.0** or higher

## 1. Xcode capabilities (one time)

Open `ios/Runner.xcworkspace`, select the **Runner** target →
*Signing & Capabilities*:

1. **Push Notifications** — add the capability
2. **Background Modes** — add, and tick **Voice over IP** (and *Audio* if you
   want calls to survive extended backgrounding)

## 2. `Info.plist`

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is required for voice calls.</string>
```

## 3. APNs credentials (server side, one time)

Generate an **APNs Auth Key** (`.p8`) in the Apple Developer portal (Keys →
enable Apple Push Notifications service) and upload it — with its Key ID and
your Team ID — in the Connly dashboard → Push Notifications. TeleCMI then
wakes your devices; nothing else to configure.

> **Sandbox vs production:** debug/Xcode builds receive *sandbox* VoIP
> tokens; TestFlight/App Store builds receive *production* tokens. Your APNs
> key must be valid for the environment you're testing — a sandbox-only key
> can never push to store builds.

## That's all

The VoIP push token is fetched automatically, registered with TeleCMI at
`login()`, unregistered at `logout()`, and re-registered on the next
sign-in. Incoming calls ring the native CallKit screen — locked, backgrounded
or killed — and the SDK connects the call when the user answers.

### Answering from a killed state (UIScene apps)

Apps on Flutter's **UIScene lifecycle** (the default for new projects —
`UIApplicationSceneManifest` in `Info.plist`) start no Flutter engine during
a background push launch: the call rings and can be answered on the lock
screen, and its audio connects as soon as the app opens (tap the app button
on the CallKit screen). Apps on the classic `AppDelegate` lifecycle run Dart
during the background launch and connect immediately, as React Native apps
do.

### Call screen options

```dart
PiopiyOptions(callKeep: PiopiyCallKeepOptions(ios: PiopiyIosCallOptions(
  imageName: 'CallIcon',        // template image in the asset catalog
  ringtoneSound: 'ring.caf',    // file in the app bundle
  includesCallsInRecents: true,
)))
```

### Audio session

CallKit owns the AVAudioSession during incoming calls. The SDK runs LiveKit
in its `externalCallSystem` mode and starts the call's audio engine only
when CallKit activates the session (`didActivate`; a 1.5 s fallback covers a
delayed activation on a cold launch). Outbound calls aren't CallKit calls —
LiveKit manages their session. Every call starts on the earpiece. If you add
your own audio code, never reconfigure the session mid-call or the owners
will fight (clicks, one-way audio).
