package com.linplayer.tvlegacy.remote;

import android.content.Context;
import com.linplayer.tvlegacy.AppPrefs;
import com.linplayer.tvlegacy.BuildConfig;
import com.linplayer.tvlegacy.ProxyService;
import com.linplayer.tvlegacy.R;
import com.linplayer.tvlegacy.servers.ServerConfig;
import com.linplayer.tvlegacy.servers.ServerStore;
import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

final class RemoteHttpServer {
    private static final Charset UTF8 = Charset.forName("UTF-8");

    private final Context appContext;
    private volatile boolean running;
    private ServerSocket serverSocket;
    private Thread acceptThread;
    private int port;
    private String token = "";
    private volatile String cachedIndexHtml;

    RemoteHttpServer(Context context) {
        this.appContext = context.getApplicationContext();
    }

    boolean isRunning() {
        return running;
    }

    int getPort() {
        return port;
    }

    String getToken() {
        return token != null ? token : "";
    }

    void start(String token, int preferredPort) {
        if (running) return;
        this.token = token != null ? token.trim() : "";

        ServerSocket ss = null;
        int chosenPort = 0;
        try {
            ss = new ServerSocket();
            ss.setReuseAddress(true);
            int p = preferredPort > 0 ? preferredPort : 0;
            ss.bind(new InetSocketAddress(InetAddress.getByName("0.0.0.0"), p));
            chosenPort = ss.getLocalPort();
        } catch (IOException e) {
            closeQuietly(ss);
            try {
                ss = new ServerSocket(0);
                ss.setReuseAddress(true);
                chosenPort = ss.getLocalPort();
            } catch (IOException ex) {
                closeQuietly(ss);
                return;
            }
        }

        serverSocket = ss;
        port = chosenPort;
        running = true;
        acceptThread =
                new Thread(
                        () -> {
                            acceptLoop();
                        },
                        "tv-legacy-remote-http");
        acceptThread.setDaemon(true);
        acceptThread.start();
    }

    void stop() {
        running = false;
        closeQuietly(serverSocket);
        serverSocket = null;
        port = 0;
        token = "";

        Thread t = acceptThread;
        acceptThread = null;
        if (t != null) {
            try {
                t.join(800);
            } catch (InterruptedException ignored) {
            }
        }
    }

    private void acceptLoop() {
        ServerSocket ss = serverSocket;
        if (ss == null) return;
        while (running) {
            Socket socket = null;
            try {
                socket = ss.accept();
                Socket s = socket;
                Thread t =
                        new Thread(
                                () -> {
                                    handleConnection(s);
                                },
                                "tv-legacy-remote-http-conn");
                t.setDaemon(true);
                t.start();
            } catch (IOException e) {
                closeQuietly(socket);
                if (!running) break;
            }
        }
    }

    private void handleConnection(Socket socket) {
        if (socket == null) return;
        try (Socket s = socket) {
            s.setSoTimeout(7000);
            InputStream rawIn = s.getInputStream();
            OutputStream out = s.getOutputStream();

            BufferedInputStream in = new BufferedInputStream(rawIn);
            String requestLine = readLine(in);
            if (requestLine == null || requestLine.trim().isEmpty()) return;

            String[] parts = requestLine.split(" ");
            if (parts.length < 2) {
                writePlain(out, 400, "bad request");
                return;
            }
            String method = parts[0].trim().toUpperCase();
            String fullPath = parts[1].trim();

            Map<String, String> headers = new HashMap<>();
            String line;
            while ((line = readLine(in)) != null) {
                if (line.isEmpty()) break;
                int idx = line.indexOf(':');
                if (idx <= 0) continue;
                String k = line.substring(0, idx).trim().toLowerCase();
                String v = line.substring(idx + 1).trim();
                headers.put(k, v);
            }

            int contentLength = parseInt(headers.get("content-length"), 0);
            byte[] bodyBytes = contentLength > 0 ? readBytes(in, contentLength) : new byte[0];
            String body = bodyBytes.length > 0 ? new String(bodyBytes, UTF8) : "";

            int q = fullPath.indexOf('?');
            String path = q >= 0 ? fullPath.substring(0, q) : fullPath;
            String query = q >= 0 ? fullPath.substring(q + 1) : "";
            Map<String, String> queryParams = parseQuery(query);

            route(out, method, path, queryParams, body);
        } catch (Exception ignored) {
            // ignore
        }
    }

