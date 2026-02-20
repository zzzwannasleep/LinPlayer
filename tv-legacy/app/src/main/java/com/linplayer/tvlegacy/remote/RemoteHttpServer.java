package com.linplayer.tvlegacy.remote;

import android.content.Context;
import com.linplayer.tvlegacy.AppPrefs;
import com.linplayer.tvlegacy.BuildConfig;
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
import java.util.HashMap;
import java.util.Map;
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

        writePlain(out, 404, "not found");
    }

    private boolean checkToken(String token) {
        String t = token != null ? token.trim() : "";
        String cur = getToken();
        return !cur.isEmpty() && cur.equals(t);
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

    private static String indexHtml() {
        return "<!doctype html>"
                + "<html><head><meta charset='utf-8'/>"
                + "<meta name='viewport' content='width=device-width, initial-scale=1'/>"
                + "<title>LinPlayer TV Legacy</title>"
                + "<style>"
                + "body{font-family:system-ui,-apple-system,Segoe UI,Roboto; padding:16px; background:#0b0b0b; color:#fff;}"
                + ".card{max-width:760px;margin:0 auto;background:#141414;border:1px solid rgba(255,255,255,.12);border-radius:14px;padding:14px;}"
                + "label{display:block;margin-top:10px;opacity:.9}"
                + "input,select,button{width:100%;padding:10px;border-radius:10px;border:1px solid rgba(255,255,255,.18);background:#0f0f0f;color:#fff;box-sizing:border-box;font-size:16px}"
                + "button{margin-top:12px;cursor:pointer}"
                + "pre{white-space:pre-wrap;word-break:break-word;font-size:12px;opacity:.85}"
                + ".row{display:grid;grid-template-columns:1fr 1fr;gap:10px}"
                + "@media(max-width:640px){.row{grid-template-columns:1fr}}"
                + "</style></head><body>"
                + "<div class='card'>"
                + "<h2>LinPlayer · TV 扫码输入</h2>"
                + "<div id='info' style='opacity:.85'>Connecting…</div>"
                + "<hr style='opacity:.2;margin:14px 0'/>"
                + "<form id='f'>"
                + "<label>类型</label>"
                + "<select id='type'>"
                + "<option value='emby'>Emby</option>"
                + "<option value='jellyfin'>Jellyfin</option>"
                + "<option value='webdav'>WebDAV</option>"
                + "<option value='plex'>Plex（Token）</option>"
                + "</select>"
                + "<label>Base URL</label>"
                + "<input id='baseUrl' placeholder='例如：http://192.168.1.2:8096 或 https://example.com'/>"
                + "<label>API key / Token（Emby/Jellyfin/Plex）</label>"
                + "<input id='apiKey' placeholder='Plex 填 token'/>"
                + "<div class='row'>"
                + "<div><label>WebDAV 用户名</label><input id='username'/></div>"
                + "<div><label>WebDAV 密码</label><input id='password' type='password'/></div>"
                + "</div>"
                + "<div class='row'>"
                + "<div><label>显示名（可选）</label><input id='displayName'/></div>"
                + "<div><label>备注（可选）</label><input id='remark'/></div>"
                + "</div>"
                + "<label style='display:flex;align-items:center;gap:10px;margin-top:12px'>"
                + "<input id='activate' type='checkbox' checked style='width:20px;height:20px;margin:0'/>添加后设为当前服务器</label>"
                + "<button type='submit'>添加到 TV</button>"
                + "</form>"
                + "<pre id='log'></pre>"
                + "</div>"
                + "<script>"
                + "const qs=new URLSearchParams(location.search);"
                + "const token=qs.get('token')||'';"
                + "const info=document.getElementById('info');"
                + "const logEl=document.getElementById('log');"
                + "const log=(s)=>{logEl.textContent=(new Date().toLocaleTimeString())+' '+s+'\\n'+logEl.textContent};"
                + "const loadInfo=async()=>{"
                + " if(!token){info.textContent='缺少 token：请重新扫码打开。';return;}"
                + " try{const res=await fetch('/api/info?token='+encodeURIComponent(token),{cache:'no-store'});"
                + " const data=await res.json();"
                + " if(!data.ok) throw new Error(data.error||'unknown');"
                + " const app=data.app||{}; const s=data.server||{};"
                + " info.textContent=(app.name||'LinPlayer')+' '+(app.version||'')+(s.activeServerName?(' · 当前：'+s.activeServerName):'');"
                + " }catch(e){info.textContent='连接失败：'+e;}"
                + "}; loadInfo();"
                + "document.getElementById('f').addEventListener('submit',async(e)=>{"
                + " e.preventDefault();"
                + " if(!token){log('缺少 token');return;}"
                + " const payload={"
                + " token,"
                + " type:document.getElementById('type').value,"
                + " baseUrl:document.getElementById('baseUrl').value,"
                + " apiKey:document.getElementById('apiKey').value,"
                + " username:document.getElementById('username').value,"
                + " password:document.getElementById('password').value,"
                + " displayName:document.getElementById('displayName').value,"
                + " remark:document.getElementById('remark').value,"
                + " activate:document.getElementById('activate').checked"
                + " };"
                + " log('提交中…');"
                + " try{const res=await fetch('/api/addServer',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(payload)});"
                + " const data=await res.json();"
                + " if(!data.ok) throw new Error(data.error||'unknown');"
                + " log('成功：已添加'); await loadInfo();"
                + " }catch(e){log('失败：'+e);}"
                + "});"
                + "</script>"
                + "</body></html>";
    }
}

