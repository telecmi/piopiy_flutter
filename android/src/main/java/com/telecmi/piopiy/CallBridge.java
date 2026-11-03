package com.telecmi.piopiy;

import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Native-to-Dart event funnel, shared by every Flutter engine in the process.
 * Only the app's MAIN isolate subscribes (the FCM background isolate calls in
 * but never listens), so call events can't be swallowed by the background
 * engine. Telecom callbacks fire in contexts where Dart may not be attached
 * yet (cold answer on the OS call UI before Flutter boots) — events are
 * queued and REPLAYED when Dart attaches, together with the stored call
 * payloads (the {room, token, url} a cold-launched app joins on answer).
 */
final class CallBridge {

    interface Sink { void send(Map<String, Object> event); }

    private static final ArrayDeque<Map<String, Object>> queue = new ArrayDeque<>();
    private static final Map<String, Map<String, Object>> payloads = new LinkedHashMap<>();
    private static Sink sink = null;
    private static Object owner = null;

    private CallBridge() { }

    static synchronized void attach(Object who, Sink s) {
        owner = who;
        sink = s;
        while (!queue.isEmpty()) {
            sink.send(queue.poll());
        }
        for (Map<String, Object> p : payloads.values()) {
            sink.send(pushEvent(p));
        }
    }

    /** Detach only if [who] still owns the sink (another engine may have taken over). */
    static synchronized void detach(Object who) {
        if (owner == who) {
            sink = null;
            owner = null;
        }
    }

    static synchronized void emit(Map<String, Object> ev) {
        if (sink != null) {
            sink.send(ev);
        } else {
            queue.add(ev);
            if (queue.size() > 30) queue.poll();
        }
    }

    static void emit(String event, String uuid) {
        Map<String, Object> ev = new HashMap<>();
        ev.put("event", event);
        if (uuid != null) ev.put("uuid", uuid.toLowerCase());
        emit(ev);
    }

    private static Map<String, Object> pushEvent(Map<String, Object> payload) {
        Map<String, Object> ev = new HashMap<>();
        ev.put("event", "push");
        ev.put("payload", payload);
        return ev;
    }

    /**
     * A push the background isolate handled: deliver it to the app now if it
     * is running. Invites that can't be delivered are replayed from the
     * stored payload on attach; cancels are queued (a later replay surfaces
     * the missed call).
     */
    static synchronized void forwardPush(Map<String, Object> payload, boolean queueIfDetached) {
        if (sink != null) {
            sink.send(pushEvent(payload));
        } else if (queueIfDetached) {
            queue.add(pushEvent(payload));
            if (queue.size() > 30) queue.poll();
        }
    }

    /** Stash the push payload with its call so a cold-launched app can read it back. */
    static synchronized void storePayload(String uuid, Map<String, Object> payload) {
        if (uuid == null || payload == null) return;
        Map<String, Object> copy = new HashMap<>(payload);
        copy.put("_alreadyRang", Boolean.TRUE); // the native layer rang it
        payloads.put(uuid.toLowerCase(), copy);
        if (payloads.size() > 10) {
            payloads.remove(payloads.keySet().iterator().next());
        }
    }

    static synchronized Map<String, Object> getPayload(String uuid) {
        return uuid == null ? null : payloads.get(uuid.toLowerCase());
    }

    static synchronized void dropPayload(String uuid) {
        if (uuid != null) payloads.remove(uuid.toLowerCase());
    }
}