    private void route(
            OutputStream out,
            String method,
            String path,
            Map<String, String> query,
            String body) {
        if (path == null || path.isEmpty()) path = "/";

        if ("GET".equals(method) && ("/".equals(path) || "/index.html".equals(path))) {
            String html = indexHtml();
            writeBytes(out, 200, "text/html; charset=utf-8", html.getBytes(UTF8));
            return;
        }

        if ("/api/info".equals(path)) {
            String tokenParam = query.get("token");
            if (!checkToken(tokenParam)) {
                writePlain(out, 401, "unauthorized");
                return;
            }
            try {
                JSONObject resp = new JSONObject();
                resp.put("ok", true);
                JSONObject app = new JSONObject();
                app.put("name", "LinPlayer TV Legacy");
                app.put("version", BuildConfig.VERSION_NAME);
                resp.put("app", app);

                ServerConfig active = ServerStore.getActive(appContext);
                JSONObject server = new JSONObject();
                server.put("activeServerId", active != null ? active.id : "");
                server.put("activeServerName", active != null ? active.effectiveName() : "");
                server.put("activeServerBaseUrl", active != null ? active.baseUrl : "");
                server.put("activeServerType", active != null ? active.type : "");
                resp.put("server", server);

                JSONObject proxy = new JSONObject();
                proxy.put("enabled", AppPrefs.isProxyEnabled(appContext));
                proxy.put("subscriptionUrl", AppPrefs.getSubscriptionUrl(appContext));
                proxy.put("status", AppPrefs.getLastStatus(appContext));
                resp.put("proxy", proxy);

                writeBytes(out, 200, "application/json; charset=utf-8", resp.toString().getBytes(UTF8));
            } catch (JSONException e) {
                writePlain(out, 500, "json error");
            }
            return;
        }

        if ("/api/addServer".equals(path)) {
            if (!"POST".equals(method)) {
                writePlain(out, 405, "method not allowed");
                return;
            }
            try {
                JSONObject req = new JSONObject(body != null ? body : "");
                String token = req.optString("token", "");
                if (!checkToken(token)) {
                    writeJson(out, jsonError("unauthorized"));
                    return;
                }

                String type = req.optString("type", "emby").trim().toLowerCase();
                String baseUrl = normalizeBaseUrl(req.optString("baseUrl", ""));
                String apiKey = req.optString("apiKey", req.optString("token", ""));
                String username = req.optString("username", "");
                String password = req.optString("password", "");
                String displayName = req.optString("displayName", "");
                String remark = req.optString("remark", "");
                boolean activate = readBool(req.opt("activate"), true);

                if (baseUrl.isEmpty()) {
                    writeJson(out, jsonError("missing baseUrl"));
                    return;
                }
                if ("webdav".equals(type)) {
                    if (username == null || username.trim().isEmpty()) {
                        writeJson(out, jsonError("missing username"));
                        return;
                    }
                } else if ("plex".equals(type)) {
                    if (apiKey == null || apiKey.trim().isEmpty()) {
                        writeJson(out, jsonError("missing token"));
                        return;
                    }
                } else {
                    if (apiKey == null || apiKey.trim().isEmpty()) {
                        writeJson(out, jsonError("missing apiKey/token"));
                        return;
                    }
                    if (!"emby".equals(type) && !"jellyfin".equals(type)) type = "emby";
                }

                ServerConfig cfg =
                        new ServerConfig(
                                "",
                                type,
                                baseUrl,
                                apiKey,
                                username,
                                password,
                                displayName,
                                remark);
                ServerConfig saved = ServerStore.upsert(appContext, cfg, activate);

                JSONObject resp = new JSONObject();
                resp.put("ok", true);
                resp.put("serverId", saved != null ? saved.id : "");
                resp.put("activeServerId", ServerStore.getActiveId(appContext));
                writeJson(out, resp);
            } catch (JSONException e) {
                writeJson(out, jsonError("invalid json"));
            }
            return;
        }

        if ("/api/bulkAddServers".equals(path)) {
            if (!"POST".equals(method)) {
                writePlain(out, 405, "method not allowed");
                return;
            }
            try {
                JSONObject req = new JSONObject(body != null ? body : "");
                String token = req.optString("token", "");
                if (!checkToken(token)) {
                    writeJson(out, jsonError("unauthorized"));
                    return;
                }

                String text = req.optString("text", "");
                String defaultType = req.optString("defaultType", "emby");
                boolean activateFirst = readBool(req.opt("activateFirst"), true);
                JSONObject resp = handleBulkAdd(text, defaultType, activateFirst);
                writeJson(out, resp);
            } catch (JSONException e) {
                writeJson(out, jsonError("invalid json"));
            }
            return;
        }

        if ("/api/setProxySettings".equals(path)) {
            if (!"POST".equals(method)) {
                writePlain(out, 405, "method not allowed");
                return;
            }
            try {
                JSONObject req = new JSONObject(body != null ? body : "");
                String token = req.optString("token", "");
                if (!checkToken(token)) {
                    writeJson(out, jsonError("unauthorized"));
                    return;
                }

                boolean enabled = readBool(req.opt("enabled"), false);
                String subscriptionUrl = req.optString("subscriptionUrl", "");
                AppPrefs.setSubscriptionUrl(appContext, subscriptionUrl);
                AppPrefs.setProxyEnabled(appContext, enabled);
                if (enabled) {
                    ProxyService.applyConfig(appContext);
                    ProxyService.start(appContext);
                } else {
                    ProxyService.stop(appContext);
                }

                JSONObject resp = new JSONObject();
                resp.put("ok", true);
                resp.put("enabled", AppPrefs.isProxyEnabled(appContext));
                resp.put("subscriptionUrl", AppPrefs.getSubscriptionUrl(appContext));
                resp.put("status", AppPrefs.getLastStatus(appContext));
                writeJson(out, resp);
            } catch (JSONException e) {
                writeJson(out, jsonError("invalid json"));
            }
            return;
        }

        if ("/api/player/status".equals(path)) {
            String tokenParam = query.get("token");
            if (!checkToken(tokenParam)) {
                writePlain(out, 401, "unauthorized");
                return;
            }
            writeJson(out, PlaybackSession.status());
            return;
        }

        if ("/api/player/control".equals(path)) {
            if (!"POST".equals(method)) {
                writePlain(out, 405, "method not allowed");
                return;
            }
            try {
                JSONObject req = new JSONObject(body != null ? body : "");
                String token = req.optString("token", "");
                if (!checkToken(token)) {
                    writeJson(out, jsonError("unauthorized"));
                    return;
                }
                String action = req.optString("action", "");
                long value = 0;
                try {
                    value = req.has("value") ? req.getLong("value") : 0;
                } catch (Exception ignored) {
                    value = 0;
                }
                writeJson(out, PlaybackSession.control(action, value));
            } catch (JSONException e) {
                writeJson(out, jsonError("invalid json"));
            }
            return;
        }

        writePlain(out, 404, "not found");
    }

