package com.telecmi.piopiy;

import android.annotation.SuppressLint;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.telecom.CallAudioState;
import android.telecom.Connection;
import android.telecom.ConnectionRequest;
import android.telecom.ConnectionService;
import android.telecom.DisconnectCause;
import android.telecom.PhoneAccount;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;
import android.util.Log;

import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 * Port of the telecmi callkeep fork's voice path: ONE system-managed
 * (CALL_PROVIDER) phone account — Android's own call UI handles ring AND
 * in-call, exactly like the React Native SDK's voice calls.
 *
 * Hard-won rules carried over from the fork:
 *  - NEVER unregister/re-register (cycle) the system-managed account: that
 *    destroys its user enablement and incoming calls silently die until the
 *    user re-enables it in phone settings (the callkeep 4.4.2 incident). The
 *    handle id is fixed, so the account never changes identity either.
 *  - setActive() inside onAnswer, NOT from Dart later: Telecom's audio route
 *    only engages on ACTIVE, and on a cold answer Dart runs seconds later —
 *    that gap was the RN SDK's killed-state silent-call bug.
 *  - Answering brings the app to the foreground (callkeep backToForeground),
 *    so a killed app launches into the call and joins its room.
 *  - A native ring timeout ends a ring nobody cancels (device offline after
 *    the push; Dart not running).
 */
public class PiopiyConnectionService extends ConnectionService {

    private static final String TAG = "PiopiyCall";
    static final String EXTRA_UUID = "com.telecmi.piopiy.UUID";
    static final String EXTRA_NAME = "com.telecmi.piopiy.NAME";
    static final String EXTRA_FROM = "com.telecmi.piopiy.FROM";
    private static final String ACCOUNT_ID = "PIOPIY";
    private static final int NOTIFICATION_ID = 0x7C3D;

    /** Lock-screen / foreground hooks for the plugin (main thread). */
    interface LiveCallListener { void onLiveCallChanged(boolean live); }

    private static final Map<String, PiopiyConnection> connections = new HashMap<>();
    // Rings requested but not yet created by Telecom (addNewIncomingCall is
    // asynchronous) — a second request in that window would ring twice.
    private static final Set<String> pendingRings = new HashSet<>();
    private static PhoneAccountHandle handle;
    private static PiopiyConnectionService instance;
    private static LiveCallListener liveCallListener;
    private static final Handler main = new Handler(Looper.getMainLooper());

