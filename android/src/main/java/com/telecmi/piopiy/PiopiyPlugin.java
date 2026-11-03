package com.telecmi.piopiy;

import android.app.Activity;
import android.app.KeyguardManager;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.WindowManager;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Flutter plugin entry point. Dart talks to the Telecom layer through
 * MethodChannel 'com.telecmi.piopiy/call'; native call events reach Dart
 * through EventChannel 'com.telecmi.piopiy/events' (queued until the app's
 * isolate attaches — cold answers included). One instance per Flutter engine:
 * the app's engine listens; the FCM background engine only calls in.
 */
public class PiopiyPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler,
        EventChannel.StreamHandler, ActivityAware {

    private MethodChannel channel;
    private EventChannel events;
    private Context context;
    private Activity activity;
    private boolean lockFlagsApplied = false;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "com.telecmi.piopiy/call");
        channel.setMethodCallHandler(this);
        events = new EventChannel(binding.getBinaryMessenger(), "com.telecmi.piopiy/events");
        events.setStreamHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        events.setStreamHandler(null);
        CallBridge.detach(this);
    }

    // ---- EventChannel ----

    @Override
    public void onListen(Object args, EventChannel.EventSink sink) {
        CallBridge.attach(this, event -> mainHandler.post(() -> sink.success(event)));
    }

    @Override
    public void onCancel(Object args) {
        CallBridge.detach(this);
    }

    // ---- ActivityAware: show the call over the lock screen ----

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
        lockFlagsApplied = false;
        PiopiyConnectionService.setLiveCallListener(this::applyLockScreenFlags);
        // A killed app launched by an answer: the call is already live.
        if (PiopiyConnectionService.hasLiveCall()) applyLockScreenFlags(true);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        PiopiyConnectionService.setLiveCallListener(null);
        activity = null;
    }

    /**
     * While a call is live, the app's UI may show over the keyguard and wake
     * the screen. Only flags this plugin set are cleared afterwards — an app
     * that shows over the lock screen permanently keeps doing so.
     */
    private void applyLockScreenFlags(boolean live) {
        Activity a = activity;
        if (a == null || live == lockFlagsApplied) return;
        lockFlagsApplied = live;
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                a.setShowWhenLocked(live);
                a.setTurnScreenOn(live);
                if (live) {
                    KeyguardManager km = (KeyguardManager) a.getSystemService(Context.KEYGUARD_SERVICE);
                    if (km != null) km.requestDismissKeyguard(a, null);
                }
            } else {
                int flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                        | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                        | WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD;
                if (live) a.getWindow().addFlags(flags);
                else a.getWindow().clearFlags(flags);
            }
        } catch (Exception ignored) { }
    }

    // ---- MethodChannel ----

    /** "Priya Sharma — support3", "+91… — support3", or the number. */
    private static String display(Map<String, Object> p, String from) {
        String name = str(p.get("name"));
        String team = str(p.get("team"));
        if (team.isEmpty()) team = str(p.get("team_name"));
        String primary = name.isEmpty() ? from : name;
        return team.isEmpty() ? primary : primary + " — " + team;
    }

    private static String str(Object o) {
        return o == null ? "" : o.toString().trim();
    }

    @Override
    @SuppressWarnings("unchecked")
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "setup": {
                Object args = call.arguments;
                if (args instanceof Map) CallSettings.save(context, (Map<String, Object>) args);
                PiopiyConnectionService.ensureAccount(context);
                result.success(null);
                break;
            }
            case "displayIncomingCall": {
                String uuid = call.argument("uuid");
                String handle = call.argument("handle");
                String callerName = call.argument("callerName");
                Map<String, Object> payload = call.argument("payload");
                if (uuid != null) {
                    if (payload != null) CallBridge.storePayload(uuid, new HashMap<>(payload));
                    PiopiyConnectionService.displayIncomingCall(
                            context, uuid,
                            handle == null ? "Incoming call" : handle,
                            callerName == null ? "" : callerName);
                }
                result.success(null);
                break;
            }
            case "backgroundPush": {
                Map<String, Object> payload = call.argument("payload");
                result.success(payload != null && handleBackgroundPush(new HashMap<>(payload)));
                break;
            }
            case "setCallActive": {
                String uuid = call.argument("uuid");
                if (uuid != null) PiopiyConnectionService.setCallActive(uuid);
                result.success(null);
                break;
            }
            case "answerCall": {
                String uuid = call.argument("uuid");
                if (uuid != null) PiopiyConnectionService.answerCall(uuid);
                result.success(null);
                break;
            }
            case "endCall": {
                String uuid = call.argument("uuid");
                Integer reason = call.argument("reason");
                if (uuid != null) {
                    PiopiyConnectionService.endCall(uuid, reason == null ? 2 : reason);
                }
                result.success(null);
                break;
            }
            case "setMuted":
                // Telecom has no API to push mute state into the OS call
                // screen; the media engine (Dart) owns mute.
                result.success(null);
                break;
            case "setAudioRoute": {
                String uuid = call.argument("uuid");
                Boolean speaker = call.argument("speaker");
                if (uuid != null) {
                    PiopiyConnectionService.setAudioRoute(uuid, Boolean.TRUE.equals(speaker));
                }
                result.success(null);
                break;
            }
            case "setSignedOut": {
                Boolean signedOut = call.argument("signedOut");
                CallSettings.setSignedOut(context, Boolean.TRUE.equals(signedOut));
                result.success(null);
                break;
            }
            default:
                result.notImplemented();
        }
    }

    /**
     * A call push from the FCM background isolate (app backgrounded or
     * killed): ring or dismiss the OS call UI here, and hand the payload to
     * the app's isolate (now if it runs, replayed when it starts otherwise).
     */
    private boolean handleBackgroundPush(Map<String, Object> payload) {
        String type = str(payload.get("type"));
        String uuid = str(payload.get("uuid"));
        if (uuid.isEmpty()) uuid = str(payload.get("call_id"));
        if (uuid.isEmpty()) return false;
        uuid = uuid.toLowerCase();

        if ("cancel_call".equals(type)) {
            PiopiyConnectionService.endIfRinging(uuid);
            CallBridge.forwardPush(payload, true);
            return true;
        }
        if (!type.isEmpty() && !"incoming_call".equals(type)) return false;
        if (CallSettings.isSignedOut(context)) {
            // Signed out: a payload alone could join the call — refuse it.
            return false;
        }
        // 'from' is an FCM-reserved data key: the caller arrives as 'caller'.
        String from = str(payload.get("caller"));
        if (from.isEmpty()) from = str(payload.get("from"));
        if (from.isEmpty()) from = "Incoming call";
        CallBridge.storePayload(uuid, payload);
        boolean rang = PiopiyConnectionService.displayIncomingCall(context, uuid, from, display(payload, from));
        Map<String, Object> stored = CallBridge.getPayload(uuid);
        if (stored != null) CallBridge.forwardPush(stored, false);
        return rang;
    }
}