    private boolean checkToken(String token) {
        String t = token != null ? token.trim() : "";
        String cur = getToken();
        return !cur.isEmpty() && cur.equals(t);
    }

    private JSONObject handleBulkAdd(String text, String defaultType, boolean activateFirst) {
        List<String> errors = new ArrayList<>();
        List<ParsedServer> items = parseBulk(text, defaultType, errors);
        int added = 0;
        boolean activatedAny = false;
        for (int i = 0; i < items.size(); i++) {
            ParsedServer ps = items.get(i);
            if (ps == null || ps.config == null) continue;
            boolean activate = ps.activate;
            if (!activatedAny && activateFirst && added == 0) {
                activate = true;
            }
            try {
                ServerStore.upsert(appContext, ps.config, activate);
                added++;
                if (activate) activatedAny = true;
            } catch (Exception e) {
                errors.add("save failed: " + String.valueOf(e.getMessage()));
            }
        }
        try {
            JSONObject resp = new JSONObject();
            resp.put("ok", true);
            resp.put("added", added);
            resp.put("activeServerId", ServerStore.getActiveId(appContext));
            resp.put("errors", new JSONArray(errors));
            return resp;
        } catch (JSONException e) {
            return jsonError("json error");
        }
    }

    private static List<ParsedServer> parseBulk(
            String text, String defaultType, List<String> errors) {
        String t = text != null ? text.trim() : "";
        String def = defaultType != null ? defaultType.trim().toLowerCase() : "emby";
        if (!isKnownType(def)) def = "emby";

        if (t.isEmpty()) return Collections.emptyList();

        // JSON mode (array or object).
        if (t.startsWith("[") || t.startsWith("{")) {
            try {
                List<ParsedServer> out = new ArrayList<>();
                if (t.startsWith("[")) {
                    JSONArray arr = new JSONArray(t);
                    for (int i = 0; i < arr.length(); i++) {
                        JSONObject o = arr.optJSONObject(i);
                        if (o == null) continue;
                        ParsedServer ps = parseServerObject(o, def, errors, "json[" + i + "]");
                        if (ps != null) out.add(ps);
                    }
                } else {
                    JSONObject o = new JSONObject(t);
                    ParsedServer ps = parseServerObject(o, def, errors, "json");
                    if (ps != null) out.add(ps);
                }
                return Collections.unmodifiableList(out);
            } catch (Exception ignored) {
                // Fall back to line mode.
            }
        }

        String[] lines = t.split("\\r?\\n");
        List<ParsedServer> out = new ArrayList<>();
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i] != null ? lines[i].trim() : "";
            if (line.isEmpty()) continue;
            if (line.startsWith("#")) continue;
            ParsedServer ps = parseServerLine(line, def, errors, "line " + (i + 1));
            if (ps != null) out.add(ps);
        }
        return Collections.unmodifiableList(out);
    }

    private static ParsedServer parseServerObject(
            JSONObject o, String defaultType, List<String> errors, String label) {
        if (o == null) return null;
        String type =
                safe(o.optString("type", defaultType))
                        .toLowerCase()
                        .trim();
        if (!isKnownType(type)) type = defaultType;

        String baseUrl = normalizeBaseUrl(o.optString("baseUrl", ""));
        String apiKey = o.optString("apiKey", o.optString("token", ""));
        String username = o.optString("username", "");
        String password = o.optString("password", "");
        String displayName = o.optString("displayName", "");
        String remark = o.optString("remark", "");
        boolean activate = readBool(o.opt("activate"), false);

        ParsedServer ps =
                validateAndBuild(type, baseUrl, apiKey, username, password, displayName, remark, activate);
        if (ps == null) {
            errors.add(label + ": invalid server");
        }
        return ps;
    }

    private static ParsedServer parseServerLine(
            String line, String defaultType, List<String> errors, String label) {
        if (line == null) return null;
        String raw = line.trim();
        if (raw.isEmpty()) return null;

        String[] parts;
        if (raw.contains("|")) {
            parts = raw.split("\\|", -1);
        } else if (raw.contains(",")) {
            parts = raw.split(",", -1);
        } else {
            parts = raw.split("\\s+", -1);
        }
        for (int i = 0; i < parts.length; i++) {
            parts[i] = parts[i] != null ? parts[i].trim() : "";
        }

        int idx = 0;
        String type = defaultType;
        if (parts.length > 0 && isKnownType(parts[0].toLowerCase())) {
            type = parts[0].toLowerCase();
            idx = 1;
        }

        String baseUrl = idx < parts.length ? normalizeBaseUrl(parts[idx]) : "";
        int restStart = idx + 1;
        int restCount = Math.max(0, parts.length - restStart);

        String apiKey = "";
        String username = "";
        String password = "";
        String displayName = "";
        String remark = "";
        boolean activate = false;

        if ("webdav".equals(type)) {
            if (restCount > 0) username = parts[restStart];
            if (restCount > 1) password = parts[restStart + 1];
            if (restCount == 3) {
                remark = parts[restStart + 2];
            } else if (restCount == 4) {
                Boolean b = parseBoolOrNull(parts[restStart + 3]);
                if (b != null) {
                    remark = parts[restStart + 2];
                    activate = b;
                } else {
                    displayName = parts[restStart + 2];
                    remark = parts[restStart + 3];
                }
            } else if (restCount >= 5) {
                displayName = parts[restStart + 2];
                remark = parts[restStart + 3];
                Boolean b = parseBoolOrNull(parts[restStart + 4]);
                if (b != null) activate = b;
            }
        } else {
            if (restCount > 0) apiKey = parts[restStart];
            if (restCount == 2) {
                remark = parts[restStart + 1];
            } else if (restCount == 3) {
                Boolean b = parseBoolOrNull(parts[restStart + 2]);
                if (b != null) {
                    remark = parts[restStart + 1];
                    activate = b;
                } else {
                    displayName = parts[restStart + 1];
                    remark = parts[restStart + 2];
                }
            } else if (restCount >= 4) {
                displayName = parts[restStart + 1];
                remark = parts[restStart + 2];
                Boolean b = parseBoolOrNull(parts[restStart + 3]);
                if (b != null) activate = b;
            }
        }

        ParsedServer ps =
                validateAndBuild(type, baseUrl, apiKey, username, password, displayName, remark, activate);
        if (ps == null) {
            errors.add(label + ": invalid format");
        }
        return ps;
    }

    private static ParsedServer validateAndBuild(
            String type,
            String baseUrl,
            String apiKey,
            String username,
            String password,
            String displayName,
            String remark,
            boolean activate) {
        String t = type != null ? type.trim().toLowerCase() : "emby";
        String b = baseUrl != null ? baseUrl.trim() : "";
        String k = apiKey != null ? apiKey.trim() : "";
        String u = username != null ? username.trim() : "";
        String p = password != null ? password : "";
        if (b.isEmpty()) return null;

        if ("webdav".equals(t)) {
            if (u.isEmpty()) return null;
        } else if ("plex".equals(t)) {
            if (k.isEmpty()) return null;
        } else {
            if (k.isEmpty()) return null;
            if (!"emby".equals(t) && !"jellyfin".equals(t)) t = "emby";
        }

        ServerConfig cfg = new ServerConfig("", t, b, k, u, p, displayName, remark);
        return new ParsedServer(cfg, activate);
    }

    private static boolean isKnownType(String type) {
        String t = type != null ? type.trim().toLowerCase() : "";
        return "emby".equals(t) || "jellyfin".equals(t) || "plex".equals(t) || "webdav".equals(t);
    }

    private static Boolean parseBoolOrNull(String value) {
        String s = value != null ? value.trim().toLowerCase() : "";
        if ("true".equals(s) || "1".equals(s) || "yes".equals(s) || "y".equals(s)) return Boolean.TRUE;
        if ("false".equals(s) || "0".equals(s) || "no".equals(s) || "n".equals(s)) return Boolean.FALSE;
        return null;
    }

    private static String safe(String s) {
        return s != null ? s : "";
    }

    private static JSONObject jsonError(String msg) {
        try {
            JSONObject o = new JSONObject();
            o.put("ok", false);
            o.put("error", msg != null ? msg : "error");
            return o;
        } catch (JSONException e) {
            return new JSONObject();
        }
    }

    private static void writeJson(OutputStream out, JSONObject obj) {
        byte[] b = (obj != null ? obj.toString() : "{}").getBytes(UTF8);
        writeBytes(out, 200, "application/json; charset=utf-8", b);
    }

    private static void writePlain(OutputStream out, int code, String text) {
        byte[] b = (text != null ? text : "").getBytes(UTF8);
        writeBytes(out, code, "text/plain; charset=utf-8", b);
    }

    private static void writeBytes(OutputStream out, int code, String contentType, byte[] body) {
        if (out == null) return;
        byte[] b = body != null ? body : new byte[0];
        String status = statusText(code);
        try {
            String headers =
                    "HTTP/1.1 "
                            + code
                            + " "
                            + status
                            + "\r\n"
                            + "Content-Type: "
                            + contentType
                            + "\r\n"
                            + "Cache-Control: no-store\r\n"
                            + "Connection: close\r\n"
                            + "Content-Length: "
                            + b.length
                            + "\r\n"
                            + "\r\n";
            out.write(headers.getBytes(UTF8));
            out.write(b);
            out.flush();
        } catch (IOException ignored) {
        }
    }

    private static String statusText(int code) {
        if (code == 200) return "OK";
        if (code == 400) return "Bad Request";
        if (code == 401) return "Unauthorized";
        if (code == 404) return "Not Found";
        if (code == 405) return "Method Not Allowed";
        if (code == 500) return "Internal Server Error";
        return "OK";
    }

    private static int parseInt(String s, int fallback) {
        if (s == null) return fallback;
        try {
            return Integer.parseInt(s.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static String readLine(InputStream in) throws IOException {
        if (in == null) return null;
        ByteArrayOutputStream baos = new ByteArrayOutputStream(64);
        int c;
        boolean gotAny = false;
        while ((c = in.read()) != -1) {
            gotAny = true;
            if (c == '\n') break;
            if (c == '\r') {
                in.mark(1);
                int next = in.read();
                if (next != '\n') {
                    in.reset();
                }
                break;
            }
            baos.write(c);
            if (baos.size() > 8192) break;
        }
        if (!gotAny) return null;
        return baos.toString("UTF-8");
    }

    private static byte[] readBytes(InputStream in, int length) throws IOException {
        int len = Math.max(0, length);
        byte[] buf = new byte[len];
        int off = 0;
        while (off < len) {
            int n = in.read(buf, off, len - off);
            if (n == -1) break;
            off += n;
        }
        if (off == len) return buf;
        byte[] out = new byte[off];
        System.arraycopy(buf, 0, out, 0, off);
        return out;
    }

    private static Map<String, String> parseQuery(String query) {
        Map<String, String> out = new HashMap<>();
        String q = query != null ? query : "";
        if (q.isEmpty()) return out;
        String[] parts = q.split("&");
        for (String part : parts) {
            if (part == null || part.isEmpty()) continue;
            int idx = part.indexOf('=');
            String k = idx >= 0 ? part.substring(0, idx) : part;
            String v = idx >= 0 ? part.substring(idx + 1) : "";
            out.put(urlDecode(k), urlDecode(v));
        }
        return out;
    }

    private static String urlDecode(String s) {
        String v = s != null ? s : "";
        try {
            return URLDecoder.decode(v, "UTF-8");
        } catch (Exception e) {
            return v;
        }
    }

    private static boolean readBool(Object v, boolean fallback) {
        if (v == null) return fallback;
        if (v instanceof Boolean) return (Boolean) v;
        if (v instanceof Number) return ((Number) v).intValue() != 0;
        String s = String.valueOf(v).trim().toLowerCase();
        if ("true".equals(s) || "1".equals(s) || "yes".equals(s) || "y".equals(s)) return true;
        if ("false".equals(s) || "0".equals(s) || "no".equals(s) || "n".equals(s)) return false;
        return fallback;
    }

    private static String normalizeBaseUrl(String baseUrl) {
        String v = baseUrl != null ? baseUrl.trim() : "";
        if (v.isEmpty()) return "";
        if (!v.contains("://")) v = "http://" + v;
        while (v.endsWith("/")) v = v.substring(0, v.length() - 1);
        return v;
    }

    private static void closeQuietly(ServerSocket ss) {
        if (ss == null) return;
        try {
            ss.close();
        } catch (IOException ignored) {
        }
    }

    private static void closeQuietly(Socket s) {
        if (s == null) return;
        try {
            s.close();
        } catch (IOException ignored) {
        }
    }

    private String indexHtml() {
        String cached = cachedIndexHtml;
        if (cached != null && !cached.isEmpty()) return cached;
        InputStream in = null;
        try {
            in = appContext.getResources().openRawResource(R.raw.remote_index);
            ByteArrayOutputStream baos = new ByteArrayOutputStream(16 * 1024);
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) >= 0) {
                baos.write(buf, 0, n);
            }
            cachedIndexHtml = baos.toString("UTF-8");
            return cachedIndexHtml;
        } catch (Exception e) {
            return "<!doctype html><html><body><pre>remote ui missing</pre></body></html>";
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (IOException ignored) {
                }
            }
        }
    }

    private static final class ParsedServer {
        final ServerConfig config;
        final boolean activate;

        ParsedServer(ServerConfig config, boolean activate) {
            this.config = config;
            this.activate = activate;
        }
    }
}
