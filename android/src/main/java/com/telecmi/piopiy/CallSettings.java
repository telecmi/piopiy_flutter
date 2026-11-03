package com.telecmi.piopiy;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;

import java.util.Map;

/**
 * Settings from Dart's setup(), persisted so the FCM background isolate and
 * a killed-state launch (no setup call yet) use the same configuration.
 */
final class CallSettings {

    private static final String PREFS = "com.telecmi.piopiy";

    private CallSettings() { }

    private static SharedPreferences prefs(Context context) {
        return context.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    @SuppressWarnings("unchecked")
    static void save(Context context, Map<String, Object> args) {
        SharedPreferences.Editor e = prefs(context).edit();
        Object label = args.get("accountLabel");
        if (label instanceof String && !((String) label).isEmpty()) {
            e.putString("accountLabel", (String) label);
        } else {
            e.remove("accountLabel");
        }
        Object ringTime = args.get("ringTime");
        if (ringTime instanceof Number) e.putInt("ringTime", ((Number) ringTime).intValue());
        Object android = args.get("android");
        if (android instanceof Map) {
            Map<String, Object> a = (Map<String, Object>) android;
            putString(e, "channelId", a.get("channelId"));
            putString(e, "channelName", a.get("channelName"));
            putString(e, "notificationTitle", a.get("notificationTitle"));
            putString(e, "notificationIcon", a.get("notificationIcon"));
        }
        e.apply();
    }

    private static void putString(SharedPreferences.Editor e, String key, Object value) {
        if (value instanceof String && !((String) value).isEmpty()) {
            e.putString(key, (String) value);
        } else {
            e.remove(key);
        }
    }

    /** Label of the calling account: the configured name, else the app's own. */
    static String accountLabel(Context context) {
        String label = prefs(context).getString("accountLabel", null);
        if (label != null) return label;
        try {
            ApplicationInfo info = context.getApplicationInfo();
            CharSequence l = info.loadLabel(context.getPackageManager());
            if (l != null && l.length() > 0) return l.toString();
        } catch (Exception ignored) { }
        return "PIOPIY";
    }

    /** Seconds an incoming call may ring before the native backstop ends it. */
    static int ringTimeoutSeconds(Context context) {
        // ringTime (the Dart timer) + 5 s: the Dart timer handles the normal
        // case; this one fires only when Dart isn't running.
        return prefs(context).getInt("ringTime", 40) + 5;
    }

    static String channelId(Context c) { return prefs(c).getString("channelId", "com.piopiy.callkeep"); }

    static String channelName(Context c) { return prefs(c).getString("channelName", "PIOPIY incoming calls"); }

    static String notificationTitle(Context c) { return prefs(c).getString("notificationTitle", "Call in progress"); }

    static int notificationIcon(Context context) {
        String name = prefs(context).getString("notificationIcon", null);
        if (name != null) {
            int id = context.getResources().getIdentifier(name, "drawable", context.getPackageName());
            if (id == 0) id = context.getResources().getIdentifier(name, "mipmap", context.getPackageName());
            if (id != 0) return id;
        }
        return context.getApplicationInfo().icon;
    }

    static void setSignedOut(Context context, boolean signedOut) {
        prefs(context).edit().putBoolean("signedOut", signedOut).apply();
    }

    /** After logout() the background push path refuses invites. */
    static boolean isSignedOut(Context context) {
        return prefs(context).getBoolean("signedOut", false);
    }

    static boolean hasLaunchActivity(Context context) {
        PackageManager pm = context.getPackageManager();
        return pm.getLaunchIntentForPackage(context.getPackageName()) != null;
    }
}
