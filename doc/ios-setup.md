# PIOPIY Flutter — iOS Setup

The plugin owns **PushKit and CallKit** — there is no AppDelegate code to
write. Incoming calls are reported to CallKit natively, inside the push
callback, before Flutter even boots (an iOS 13+ requirement handled for you).

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

### Audio session

CallKit owns the AVAudioSession during calls. The SDK starts call audio only
after CallKit activates the session (the `didActivateAudioSession` signal) —
if you add your own audio code, never reconfigure the session mid-call or
the two owners will fight (clicks, one-way audio).
