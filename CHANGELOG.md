# Changelog

All notable changes to this project are documented here.

## [0.1.0] - 2026-11-02

First release — Flutter port of `@telecmi/piopiy-native` (React Native),
voice-only, carrying every production lesson from that SDK:

### Added
- **Voice calls over the TeleCMI network** with the native OS call UI for
  ring and in-call (iOS CallKit, Android Telecom system-managed account).
- **Outbound**: SIP over WSS (`sip_ua`, the Dart jsSIP port). The INVITE
  waits for ICE gathering — the zero-candidates/SIP 488 class of failure
  cannot happen.
- **Inbound**: push-delivered — the payload carries the call's room and join
  token, and the SDK joins on answer. Retryable by design; killed-state
  answers work (events are queued natively and replayed when Dart attaches).
- **iOS PushKit + CallKit live inside the plugin** — apps write zero native
  code (no AppDelegate wiring, unlike React Native). The call is reported to
  CallKit synchronously inside the push callback (iOS 13+ requirement),
  actions are fulfilled immediately, and a 40 s native ring-timeout backstop
  covers a parked JS thread.
- **Android Telecom hard-won rules built in**: the system-managed phone
  account is never cycled (cycling destroys user enablement); the connection
  goes ACTIVE inside `onAnswer` natively, so audio routing never waits for
  Dart (the killed-state silent-call bug class).
- **Automatic push-token registration** at login (FCM on Android, PushKit on
  iOS), re-registration after logout→login, and unregistration at logout.
- **Stale-ring guard**: FCM redelivers undelivered data pushes for days —
  call invites older than 45 s are dropped (cancels always pass).
- **API parity with the React Native SDK**: `login` / `logout` / `call` /
  `answer` / `reject` / `terminate` / `mute` / `unMute` / `speaker` /
  `sendDtmf` / `getAuthToken`, and the same event names.
- Example app with saved credentials and automatic sign-in.
