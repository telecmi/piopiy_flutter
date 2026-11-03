# PIOPIY Flutter SDK

Official **PIOPIY voice SDK for Flutter** — high-quality voice calls over the
TeleCMI network with the **native call UI** (iOS CallKit / Android Telecom)
for ring **and** in-call, plus push wake-ups so calls arrive with the app
backgrounded or killed.

Same architecture **and the same API** as `@telecmi/piopiy-native` (React
Native): outbound calls are SIP over WSS; incoming calls are push-delivered —
the payload carries the call's room and join token, so answering works even
from a cold start. Method names, event names and event payloads match the
React Native SDK, so an app's call logic ports over line by line.

## Install

```yaml
dependencies:
  piopiy_flutter: ^0.2.0
```

Then follow the platform guides: [Android](doc/android-setup.md) ·
[iOS](doc/ios-setup.md) · [Push notifications](doc/push-notifications.md).

## Quick start

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:piopiy_flutter/piopiy_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // Android push; skip for iOS-only apps
  runApp(const MyApp());
}

final piopiy = Piopiy(const PiopiyOptions(name: 'MyApp', debug: true));

piopiy.on('login', (_) => print('signed in'));
piopiy.on('inComingCall', (c) => print('incoming from ${c['name'] ?? c['from']}'));
piopiy.on('answered', (_) => print('connected'));
piopiy.on('ended', (_) => print('call over'));
piopiy.on('missedCall', (m) => print('missed call from ${m['from']}'));

await piopiy.login('5159_2224257', 'password', 'sbcsg.telecmi.com');

