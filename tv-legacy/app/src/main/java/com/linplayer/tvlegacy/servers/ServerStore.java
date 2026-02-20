package com.linplayer.tvlegacy.servers;

import android.content.Context;
import com.linplayer.tvlegacy.AppPrefs;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public final class ServerStore {
    private ServerStore() {}

    public static List<ServerConfig> list(Context context) {
        if (context == null) return Collections.emptyList();
        String raw = AppPrefs.getServersJson(context);
        if (raw == null || raw.trim().isEmpty()) return Collections.emptyList();
        try {
            JSONArray arr = new JSONArray(raw);
            List<ServerConfig> out = new ArrayList<>(arr.length());
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.optJSONObject(i);
                if (o == null) continue;
                ServerConfig c = ServerConfig.fromJson(o);
                if (c == null) continue;
                if (c.id == null || c.id.trim().isEmpty()) continue;
                out.add(c);
            }
            return Collections.unmodifiableList(out);
        } catch (JSONException e) {
            return Collections.emptyList();
        }
    }

    public static boolean hasAny(Context context) {
        List<ServerConfig> list = list(context);
        return list != null && !list.isEmpty();
    }

    public static ServerConfig getActive(Context context) {
        if (context == null) return null;
        String activeId = AppPrefs.getActiveServerId(context);
        List<ServerConfig> list = list(context);
        if (list == null || list.isEmpty()) return null;
        if (activeId != null && !activeId.trim().isEmpty()) {
            for (ServerConfig c : list) {
                if (c != null && activeId.equals(c.id)) return c;
            }
        }
        return list.get(0);
    }

    public static String getActiveId(Context context) {
        if (context == null) return "";
        String v = AppPrefs.getActiveServerId(context);
        if (v != null && !v.trim().isEmpty()) return v.trim();
        ServerConfig first = getActive(context);
        return first != null ? first.id : "";
    }

    public static void setActive(Context context, String serverId) {
        if (context == null) return;
        String id = serverId != null ? serverId.trim() : "";
        AppPrefs.setActiveServerId(context, id);
    }

    public static ServerConfig find(Context context, String serverId) {
        if (context == null) return null;
        String id = serverId != null ? serverId.trim() : "";
        if (id.isEmpty()) return null;
        List<ServerConfig> list = list(context);
        for (ServerConfig c : list) {
            if (c != null && id.equals(c.id)) return c;
        }
        return null;
    }

    public static ServerConfig upsert(Context context, ServerConfig config, boolean activate)
            throws JSONException {
        if (context == null) return null;
        if (config == null) return null;
        String id = config.id != null ? config.id.trim() : "";
        if (id.isEmpty()) {
            id = UUID.randomUUID().toString();
        }

        List<ServerConfig> current = new ArrayList<>(list(context));
        boolean replaced = false;
        for (int i = 0; i < current.size(); i++) {
            ServerConfig c = current.get(i);
            if (c != null && id.equals(c.id)) {
                current.set(
                        i,
                        new ServerConfig(
                                id,
                                config.type,
                                config.baseUrl,
                                config.apiKey,
                                config.username,
                                config.password,
                                config.displayName,
                                config.remark));
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            current.add(
                    new ServerConfig(
                            id,
                            config.type,
                            config.baseUrl,
                            config.apiKey,
                            config.username,
                            config.password,
                            config.displayName,
                            config.remark));
        }

        save(context, current);
        if (activate) {
            setActive(context, id);
        } else {
            String activeId = AppPrefs.getActiveServerId(context);
            if (activeId == null || activeId.trim().isEmpty()) {
                setActive(context, id);
            }
        }
        return find(context, id);
    }

    public static void delete(Context context, String serverId) throws JSONException {
        if (context == null) return;
        String id = serverId != null ? serverId.trim() : "";
        if (id.isEmpty()) return;

        List<ServerConfig> current = new ArrayList<>(list(context));
        boolean removed = false;
        for (int i = current.size() - 1; i >= 0; i--) {
            ServerConfig c = current.get(i);
            if (c != null && id.equals(c.id)) {
                current.remove(i);
                removed = true;
                break;
            }
        }
        if (!removed) return;
        save(context, current);

        String activeId = AppPrefs.getActiveServerId(context);
        if (activeId != null && activeId.equals(id)) {
            AppPrefs.setActiveServerId(context, current.isEmpty() ? "" : safeId(current.get(0)));
        }
    }

    private static void save(Context context, List<ServerConfig> list) throws JSONException {
        JSONArray arr = new JSONArray();
        if (list != null) {
            for (ServerConfig c : list) {
                if (c == null) continue;
                if (c.id == null || c.id.trim().isEmpty()) continue;
                arr.put(c.toJson());
            }
        }
        AppPrefs.setServersJson(context, arr.toString());
    }

    private static String safeId(ServerConfig c) {
        if (c == null) return "";
        String v = c.id != null ? c.id.trim() : "";
        return v;
    }
}
