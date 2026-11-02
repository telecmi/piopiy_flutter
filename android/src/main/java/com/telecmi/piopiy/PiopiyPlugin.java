package com.telecmi.piopiy;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Flutter plugin entry point. Dart talks to the Telecom layer through
 * MethodChannel 'com.telecmi.piopiy/call'; native call events reach Dart
 * through EventChannel 'com.telecmi.piopiy/events' (queued until Dart
 * attaches — cold answers included).
 */
public class PiopiyPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private MethodChannel channel;
    private EventChannel events;
    private Context context;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private String appName = "PIOPIY";

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
        CallBridge.detach();
    }

    // ---- EventChannel ----

    @Override
    public void onListen(Object args, EventChannel.EventSink sink) {
        CallBridge.attach(event -> mainHandler.post(() -> sink.success(event)));
    }

    @Override
    public void onCancel(Object args) {
        CallBridge.detach();
    }

    // ---- MethodChannel ----

    @Override
    @SuppressWarnings("unchecked")
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "setup": {
                String name = call.argument("appName");
                if (name != null && !name.isEmpty()) appName = name;
                PiopiyConnectionService.ensureAccount(context, appName);
                result.success(null);
                break;
            }
            case "displayIncomingCall": {
                String uuid = call.argument("uuid");
                String handle = call.argument("handle");
                String callerName = call.argument("callerName");
                Map<String, Object> payload = call.argument("payload");
                if (payload != null && uuid != null) {
                    CallBridge.storePayload(uuid, new HashMap<>(payload));
                }
                if (uuid != null) {
                    PiopiyConnectionService.displayIncomingCall(
                            context, appName, uuid,
                            handle == null ? "Incoming call" : handle,
                            callerName == null ? "" : callerName);
                }
                result.success(null);
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
            case "setMuted": {
                String uuid = call.argument("uuid");
                Boolean muted = call.argument("muted");
                if (uuid != null) {
                    PiopiyConnectionService.setMuted(uuid, Boolean.TRUE.equals(muted));
                }
                result.success(null);
                break;
            }
            default:
                result.notImplemented();
        }
    }
}