await piopiy.call('9199XXXXXXXX');          // outbound
piopiy.hold();                              // in-call controls
piopiy.sendDtmf('1');
final res = await piopiy.transfer('102');   // {..} from the platform
await piopiy.terminate();
```

Incoming calls ring on the **OS call screen** — the user answers there and
the SDK connects the call; your app needs no incoming-call UI (listen to the
events to update state). Push tokens are fetched and registered
automatically; Android's FCM background handler registers itself.

## API

| Method | Returns | Notes |
| :--- | :--- | :--- |
| `login(userId, password, [region])` | `Future<void>` | `region` = SBC host, default `sbcsg.telecmi.com` |
| `logout()` | `Future<Map>` | unregisters the push token first (retried once); returns the unregister response |
| `getAuthToken()` | `String?` | the agent's TeleCMI REST bearer, `null` until login completes |
| `call(to, {extraParam})` | `Future<void>` | `extraParam` → `X-cmi-extra_param` header |
| `answer()` / `reject()` / `terminate()` | `Future<void>` | |
| `mute()` / `unMute()` / `onMute()` | | |
| `speaker(on)` / `onSpeaker()` | `Future<bool>` / `bool` | calls start on the earpiece |
| `hold()` / `unHold()` / `onHold()` | | outbound calls |
| `sendDtmf(tone)` | | outbound calls (RFC 2833) |
| `transfer(to)` / `teamTransfer(to)` | `Future<Map>` | outbound calls; the platform's response or `{error}` |
| `merge()` / `cancel()` | | attended transfer: merge / return to the caller |
| `getCallId()` / `getCallID()` | `String?` | SIP Call-ID / TeleCMI call id of the live call |
| `isLogedIn()` / `isConnected()` | `bool` | |
| `reRegister()` | | re-send the SIP REGISTER if it lapsed |
| `registerToken({provider, token, platform})` / `unregisterToken()` | `Future<Map>` | only with `autoPushToken: false` |
| `handleIncomingPush(data)` | `bool` | only if your app owns the push pipeline |
| `registerBackgroundPushHandler()` | `bool` | Android; automatic by default |
| `onOtherPush(callback)` | | pushes that aren't TeleCMI calls |
| `on` / `once` / `off` / `removeAllListeners` / `emit` | | event emitter |

Top-level: `piopiyBackgroundPushHandler(RemoteMessage)` — call it from your
own FCM background handler if you set `autoBackgroundPush: false`.

### In-call controls

Outgoing calls are carried over SIP; incoming calls are delivered by push and
connected on answer (as on React Native):

| Control | Outgoing | Incoming |
| :--- | :---: | :---: |
| `answer()` / `reject()` | — | ✅ |
| `terminate()` | ✅ | ✅ |
| `mute()` / `unMute()` / `onMute()` (also the OS call screen's button) | ✅ | ✅ |
| `speaker(on)` / `onSpeaker()` (synced with the OS call screen) | ✅ | ✅ |
| `sendDtmf(tone)` | ✅ | ⛔ not yet |
| `hold()` / `unHold()` / `onHold()` | ✅ | ⛔ not yet |
| `transfer()` / `teamTransfer()` / `merge()` | ✅ | ⛔ not yet |

`reject()` declines locally: the native call screen is dismissed, and the
caller keeps ringing until the platform's no-answer timeout routes the call
onward.

## Options

```dart
Piopiy(const PiopiyOptions(
  name: 'MyApp',            // SIP display name + call-UI label
  debug: false,             // print diagnostics (always emitted as 'log')
  ringTime: 40,             // max ring, seconds (native backstop +5 s)
  registerExpires: 120,     // SIP registration lifetime, seconds
  autoPushToken: true,      // fetch + register the push token automatically
  autoBackgroundPush: true, // Android: register the FCM background handler
  apiBase: null,            // e.g. 'https://stagerest.telecmi.com/v2'
  callKeep: PiopiyCallKeepOptions(
    ios: PiopiyIosCallOptions(imageName: 'CallIcon', ringtoneSound: 'ring.caf'),
    android: PiopiyAndroidCallOptions(notificationTitle: 'Call in progress'),
  ),
));
```

## Events

| Event | Payload |
| :--- | :--- |
| `connected` / `disconnected` | `{code, status}` — SIP transport |
| `login` / `logout` | `{code: 200, status}` |
| `loginFailed` | `{code, status}` — 401 invalid user · 405 too many connections · 407 invalid IP / token generation failed |
| `sbc_logout` | the server ended this session (signed in elsewhere) |
| `net_changed` | `{code: 400, msg}` — transport dropped; the SDK reconnects |
| `inComingCall` | `{from, name?, team_name?, call_id, transfer, transfer_from?, transport: 'push'}` |
| `trying` / `ringing` | `{code, status, type: 'outgoing' \| 'incoming'}` |
| `answered` | `{code: 200, status, transport?}` |
| `hold` / `unhold` | `{code, status, whom: 'myself' \| 'other'}` |
| `ended` / `hangup` | `{code, status, reason?, transport?}` — remote / local end |
| `missedCall` | `{uuid, from, reason: 'cancelled' \| 'ring_timeout', transport}` |
| `callStream` | `{code: 200, status: MediaStream}` |
| `mediaFailed` | `{code: 415, status}` — microphone unavailable |
| `dtmf` | `{code, dtmf, type}` |
| `RTC` | `{state: 'connected' \| 'disconnected', msg}` |
| `RTCStats` | `{delay, jitter, packetLostRate, fractionLost, codec, network, ...}` per second |
| `NETStats` | `{code: 408, msg}` — no SIP response 5 s after dialing |
| `transfer` | `{state, code?, transfer_id?, to?, type?, reason?, ...}` |
| `record` | `{state: 'start' \| 'stop', ...}` |
| `pushRegistered` / `pushUnregistered` | the TeleCMI response |
| `otherPush` | a push that isn't a TeleCMI call |
| `callkeepCancel` | `{uuid, reason}` — a ringing call was dismissed |
| `error` | `{code, status}` |
| `log` | Flutter only: every internal SDK line |

## Documentation

- [Android setup](doc/android-setup.md) — Firebase checklist, permissions, first-run calling account
- [iOS setup](doc/ios-setup.md) — Xcode capabilities, APNs key, audio-session rules
- [Push notifications](doc/push-notifications.md) — credentials, how the flow works, built-in guards
- [Troubleshooting](doc/troubleshooting.md) — every field-diagnosed symptom and its fix
- [Changelog](CHANGELOG.md)

## License

Apache-2.0 © [TeleCMI](https://telecmi.com)
