// Constructor options — the React Native SDK's PiopiyOptions, field for field
// (web-only `autoplay` / `autoReboot` have no meaning on mobile and are not
// carried).

/// Options for [Piopiy]. Same names and defaults as `@telecmi/piopiy-native`.
class PiopiyOptions {
  const PiopiyOptions({
    this.name,
    this.debug = false,
    this.ringTime = 40,
    this.registerExpires = 120,
    this.autoPushToken = true,
    this.autoBackgroundPush = true,
    this.apiBase,
    this.callKeep = const PiopiyCallKeepOptions(),
    this.livekitUrl,
  });

  /// SIP display name for outbound calls, and the label of the native call
  /// UI / Android calling account (iOS: unless [PiopiyIosCallOptions.appName]
  /// overrides it). When null the callee sees no display name and the call UI
  /// shows the app's own name.
  final String? name;

  /// Print SDK diagnostics (also always emitted as the `log` event).
  final bool debug;

  /// Maximum time an incoming call rings, in seconds (default 40). The native
  /// layer adds a backstop 5 s later for when Dart is not running.
  final int ringTime;

  /// How long the SIP registration lives, in seconds (default 120). A shorter
  /// value clears a killed app's stale registration from the SBC faster.
  final int registerExpires;

  /// Fetch this device's push token (FCM / PushKit) and register it with
  /// TeleCMI after login, re-registering on rotation. Set false to manage the
  /// token yourself with [Piopiy.registerToken].
  final bool autoPushToken;

  /// Android: register the FCM background handler automatically so
  /// background/killed call pushes ring natively — no `main()` code needed.
  /// Android allows one background handler per app: set false if your app
  /// owns `FirebaseMessaging.onBackgroundMessage`, and call
  /// `piopiyBackgroundPushHandler(message)` from your handler.
  final bool autoBackgroundPush;

  /// Override the TeleCMI REST base (staging), e.g.
  /// `https://stagerest.telecmi.com/v2`. Defaults to production.
  final String? apiBase;

  /// Native call-UI configuration (the React Native SDK's `callKeep` option).
  final PiopiyCallKeepOptions callKeep;

  /// Advanced/testing only: media URL used if an inbound-call push arrives
  /// without one. In production the push always carries it.
  final String? livekitUrl;
}

/// Native call-UI configuration: CallKit on iOS, Telecom on Android.
class PiopiyCallKeepOptions {
  const PiopiyCallKeepOptions({
    this.ios = const PiopiyIosCallOptions(),
    this.android = const PiopiyAndroidCallOptions(),
  });

  final PiopiyIosCallOptions ios;
  final PiopiyAndroidCallOptions android;
}

/// CallKit provider configuration.
class PiopiyIosCallOptions {
  const PiopiyIosCallOptions({
    this.appName,
    this.imageName,
    this.ringtoneSound,
    this.includesCallsInRecents = true,
  });

  /// Name on the CallKit screen. Defaults to [PiopiyOptions.name].
  final String? appName;

  /// Template image (asset catalog name) shown on the CallKit screen.
  final String? imageName;

  /// Ringtone file in the app bundle, e.g. `ringtone.caf`.
  final String? ringtoneSound;

  /// Whether calls appear in the Phone app's Recents.
  final bool includesCallsInRecents;

  Map<String, dynamic> toMap() => {
        if (appName != null) 'appName': appName,
        if (imageName != null) 'imageName': imageName,
        if (ringtoneSound != null) 'ringtoneSound': ringtoneSound,
        'includesCallsInRecents': includesCallsInRecents,
      };
}

/// The ongoing-call notification Android shows while a call is live (the
/// foreground service that keeps the microphone available in the background).
class PiopiyAndroidCallOptions {
  const PiopiyAndroidCallOptions({
    this.channelId = 'com.piopiy.callkeep',
    this.channelName = 'PIOPIY incoming calls',
    this.notificationTitle = 'Call in progress',
    this.notificationIcon,
  });

  final String channelId;
  final String channelName;
  final String notificationTitle;

  /// Drawable resource name for the notification's small icon (e.g.
  /// `ic_stat_call`). Defaults to the app icon.
  final String? notificationIcon;

  Map<String, dynamic> toMap() => {
        'channelId': channelId,
        'channelName': channelName,
        'notificationTitle': notificationTitle,
        if (notificationIcon != null) 'notificationIcon': notificationIcon,
      };
}
