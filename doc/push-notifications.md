# PIOPIY Flutter — Push Notifications Guide

Incoming calls reach your app in **every** state — foreground, background,
killed, locked — through platform push: **PushKit** (iOS) and **FCM data
messages** (Android). The SDK handles the entire pipeline; this guide is the
credentials setup plus how the flow works.

## Getting your push credentials

Generate these once and upload them in the
[Connly dashboard](https://connle.telecmi.com) → Push Notifications. You
never paste them into your app.

| Platform | What to generate | Where |
| :--- | :--- | :--- |
| **iOS** | An **APNs Auth Key** (`.p8`) + its Key ID and your Team ID | Apple Developer → Certificates, Identifiers & Profiles → **Keys** → create a key with **APNs** enabled |
| **Android** | A Firebase **service account** JSON | Firebase Console → Project settings → **Service accounts** → *Generate new private key* (you also add `google-services.json` to the app — see [Android setup](android-setup.md)) |

## How it works

1. At `login()` the SDK fetches the device push token (PushKit / FCM) and
   registers it with TeleCMI — you'll see the `pushRegistered` event.
2. A call for your signed-in agent with the app not reachable triggers a
   push. The payload carries the call's identity **and its media ticket**
   (`{uuid, room, token, url, from}`), so answering works even from a cold
   start — there is no fragile one-shot INVITE to catch.
3. The native layer rings the **OS call screen** (CallKit / Telecom).
   The user answers there; the SDK joins the call's room and fires
   `answered`. Your Flutter UI just follows the events.
4. A `cancel_call` push dismisses the ring when the caller hangs up or the
   call is answered on another device.

## What you write

**Android** — one line in `main()` (killed-state ring from the background
isolate):

```dart
FirebaseMessaging.onBackgroundMessage(piopiyBackgroundPushHandler);
```

**iOS** — nothing. PushKit and CallKit live inside the plugin.

## Token lifecycle

- Registered automatically at `login()` (`pushRegistered` event)
- Unregistered at `logout()` — the device stops being woken
- Re-registered automatically on the next `login()` (the OS does not re-issue
  the token event, the SDK keeps it)
- Rotations (OS reissues the token) are registered automatically

## Built-in guards (so you don't learn these in production)

- **Stale invites dropped**: FCM redelivers undelivered data pushes for days;
  a redelivered invite would ring a long-dead call. Invites older than 45 s
  are dropped. Cancels always pass. APNs pushes expire server-side instead.
- **Signed-out devices refuse invites** — after `logout()`, a racing push
  cannot ring a ghost call.
- **Multi-device dismissal** — the cancel that your own answer triggers on
  sibling devices never kills the call you just answered.
- **Ring-timeout backstop** (iOS) — if the app is frozen by the OS after the
  push, a 40 s native timer clears the ring as missed rather than ringing
  forever.