    private boolean inForeground = false;

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
    }

    @Override
    public void onDestroy() {
        if (instance == this) instance = null;
        super.onDestroy();
    }

    static void setLiveCallListener(LiveCallListener l) {
        liveCallListener = l;
    }

    private static void notifyLiveCall() {
        final boolean live = hasLiveCall();
        final LiveCallListener l = liveCallListener;
        if (l != null) main.post(() -> l.onLiveCallChanged(live));
    }

    static synchronized boolean hasLiveCall() {
        for (PiopiyConnection c : connections.values()) {
            if (c.answered) return true;
        }
        return false;
    }

    static synchronized PhoneAccountHandle ensureAccount(Context context) {
        TelecomManager tm = (TelecomManager) context.getSystemService(Context.TELECOM_SERVICE);
        if (handle == null) {
            ComponentName cn = new ComponentName(context, PiopiyConnectionService.class);
            handle = new PhoneAccountHandle(cn, ACCOUNT_ID);
        }
        PhoneAccount account = new PhoneAccount.Builder(handle, CallSettings.accountLabel(context))
                .setCapabilities(PhoneAccount.CAPABILITY_CALL_PROVIDER)
                .build();
        try {
            tm.registerPhoneAccount(account); // idempotent update — never cycled
        } catch (Exception e) {
            Log.w(TAG, "registerPhoneAccount failed", e);
        }
        return handle;
    }

    /** Ring the OS incoming-call UI. Returns false when it couldn't. */
    @SuppressLint("MissingPermission")
    static synchronized boolean displayIncomingCall(Context context, String uuid,
                                                    String handleNumber, String name) {
        String id = uuid.toLowerCase();
        if (connections.containsKey(id) || pendingRings.contains(id)) {
            Log.d(TAG, "displayIncomingCall ignored — call already exists: " + id);
            return true;
        }
        PhoneAccountHandle h = ensureAccount(context);
        Bundle extras = new Bundle();
        extras.putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                Uri.fromParts(PhoneAccount.SCHEME_TEL, handleNumber, null));
        extras.putString(EXTRA_UUID, id);
        extras.putString(EXTRA_NAME, name);
        extras.putString(EXTRA_FROM, handleNumber);
        TelecomManager tm = (TelecomManager) context.getSystemService(Context.TELECOM_SERVICE);
        try {
            tm.addNewIncomingCall(h, extras);
            pendingRings.add(id);
            Log.d(TAG, "ringing " + id + " from " + handleNumber);
            return true;
        } catch (SecurityException e) {
            // Account disabled by the user/OEM — the one-time enable in phone
            // settings (documented in the troubleshooting guide).
            Log.e(TAG, "addNewIncomingCall refused — calling account disabled?", e);
            return false;
        }
    }

    static synchronized void setCallActive(String uuid) {
        PiopiyConnection c = connections.get(uuid.toLowerCase());
        if (c != null && c.getState() != Connection.STATE_ACTIVE) c.setActive();
    }

    static synchronized void answerCall(String uuid) {
        PiopiyConnection c = connections.get(uuid.toLowerCase());
        if (c != null) c.onAnswer();
    }

    /** [reason]: 1 local, 2 remote, 3 missed, 6 rejected. */
    static synchronized void endCall(String uuid, int reason) {
        PiopiyConnection c = connections.remove(uuid.toLowerCase());
        CallBridge.dropPayload(uuid);
        if (c == null) return;
        int cause = reason == 1 ? DisconnectCause.LOCAL
                : reason == 3 ? DisconnectCause.MISSED
                : reason == 6 ? DisconnectCause.REJECTED
                : DisconnectCause.REMOTE;
        c.ended = true;
        c.setDisconnected(new DisconnectCause(cause));
        c.destroy();
        afterCallRemoved();
    }

    /** A cancel push: end the call only while it is still ringing. */
    static synchronized void endIfRinging(String uuid) {
        PiopiyConnection c = connections.get(uuid.toLowerCase());
        if (c == null) {
            CallBridge.dropPayload(uuid);
            return;
        }
        if (c.answered) return; // answered here — the cancel is our own dismissal echo
        endCall(uuid, 3);
    }

    static synchronized void setAudioRoute(String uuid, boolean speaker) {
        PiopiyConnection c = connections.get(uuid.toLowerCase());
        if (c == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        c.setAudioRoute(speaker ? CallAudioState.ROUTE_SPEAKER : CallAudioState.ROUTE_WIRED_OR_EARPIECE);
    }

    private static void afterCallRemoved() {
        PiopiyConnectionService s = instance;
        if (s != null && !hasLiveCall()) s.stopCallForeground();
        notifyLiveCall();
    }

    @Override
    public Connection onCreateIncomingConnection(PhoneAccountHandle account, ConnectionRequest request) {
        Bundle extras = request.getExtras();
        if (extras == null) extras = new Bundle();
        String uuid = extras.getString(EXTRA_UUID, "");
        String name = extras.getString(EXTRA_NAME, "");
        String from = extras.getString(EXTRA_FROM, "");
        Uri address = extras.getParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS);

        final PiopiyConnection connection = new PiopiyConnection(this, uuid, from, name);
        // Mute only: hold/DTMF on inbound calls need platform call control
        // (as on React Native), so the OS UI doesn't offer a Hold that does
        // nothing.
        connection.setConnectionCapabilities(Connection.CAPABILITY_MUTE);
        if (address != null) {
            connection.setAddress(address, TelecomManager.PRESENTATION_ALLOWED);
        }
        if (!name.isEmpty()) {
            connection.setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED);
        }
        connection.setAudioModeIsVoip(true);
        connection.setRinging();
        synchronized (PiopiyConnectionService.class) {
            pendingRings.remove(uuid.toLowerCase());
            connections.put(uuid.toLowerCase(), connection);
        }

        // Native ring timeout: the Dart timer dies with a background isolate,
        // and the cancel push never arrives if the device lost its network.
        final int timeoutSec = CallSettings.ringTimeoutSeconds(this);
        main.postDelayed(() -> {
            synchronized (PiopiyConnectionService.class) {
                if (connection.answered || connection.ended
                        || connections.get(connection.uuid) != connection) return;
                Log.w(TAG, "ring timeout (" + timeoutSec + " s) — ending unanswered call " + connection.uuid);
                connections.remove(connection.uuid);
                connection.ended = true;
                connection.setDisconnected(new DisconnectCause(DisconnectCause.MISSED));
                connection.destroy();
                CallBridge.dropPayload(connection.uuid);
            }
            Map<String, Object> ev = new HashMap<>();
            ev.put("event", "end");
            ev.put("uuid", connection.uuid);
            ev.put("reason", "ring_timeout");
            ev.put("from", connection.from);
            CallBridge.emit(ev);
        }, timeoutSec * 1000L);
        return connection;
    }

    @Override
    public void onCreateIncomingConnectionFailed(PhoneAccountHandle account, ConnectionRequest request) {
        Bundle extras = request.getExtras();
        String uuid = extras != null ? extras.getString(EXTRA_UUID, "") : "";
        synchronized (PiopiyConnectionService.class) {
            pendingRings.remove(uuid.toLowerCase());
        }
        Log.w(TAG, "onCreateIncomingConnectionFailed for " + uuid);
        Map<String, Object> ev = new HashMap<>();
        ev.put("event", "end");
        ev.put("uuid", uuid.toLowerCase());
        ev.put("reason", "failed");
        CallBridge.emit(ev);
        super.onCreateIncomingConnectionFailed(account, request);
    }

    // ---- ongoing-call foreground service (callkeep's foregroundService) ----

    /** Keeps the microphone available while the app is in the background. */
    void startCallForeground(String callerName) {
        if (inForeground) return;
        try {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            String channelId = CallSettings.channelId(this);
            Notification.Builder b;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                NotificationChannel channel = new NotificationChannel(channelId,
                        CallSettings.channelName(this), NotificationManager.IMPORTANCE_LOW);
                nm.createNotificationChannel(channel);
                b = new Notification.Builder(this, channelId);
            } else {
                b = new Notification.Builder(this);
            }
            b.setContentTitle(CallSettings.notificationTitle(this))
                    .setSmallIcon(CallSettings.notificationIcon(this))
                    .setOngoing(true)
                    .setCategory(Notification.CATEGORY_CALL);
            if (callerName != null && !callerName.isEmpty()) b.setContentText(callerName);
            Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
            if (launch != null) {
                launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
                b.setContentIntent(PendingIntent.getActivity(this, 0, launch,
                        PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
            }
            Notification n = b.build();
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                try {
                    startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                            | ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
                } catch (Exception e) {
                    // Microphone type refused from the background — the
                    // phone-call type alone still keeps the call alive.
                    startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL);
                }
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL);
            } else {
                startForeground(NOTIFICATION_ID, n);
            }
            inForeground = true;
        } catch (Exception e) {
            Log.w(TAG, "foreground service start failed", e);
        }
    }

    void stopCallForeground() {
        if (!inForeground) return;
        inForeground = false;
        try {
            stopForeground(STOP_FOREGROUND_REMOVE);
        } catch (Exception ignored) { }
    }

    /** callkeep's backToForeground: bring the app's UI up for the answered call. */
    private void bringAppToFront() {
        try {
            Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
            if (launch == null) return;
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                    | Intent.FLAG_ACTIVITY_SINGLE_TOP
                    | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
            startActivity(launch);
        } catch (Exception e) {
            Log.w(TAG, "bringAppToFront failed", e);
        }
    }

    /** One Telecom connection = one call. Events flow to Dart via CallBridge. */
    static class PiopiyConnection extends Connection {
        private final PiopiyConnectionService service;
        final String uuid;
        final String from;
        final String name;
        volatile boolean answered = false;
        volatile boolean ended = false;
        private Boolean lastMuted = null;
        private Integer lastRoute = null;

        PiopiyConnection(PiopiyConnectionService service, String uuid, String from, String name) {
            this.service = service;
            this.uuid = uuid.toLowerCase();
            this.from = from;
            this.name = name;
        }

        @Override
        public void onAnswer() {
            if (answered || ended) return; // some OEMs call onAnswer twice
            answered = true;
            setAudioModeIsVoip(true);
            // ACTIVE here, synchronously — audio routing must not wait for Dart.
            setActive();
            service.startCallForeground(name.isEmpty() ? from : name);
            CallBridge.emit("answer", uuid);
            service.bringAppToFront();
            notifyLiveCall();
        }

        @Override
        public void onAnswer(int videoState) {
            onAnswer();
        }

        @Override
        public void onDisconnect() {
            endedByUser(DisconnectCause.LOCAL);
        }

        @Override
        public void onReject() {
            endedByUser(DisconnectCause.REJECTED);
        }

        @Override
        public void onAbort() {
            endedByUser(DisconnectCause.REJECTED);
        }

        private void endedByUser(int cause) {
            if (ended) return;
            ended = true;
            setDisconnected(new DisconnectCause(cause));
            synchronized (PiopiyConnectionService.class) {
                if (connections.get(uuid) == this) connections.remove(uuid);
            }
            CallBridge.dropPayload(uuid);
            destroy();
            Map<String, Object> ev = new HashMap<>();
            ev.put("event", "end");
            ev.put("uuid", uuid);
            ev.put("reason", "user");
            CallBridge.emit(ev);
            afterCallRemoved();
        }

        @Override
        public void onHold() {
            Map<String, Object> ev = new HashMap<>();
            ev.put("event", "hold");
            ev.put("uuid", uuid);
            ev.put("hold", true);
            CallBridge.emit(ev);
        }

        @Override
        public void onUnhold() {
            Map<String, Object> ev = new HashMap<>();
            ev.put("event", "hold");
            ev.put("uuid", uuid);
            ev.put("hold", false);
            CallBridge.emit(ev);
        }

        @Override
        public void onPlayDtmfTone(char c) {
            Map<String, Object> ev = new HashMap<>();
            ev.put("event", "dtmf");
            ev.put("uuid", uuid);
            ev.put("digits", String.valueOf(c));
            CallBridge.emit(ev);
        }

        @Override
        public void onCallAudioStateChanged(CallAudioState state) {
            if (state == null) return;
            // The OS call screen's Mute button: mirror it into the media
            // engine, or the user believes they're muted while still heard.
            if (lastMuted == null || lastMuted != state.isMuted()) {
                boolean first = lastMuted == null;
                lastMuted = state.isMuted();
                if (!first || state.isMuted()) {
                    Map<String, Object> ev = new HashMap<>();
                    ev.put("event", "mute");
                    ev.put("uuid", uuid);
                    ev.put("muted", state.isMuted());
                    CallBridge.emit(ev);
                }
            }
            int route = state.getRoute();
            if (lastRoute == null || lastRoute != route) {
                lastRoute = route;
                Map<String, Object> ev = new HashMap<>();
                ev.put("event", "audioRoute");
                ev.put("output", CallAudioState.audioRouteToString(route));
                ev.put("speaker", route == CallAudioState.ROUTE_SPEAKER);
                CallBridge.emit(ev);
            }
        }
    }
}
