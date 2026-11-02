package com.telecmi.piopiy;

import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.Map;

/**
 * Native-to-Dart event funnel. Telecom callbacks fire in contexts where Dart
 * may not be attached yet (cold answer on the OS call UI before Flutter
 * boots) — events are queued and REPLAYED when Dart attaches, the same
 * pattern as react-native-voip-push-notification's didLoadWithEvents, whose
 * absence cost the RN SDK its lost-answer bug.
 */
final class CallBridge {

    interface Sink { void send(Map<String, Object> event); }

    private static final ArrayDeque<Map<String, Object>> queue = new ArrayDeque<>();
    private static final Map<String, Map<String, Object>> payloads = new HashMap<>();
    private static Sink sink = null;

    private CallBridge() { }

    static synchronized void attach(Sink s) {
        sink = s;
        while (!queue.isEmpty() && sink != null) {
            sink.send(queue.poll());
        }
        // Replay stored call payloads too — a cold-launched app needs the
        // {room, token, url} of the call it is being answered into.
        for (Map<String, Object> p : payloads.values()) {
            Map<String, Object> ev = new HashMap<>();
            ev.put("event", "push");
            ev.put("payload", p);
            sink.send(ev);
        }
    }

    static synchronized void detach() {
        sink = null;
    }

    static synchronized void emit(String event, String uuid) {
        Map<String, Object> ev = new HashMap<>();
        ev.put("event", event);
        if (uuid != null) ev.put("uuid", uuid.toLowerCase());
        if (sink != null) {
            sink.send(ev);
        } else {
            queue.add(ev);
            if (queue.size() > 20) queue.poll();
        }
    }

    /** Stash the push payload with its call so a cold-launched app can read it back. */
    static synchronized void storePayload(String uuid, Map<String, Object> payload) {
        if (uuid == null || payload == null) return;
        payloads.put(uuid.toLowerCase(), payload);
        if (payloads.size() > 10) {
            payloads.remove(payloads.keySet().iterator().next());
        }
    }

    static synchronized void dropPayload(String uuid) {
        if (uuid != null) payloads.remove(uuid.toLowerCase());
    }
}
