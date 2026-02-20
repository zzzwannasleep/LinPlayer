package com.linplayer.tvlegacy.servers;

import org.json.JSONException;
import org.json.JSONObject;

public final class ServerConfig {
    public final String id;
    public final String type;
    public final String baseUrl;
    public final String apiKey;
    public final String username;
    public final String password;
    public final String displayName;
    public final String remark;

    public ServerConfig(
            String id,
            String type,
            String baseUrl,
            String apiKey,
            String username,
            String password,
            String displayName,
            String remark) {
        this.id = safeTrim(id);
        this.type = safeTrim(type);
        this.baseUrl = safeTrim(baseUrl);
        this.apiKey = safeTrim(apiKey);
        this.username = safeTrim(username);
        this.password = safe(password);
        this.displayName = safeTrim(displayName);
        this.remark = safeTrim(remark);
    }

    public static ServerConfig fromJson(JSONObject o) throws JSONException {
        if (o == null) return null;
        return new ServerConfig(
                o.optString("id", ""),
                o.optString("type", ""),
                o.optString("baseUrl", ""),
                o.optString("apiKey", ""),
                o.optString("username", ""),
                o.optString("password", ""),
                o.optString("displayName", ""),
                o.optString("remark", ""));
    }

    public JSONObject toJson() throws JSONException {
        JSONObject o = new JSONObject();
        o.put("id", safeTrim(id));
        o.put("type", safeTrim(type));
        o.put("baseUrl", safeTrim(baseUrl));
        o.put("apiKey", safeTrim(apiKey));
        o.put("username", safeTrim(username));
        o.put("password", safe(password));
        o.put("displayName", safeTrim(displayName));
        o.put("remark", safeTrim(remark));
        return o;
    }

    public String effectiveName() {
        String n = safeTrim(displayName);
        if (!n.isEmpty()) return n;
        n = safeTrim(baseUrl);
        return !n.isEmpty() ? n : "Server";
    }

    public boolean isType(String t) {
        String a = safeTrim(type).toLowerCase();
        String b = safeTrim(t).toLowerCase();
        return !a.isEmpty() && a.equals(b);
    }

    private static String safeTrim(String s) {
        return s != null ? s.trim() : "";
    }

    private static String safe(String s) {
        return s != null ? s : "";
    }
}

