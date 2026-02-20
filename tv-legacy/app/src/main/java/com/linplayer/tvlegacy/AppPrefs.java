package com.linplayer.tvlegacy;

import android.content.Context;
import android.content.SharedPreferences;

public final class AppPrefs {
    private static final String PREFS = "linplayer_tv_legacy";

    private static final String KEY_SUBSCRIPTION_URL = "subscription_url";
    private static final String KEY_PROXY_ENABLED = "proxy_enabled";
    private static final String KEY_LAST_STATUS = "last_status";

    private static final String KEY_MEDIA_BACKEND = "media_backend";
    private static final String KEY_MEDIA_BASE_URL = "media_base_url";
    private static final String KEY_MEDIA_API_KEY = "media_api_key";

    private static final String KEY_SERVERS_JSON = "servers_json";
    private static final String KEY_ACTIVE_SERVER_ID = "active_server_id";
    private static final String KEY_SERVER_VIEW_MODE = "server_view_mode";

    private static final String KEY_REMOTE_TOKEN = "remote_token";
    private static final String KEY_REMOTE_PORT = "remote_port";

    private AppPrefs() {}

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    public static String getSubscriptionUrl(Context context) {
        String v = prefs(context).getString(KEY_SUBSCRIPTION_URL, "");
        return v != null ? v : "";
    }

    public static void setSubscriptionUrl(Context context, String url) {
        String v = url != null ? url.trim() : "";
        prefs(context).edit().putString(KEY_SUBSCRIPTION_URL, v).apply();
    }

    public static boolean isProxyEnabled(Context context) {
        return prefs(context).getBoolean(KEY_PROXY_ENABLED, false);
    }

    public static void setProxyEnabled(Context context, boolean enabled) {
        prefs(context).edit().putBoolean(KEY_PROXY_ENABLED, enabled).apply();
    }

    public static String getLastStatus(Context context) {
        String v = prefs(context).getString(KEY_LAST_STATUS, "stopped");
        return v != null ? v : "stopped";
    }

    public static void setLastStatus(Context context, String status) {
        String v = status != null ? status : "unknown";
        prefs(context).edit().putString(KEY_LAST_STATUS, v).apply();
    }

    public static String getMediaBackend(Context context) {
        String v = prefs(context).getString(KEY_MEDIA_BACKEND, "demo");
        return v != null && !v.trim().isEmpty() ? v.trim().toLowerCase() : "demo";
    }

    public static void setMediaBackend(Context context, String backend) {
        String v = backend != null ? backend.trim().toLowerCase() : "demo";
        if (v.isEmpty()) v = "demo";
        prefs(context).edit().putString(KEY_MEDIA_BACKEND, v).apply();
    }

    public static String getMediaBaseUrl(Context context) {
        String v = prefs(context).getString(KEY_MEDIA_BASE_URL, "");
        return v != null ? v.trim() : "";
    }

    public static void setMediaBaseUrl(Context context, String baseUrl) {
        String v = baseUrl != null ? baseUrl.trim() : "";
        prefs(context).edit().putString(KEY_MEDIA_BASE_URL, v).apply();
    }

    public static String getMediaApiKey(Context context) {
        String v = prefs(context).getString(KEY_MEDIA_API_KEY, "");
        return v != null ? v.trim() : "";
    }

    public static void setMediaApiKey(Context context, String apiKey) {
        String v = apiKey != null ? apiKey.trim() : "";
        prefs(context).edit().putString(KEY_MEDIA_API_KEY, v).apply();
    }

    public static String getServersJson(Context context) {
        String v = prefs(context).getString(KEY_SERVERS_JSON, "");
        return v != null ? v : "";
    }

    public static void setServersJson(Context context, String json) {
        String v = json != null ? json : "";
        prefs(context).edit().putString(KEY_SERVERS_JSON, v).apply();
    }

    public static String getActiveServerId(Context context) {
        String v = prefs(context).getString(KEY_ACTIVE_SERVER_ID, "");
        return v != null ? v : "";
    }

    public static void setActiveServerId(Context context, String serverId) {
        String v = serverId != null ? serverId.trim() : "";
        prefs(context).edit().putString(KEY_ACTIVE_SERVER_ID, v).apply();
    }

    public static String getServerViewMode(Context context) {
        String v = prefs(context).getString(KEY_SERVER_VIEW_MODE, "list");
        String s = v != null ? v.trim().toLowerCase() : "list";
        return ("grid".equals(s) || "list".equals(s)) ? s : "list";
    }

    public static void setServerViewMode(Context context, String mode) {
        String v = mode != null ? mode.trim().toLowerCase() : "list";
        if (!"grid".equals(v) && !"list".equals(v)) v = "list";
        prefs(context).edit().putString(KEY_SERVER_VIEW_MODE, v).apply();
    }

    public static String getRemoteToken(Context context) {
        String v = prefs(context).getString(KEY_REMOTE_TOKEN, "");
        return v != null ? v : "";
    }

    public static void setRemoteToken(Context context, String token) {
        String v = token != null ? token.trim() : "";
        prefs(context).edit().putString(KEY_REMOTE_TOKEN, v).apply();
    }

    public static int getRemotePort(Context context) {
        return prefs(context).getInt(KEY_REMOTE_PORT, 0);
    }

    public static void setRemotePort(Context context, int port) {
        int p = port > 0 ? port : 0;
        prefs(context).edit().putInt(KEY_REMOTE_PORT, p).apply();
    }
}
