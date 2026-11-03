# Changelog

All notable changes to this project are documented here. While on `0.x`, a
**minor** bump may contain breaking changes, always listed under
**Upgrading**.

## [0.2.0] - 2026-11-03

Feature parity with `@telecmi/piopiy-native` **0.26.6** (React Native): the
same methods, options, event names and event payloads.

### Added
- **In-call API**: `hold()` / `unHold()` / `onHold()`, `transfer(to)` /
  `teamTransfer(to)` (return the platform's response), `merge()` /
  `cancel()` for attended transfer, `getCallId()` / `getCallID()`,
  `isLogedIn()` / `isConnected()` / `onMute()` / `onSpeaker()`,
  `reRegister()`.
- **Push API**: `registerToken()` / `unregisterToken()` (for
  `autoPushToken: false`), `handleIncomingPush()` (+ the deprecated
  `livekitIncoming()` alias), `registerBackgroundPushHandler()`,
  `onOtherPush()`.
- **Options**: `ringTime` (default 40 s), `registerExpires` (default 120 s),
  `autoBackgroundPush`, `callKeep` (iOS template image / ringtone / Recents;
  Android ongoing-call notification), `livekitUrl`.
- **TeleCMI notify socket** (opened after login): `transfer`, `record` and
  `sbc_logout` events; a dropped transport emits `net_changed` and reconnects
  the SIP transport immediately.
- **Events**: `connected` / `disconnected`, `hold` / `unhold`, `dtmf`,
  `callStream`, `mediaFailed`, `RTC`, `RTCStats` (per second), `NETStats`,
  `missedCall`, `pushUnregistered`, `callkeepCancel`, `otherPush`; `once()`
  and `removeAllListeners()` on the emitter.
- **Ring timeout + missed calls**: a ringing call ends after `ringTime` and
  emits `missedCall` (`cancelled` / `ring_timeout`); a native backstop 5 s
  later covers a killed or parked app on both platforms, and a call missed
  while the app wasn't running is reported when it next starts.
- **SIP media monitoring**: ICE restart only after a 5 s `disconnected` grace
  or on `failed` (the 0.26.5 lost-audio-after-transfer fix), `RTC` events,
  `RTCStats`; outbound watchdog — `NETStats` 408 after 5 s without a SIP
  response, hang up and restart the UA after 10 s.
- **OS call screen** controls reach the SDK: its mute button mutes the
  microphone, and speaker-route changes are mirrored into `onSpeaker()`.
- **Android**: an ongoing-call foreground service (keeps the microphone
  available in the background), the app is brought up on answer and shown
  over the lock screen while a call is live (no `MainActivity` code).

### Fixed
- **Android push never reached FCM devices.** The SDK registered the Firebase
  Installation ID (`register()` / `onRegistered`) as the push token; TeleCMI's
  push server sends to an FCM registration token, so every send failed and the
  token was pruned as stale. It now registers `getToken()` /
  `onTokenRefresh`, like the React Native SDK.
- **Android killed-state answer connected silent.** The Answer event went to
  the FCM background isolate (which never joins calls) and nothing launched
  the app. Call events now reach only the app's isolate; answering launches
  the app, which replays the call and completes the answer.
- **Android, app backgrounded but alive**: a call pushed to the background
  isolate never reached the app's isolate — no `inComingCall`, and an answer
  stayed parked forever. The payload is now forwarded.
- **Android**: the background path registered a second calling account
  (`PIOPIY` beside the app name); one fixed account is used everywhere. A
  replayed payload no longer rings a second Telecom call.
- **iOS: PushKit and CallKit start at app launch**, natively. They were
  created only when Dart called `login()` — on a background push launch
  (no UI scene, so no Flutter engine) iOS had no registry to deliver to.
- **iOS audio**: CallKit owns the audio session — LiveKit runs in
  `externalCallSystem` mode and the engine starts on `didActivate` (1.5 s
  fallback), instead of activating the session itself and racing CallKit.
- **Calls answered on the loudspeaker** (LiveKit's default) — every call now
  starts on the earpiece.
- **Answer/cancel race** (the RN 0.24.1 fix): a cancel landing during the
  room join no longer resurrects the call with a late `answered`.
- `login` is re-emitted after a transport flap (was once per `login()`
  call); `loginFailed` codes match React Native (401 / 405 / 407); `logout`
  fires exactly once.
- SIP: the `piopiy_mobile` User-Agent, TeleCMI's STUN server, and a 120 s
  registration — as React Native.
- The native call screen no longer offers Hold / keypad buttons for incoming
  calls (they did nothing).
- `logout()` retries the push unregister once, as documented.
- The example's widget test referenced the template `MyApp`.

### Changed
- Event payloads follow React Native exactly: `inComingCall` is
  `{from, name?, team_name?, call_id, transfer, transfer_from?, transport}`;
  `login` / `trying` / `ringing` / `answered` / `ended` / `hangup` carry
  `{code, status, ...}`. The 0.1.0-only `mute` / `unMute` events are gone.
- `logout()` returns the push-unregister response; `speaker()` returns
  whether the route was applied.
- `PiopiyOptions.name` is optional: when null the call UI shows the app's
  name and outbound calls carry no SIP display name.
- The FCM background handler registers itself (`autoBackgroundPush`).
- Requires Flutter 3.38 / Dart 3.10 (the livekit_client 2.12+ floor). New
  dependency: `socket_io_client`.

### Upgrading from 0.1.0
1. `inComingCall`: read `call_id` / `team_name` (were `uuid` / `team`).
2. Other events: use the `{code, status}` payloads (0.1.0 sent `id` / `cause`).
3. `main()` no longer needs `FirebaseMessaging.onBackgroundMessage(...)` —
   keeping it is harmless. Apps that own the handler set
   `autoBackgroundPush: false` and call `piopiyBackgroundPushHandler(message)`.
4. Android: apps that passed a custom `name` in 0.1.0 had their calling
   account registered under that name; 0.2.0 uses one fixed account, which a
   device may ask the user to enable once (Settings → Calling accounts).

## [0.1.0] - 2026-11-02

First release — Flutter port of `@telecmi/piopiy-native` (React Native),
voice-only: outbound SIP over WSS (`sip_ua`), push-delivered inbound joined on
answer, CallKit + PushKit inside the plugin, Android Telecom system-managed
account, automatic push-token registration, the 45 s stale-ring guard, and the
example app.
