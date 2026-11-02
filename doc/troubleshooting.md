# PIOPIY Flutter — Troubleshooting

Every entry below is a field-diagnosed failure from TeleCMI production SDKs —
if your symptom is here, the fix is known.

## Incoming calls

| Symptom | Fix |
| :--- | :--- |
| **Push arrives (log shows it) but no ring UI** (Android) | The app's **calling account** is disabled. Settings → search "Calling accounts" (or Phone app → Settings → Calling accounts) → enable your app. One-time. |
| **No incoming calls when the app is killed — Oppo / OnePlus / Xiaomi / vivo** | OEM battery management blocks the FCM wake-up: set the app's battery usage to **Unrestricted** and enable **Auto-start**. Advise your users in-app. |
| **No calls at all, no `pushRegistered` in the log** | The device never got a push token: Android — check `google-services.json` and the gradle plugin ([Android setup](android-setup.md)); iOS — check the Push Notifications capability and VoIP background mode. The SDK logs a warning 10 s after login when no token appeared. |
| **Calls ring on another device, not this one** | Both devices are signed in as the **same agent** — the platform routes to one registration. Use distinct agents per device. |
| **A call that already ended rings again minutes later** | Can't happen — stale FCM redeliveries are dropped by the SDK (45 s window). If you see it, capture the log and report it. |
| **iOS: pushes work in debug but not TestFlight** | Store builds get **production** APNs tokens. The APNs key uploaded to the Connly dashboard must be production-capable (sandbox-only keys exist). |

## Audio

| Symptom | Fix |
| :--- | :--- |
| **Answered from killed state, silent both ways** (Android) | Should not happen — the SDK activates the Telecom connection natively at answer. If reproduced: check mic permission was granted *before* the call (a permission dialog cannot show over the lock screen), and capture `adb logcat`. |
| **No audio on emulator/simulator** | Emulators don't do real call audio reliably — test voice on physical devices. |
| **One-way or clicking audio (iOS)** | Another component reconfigured the AVAudioSession mid-call. CallKit + the SDK own the session — remove app-side `AVAudioSession` calls during calls. |

## Build

| Symptom | Fix |
| :--- | :--- |
| `No matching client found for package name` | Your `google-services.json` doesn't contain your `applicationId` — regenerate from Firebase after adding that package name. |
| `requires libraries … compile against version 36` | Set your app's `compileSdk` to 36+. |
| CocoaPods errors about missing modules | Run `pod install` from `ios/` with CocoaPods ≥ 1.13, then build from the `.xcworkspace`. |

## Sign-in

| Symptom | Fix |
| :--- | :--- |
| `loginFailed {code: 407}` | The REST login (`/user/login`) rejected the credentials — token generation failed. Check agent id/password; the SIP register may still succeed independently. |
| `loginFailed` with a SIP cause | Wrong password/agent for the SBC, or the region hostname is wrong. The region is the SBC host, e.g. `sbcsg.telecmi.com`. |

## Getting a useful log

Construct the SDK with `debug: true` and listen to the `log` event — every
internal step (REST, SIP, LiveKit, push, native events) is emitted there.
For killed-state issues on Android, `adb logcat | grep -E "PiopiyCall|flutter"`
captures both the native Telecom layer and Dart.
