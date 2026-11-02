package com.telecmi.piopiy;

import android.annotation.SuppressLint;
import android.content.ComponentName;
import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
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
import java.util.Map;

/**
 * Lean port of the telecmi callkeep fork's voice path: ONE system-managed
 * (CALL_PROVIDER) phone account — Android's own call UI handles ring AND
 * in-call, exactly like the React Native SDK's voice calls.
 *
 * Hard-won rules carried over from the fork:
 *  - NEVER unregister/re-register (cycle) the system-managed account: that
 *    destroys its user enablement and incoming calls silently die until the
 *    user re-enables it in phone settings (the callkeep 4.4.0 incident).
 *  - setActive() inside onAnswer, NOT from Dart later: Telecom's audio route
 *    only engages on ACTIVE, and on a cold answer Dart runs seconds later —
 *    that gap was the RN SDK's killed-state silent-call bug (fixed in 4.5.0).
 */
public class PiopiyConnectionService extends ConnectionService {

    private static final String TAG = "PiopiyCall";
    static final String EXTRA_UUID = "com.telecmi.piopiy.UUID";
    static final String EXTRA_NAME = "com.telecmi.piopiy.NAME";

    private static final Map<String, PiopiyConnection> connections = new HashMap<>();
    private static PhoneAccountHandle handle;

    static synchronized PhoneAccountHandle ensureAccount(Context context, String appName) {
        TelecomManager tm = (TelecomManager) context.getSystemService(Context.TELECOM_SERVICE);
        if (handle == null) {
            ComponentName cn = new ComponentName(context, PiopiyConnectionService.class);
            handle = new PhoneAccountHandle(cn, appName);
        }
        PhoneAccount account = new PhoneAccount.Builder(handle, appName)
                .setCapabilities(PhoneAccount.CAPABILITY_CALL_PROVIDER)
                .build();
        try {
            tm.registerPhoneAccount(account); // idempotent — never cycled
        } catch (Exception e) {
            Log.w(TAG, "registerPhoneAccount failed", e);
        }
        return handle;
    }

    @SuppressLint("MissingPermission")
    static synchronized void displayIncomingCall(Context context, String appName,
                                                 String uuid, String handleNumber, String name) {
        PhoneAccountHandle h = ensureAccount(context, appName);
        PiopiyConnection existing = connections.get(uuid.toLowerCase());
        if (existing != null && (existing.getState() == Connection.STATE_ACTIVE || existing.answered)) {
            Log.d(TAG, "displayIncomingCall ignored — already answered/active: " + uuid);
            return;
        }
        Bundle extras = new Bundle();
        extras.putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                Uri.fromParts(PhoneAccount.SCHEME_TEL, handleNumber, null));
        extras.putString(EXTRA_UUID, uuid.toLowerCase());
        extras.putString(EXTRA_NAME, name);
        TelecomManager tm = (TelecomManager) context.getSystemService(Context.TELECOM_SERVICE);
        try {
            tm.addNewIncomingCall(h, extras);
            Log.d(TAG, "ringing " + uuid + " from " + handleNumber);
        } catch (SecurityException e) {
            // Account disabled by the user/OEM — the one-time enable in phone
            // settings (documented in the troubleshooting guide).
            Log.e(TAG, "addNewIncomingCall refused — calling account disabled?", e);
        }
    }

    static synchronized void setCallActive(String uuid) {
        PiopiyConnection c = connections.get(uuid.toLowerCase());
        if (c != null) c.setActive();
    }

    static synchronized void answerCall(String uuid) {
        PiopiyConnection c = connections.get(uuid.toLowerCase());
        if (c != null) c.onAnswer();
    }

    static synchronized void endCall(String uuid, int reason) {
        PiopiyConnection c = connections.remove(uuid.toLowerCase());
        CallBridge.dropPayload(uuid);
        if (c == null) return;
        int cause = reason == 3 ? DisconnectCause.MISSED
                : reason == 6 ? DisconnectCause.REJECTED
                : DisconnectCause.REMOTE;
        c.setDisconnected(new DisconnectCause(cause));
        c.destroy();
    }

    static synchronized void setMuted(String uuid, boolean muted) {
        PiopiyConnection c = connections.get(uuid.toLowerCase());
        if (c != null) c.setMutedState(muted);
    }

    @Override
    public Connection onCreateIncomingConnection(PhoneAccountHandle account, ConnectionRequest request) {
        Bundle extras = request.getExtras();
        String uuid = extras.getString(EXTRA_UUID, "");
        String name = extras.getString(EXTRA_NAME, "");
        Uri address = extras.getParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS);

        PiopiyConnection connection = new PiopiyConnection(uuid);
        connection.setConnectionCapabilities(Connection.CAPABILITY_MUTE | Connection.CAPABILITY_HOLD);
        if (address != null) {
            connection.setAddress(address, TelecomManager.PRESENTATION_ALLOWED);
        }
        if (!name.isEmpty()) {
            connection.setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED);
        }
        connection.setAudioModeIsVoip(true);
        connection.setRinging();
        synchronized (PiopiyConnectionService.class) {
            connections.put(uuid.toLowerCase(), connection);
        }
        return connection;
    }

    @Override
    public void onCreateIncomingConnectionFailed(PhoneAccountHandle account, ConnectionRequest request) {
        Bundle extras = request.getExtras();
        String uuid = extras != null ? extras.getString(EXTRA_UUID, "") : "";
        Log.w(TAG, "onCreateIncomingConnectionFailed for " + uuid);
        CallBridge.emit("end", uuid);
        super.onCreateIncomingConnectionFailed(account, request);
    }

    /** One Telecom connection = one call. Events flow to Dart via CallBridge. */
    static class PiopiyConnection extends Connection {
        private final String uuid;
        boolean answered = false;

        PiopiyConnection(String uuid) {
            this.uuid = uuid;
        }

        @Override
        public void onAnswer() {
            if (answered) return; // some OEMs call onAnswer twice
            answered = true;
            setConnectionCapabilities(getConnectionCapabilities() | Connection.CAPABILITY_HOLD);
            setAudioModeIsVoip(true);
            // ACTIVE here, synchronously — audio routing must not wait for Dart.
            setActive();
            CallBridge.emit("answer", uuid);
        }

        @Override
        public void onAnswer(int videoState) {
            onAnswer();
        }

        @Override
        public void onDisconnect() {
            setDisconnected(new DisconnectCause(DisconnectCause.LOCAL));
            cleanup();
            CallBridge.emit("end", uuid);
        }

        @Override
        public void onReject() {
            setDisconnected(new DisconnectCause(DisconnectCause.REJECTED));
            cleanup();
            CallBridge.emit("end", uuid);
        }

        @Override
        public void onAbort() {
            setDisconnected(new DisconnectCause(DisconnectCause.REJECTED));
            cleanup();
            CallBridge.emit("end", uuid);
        }

        @Override
        public void onCallAudioStateChanged(CallAudioState state) {
            // The OS in-call UI owns routing (speaker/bluetooth) — nothing to do.
        }

        void setMutedState(boolean muted) {
            // Mute is enacted in the media engine (Dart); Telecom just reflects it.
        }

        private void cleanup() {
            synchronized (PiopiyConnectionService.class) {
                connections.remove(uuid.toLowerCase());
            }
            CallBridge.dropPayload(uuid);
            destroy();
        }
    }
}
