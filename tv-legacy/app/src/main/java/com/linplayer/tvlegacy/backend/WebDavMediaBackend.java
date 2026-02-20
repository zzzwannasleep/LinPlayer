package com.linplayer.tvlegacy.backend;

import android.content.Context;
import android.net.Uri;
import com.linplayer.tvlegacy.Episode;
import com.linplayer.tvlegacy.NetworkClients;
import com.linplayer.tvlegacy.Show;
import java.io.IOException;
import java.io.StringReader;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import okhttp3.Credentials;
import okhttp3.HttpUrl;
import okhttp3.Interceptor;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.xmlpull.v1.XmlPullParser;
import org.xmlpull.v1.XmlPullParserFactory;

final class WebDavMediaBackend implements MediaBackend {
    private static final MediaType XML = MediaType.parse("text/xml; charset=utf-8");

    private final Context appContext;
    private final HttpUrl baseUrl;
    private final String authHeader;
    private final OkHttpClient client;

    WebDavMediaBackend(Context context, String baseUrl, String username, String password) {
        this.appContext = context.getApplicationContext();
        String raw = normalizeBaseUrl(baseUrl);
        HttpUrl parsed = raw.isEmpty() ? null : HttpUrl.parse(ensureSlash(raw));
        this.baseUrl = parsed;
        String u = username != null ? username : "";
        String p = password != null ? password : "";
        this.authHeader = Credentials.basic(u, p);
        this.client =
                NetworkClients.okHttp(this.appContext)
                        .newBuilder()
                        .addInterceptor(
                                new Interceptor() {
                                    @Override
                                    public Response intercept(Chain chain) throws IOException {
                                        Request r =
                                                chain.request()
                                                        .newBuilder()
                                                        .header("Authorization", authHeader)
                                                        .build();
                                        return chain.proceed(r);
                                    }
                                })
                        .build();
    }

    @Override
    public void listShows(Callback<List<Show>> cb) {
        if (!isConfigured()) {
            AppExecutors.main(() -> cb.onError(new IllegalStateException("WebDAV not configured")));
            return;
        }
        AppExecutors.io(
                () -> {
                    try {
                        List<DavEntry> entries = propfind(baseUrl, 1);
                        List<Show> out = new ArrayList<>();
                        String self = baseUrl.toString();
                        for (DavEntry e : entries) {
                            if (e == null || e.href == null) continue;
                            if (!e.isCollection) continue;
                            if (sameUrl(self, e.href)) continue;
                            String title = e.displayName;
                            if (title == null || title.trim().isEmpty()) {
                                title = lastSegment(e.href);
                            }
                            out.add(new Show(e.href, title, ""));
                        }
                        AppExecutors.main(() -> cb.onSuccess(Collections.unmodifiableList(out)));
                    } catch (Exception e) {
                        AppExecutors.main(() -> cb.onError(e));
                    }
                });
    }

    @Override
    public void getShow(String showId, Callback<Show> cb) {
        if (!isConfigured()) {
            AppExecutors.main(() -> cb.onError(new IllegalStateException("WebDAV not configured")));
            return;
        }
        if (showId == null || showId.trim().isEmpty()) {
            AppExecutors.main(() -> cb.onSuccess(null));
            return;
        }
        String id = showId.trim();
        AppExecutors.io(
                () -> {
                    try {
                        String title = lastSegment(id);
                        Show show = new Show(id, title.isEmpty() ? id : title, "");
                        AppExecutors.main(() -> cb.onSuccess(show));
                    } catch (Exception e) {
                        AppExecutors.main(() -> cb.onError(e));
                    }
                });
    }

    @Override
    public void listEpisodes(String showId, Callback<List<Episode>> cb) {
        if (!isConfigured()) {
            AppExecutors.main(() -> cb.onError(new IllegalStateException("WebDAV not configured")));
            return;
        }
        if (showId == null || showId.trim().isEmpty()) {
            AppExecutors.main(() -> cb.onSuccess(Collections.emptyList()));
            return;
        }
        String id = showId.trim();
        AppExecutors.io(
                () -> {
                    try {
                        HttpUrl folder = HttpUrl.parse(ensureSlash(id));
                        if (folder == null) throw new IOException("invalid WebDAV folder url");
                        List<DavEntry> entries = propfind(folder, 1);
                        List<DavEntry> files = new ArrayList<>();
                        String self = folder.toString();
                        for (DavEntry e : entries) {
                            if (e == null || e.href == null) continue;
                            if (sameUrl(self, e.href)) continue;
                            if (e.isCollection) continue;
                            if (!isVideoFile(e.href)) continue;
                            files.add(e);
                        }
                        Collections.sort(
                                files,
                                new Comparator<DavEntry>() {
                                    @Override
                                    public int compare(DavEntry a, DavEntry b) {
                                        String ta = a != null ? safe(a.displayName) : "";
                                        String tb = b != null ? safe(b.displayName) : "";
                                        return ta.compareToIgnoreCase(tb);
                                    }
                                });

                        List<Episode> out = new ArrayList<>(files.size());
                        int idx = 1;
                        for (DavEntry e : files) {
                            String title = safe(e.displayName);
                            if (title.isEmpty()) title = lastSegment(e.href);
                            out.add(new Episode(e.href, idx, title, e.href));
                            idx++;
                        }
                        AppExecutors.main(() -> cb.onSuccess(Collections.unmodifiableList(out)));
                    } catch (Exception e) {
                        AppExecutors.main(() -> cb.onError(e));
                    }
                });
    }

    @Override
    public void getEpisode(String showId, int episodeIndex, Callback<Episode> cb) {
        if (!isConfigured()) {
            AppExecutors.main(() -> cb.onError(new IllegalStateException("WebDAV not configured")));
            return;
        }
        if (showId == null || showId.trim().isEmpty()) {
            AppExecutors.main(() -> cb.onSuccess(null));
            return;
        }
        String id = showId.trim();
        int index = episodeIndex;
        AppExecutors.io(
                () -> {
                    try {
                        List<Episode> list = loadEpisodes(id);
                        Episode found = null;
                        for (Episode e : list) {
                            if (e != null && e.index == index) {
                                found = e;
                                break;
                            }
                        }
                        Episode v = found;
                        AppExecutors.main(() -> cb.onSuccess(v));
                    } catch (Exception e) {
                        AppExecutors.main(() -> cb.onError(e));
                    }
                });
    }

    private List<Episode> loadEpisodes(String folderUrl) throws Exception {
        HttpUrl folder = HttpUrl.parse(ensureSlash(folderUrl));
        if (folder == null) return Collections.emptyList();
        List<DavEntry> entries = propfind(folder, 1);
        List<DavEntry> files = new ArrayList<>();
        String self = folder.toString();
        for (DavEntry e : entries) {
            if (e == null || e.href == null) continue;
            if (sameUrl(self, e.href)) continue;
            if (e.isCollection) continue;
            if (!isVideoFile(e.href)) continue;
            files.add(e);
        }
        Collections.sort(
                files,
                new Comparator<DavEntry>() {
                    @Override
                    public int compare(DavEntry a, DavEntry b) {
                        String ta = a != null ? safe(a.displayName) : "";
                        String tb = b != null ? safe(b.displayName) : "";
                        return ta.compareToIgnoreCase(tb);
                    }
                });

        List<Episode> out = new ArrayList<>(files.size());
        int idx = 1;
        for (DavEntry e : files) {
            String title = safe(e.displayName);
            if (title.isEmpty()) title = lastSegment(e.href);
            out.add(new Episode(e.href, idx, title, e.href));
            idx++;
        }
        return Collections.unmodifiableList(out);
    }

    private boolean isConfigured() {
        return baseUrl != null && authHeader != null && !authHeader.trim().isEmpty();
    }

    private List<DavEntry> propfind(HttpUrl url, int depth) throws Exception {
        String body =
                "<?xml version=\"1.0\" encoding=\"utf-8\" ?>\n"
                        + "<d:propfind xmlns:d=\"DAV:\">\n"
                        + "  <d:prop>\n"
                        + "    <d:displayname />\n"
                        + "    <d:resourcetype />\n"
                        + "  </d:prop>\n"
                        + "</d:propfind>\n";
        Request req =
                new Request.Builder()
                        .url(url)
                        .method("PROPFIND", RequestBody.create(XML, body))
                        .header("Depth", String.valueOf(depth))
                        .header("Accept", "application/xml")
                        .build();
        try (Response resp = client.newCall(req).execute()) {
            if (!resp.isSuccessful()) {
                throw new IOException("WebDAV: HTTP " + resp.code() + " " + resp.message());
            }
            ResponseBody rb = resp.body();
            String xml = rb != null ? rb.string() : "";
            List<DavEntry> parsed = parsePropfind(xml);
            // Normalize href to absolute URL for later navigation/playback.
            for (DavEntry d : parsed) {
                if (d == null) continue;
                d.href = resolveHref(url, d.href);
            }
            return parsed;
        }
    }

    private static String resolveHref(HttpUrl requestUrl, String href) {
        String h = safe(href);
        if (h.isEmpty()) return "";
        if (h.startsWith("http://") || h.startsWith("https://")) return normalizeUrl(h);
        if (requestUrl == null) return h;

        int q = h.indexOf('?');
        String path = q >= 0 ? h.substring(0, q) : h;
        String query = q >= 0 ? h.substring(q + 1) : "";
        if (path.startsWith("/")) {
            HttpUrl.Builder b = requestUrl.newBuilder();
            b.encodedPath(path);
            if (!query.isEmpty()) b.encodedQuery(query);
            return b.build().toString();
        }
        HttpUrl resolved = requestUrl.resolve(h);
        return resolved != null ? resolved.toString() : h;
    }

    private static List<DavEntry> parsePropfind(String xml) throws Exception {
        XmlPullParser p = newParser(xml);
        int e = p.getEventType();
        List<DavEntry> out = new ArrayList<>();
        DavEntry cur = null;
        boolean inResourceType = false;
        while (e != XmlPullParser.END_DOCUMENT) {
            if (e == XmlPullParser.START_TAG) {
                String name = p.getName();
                if ("response".equalsIgnoreCase(name)) {
                    cur = new DavEntry();
                } else if (cur != null) {
                    if ("href".equalsIgnoreCase(name)) {
                        cur.href = safe(p.nextText());
                    } else if ("displayname".equalsIgnoreCase(name)) {
                        cur.displayName = safe(p.nextText());
                    } else if ("resourcetype".equalsIgnoreCase(name)) {
                        inResourceType = true;
                    } else if (inResourceType && "collection".equalsIgnoreCase(name)) {
                        cur.isCollection = true;
                    }
                }
            } else if (e == XmlPullParser.END_TAG) {
                String name = p.getName();
                if ("resourcetype".equalsIgnoreCase(name)) {
                    inResourceType = false;
                } else if ("response".equalsIgnoreCase(name)) {
                    if (cur != null && cur.href != null && !cur.href.trim().isEmpty()) {
                        out.add(cur);
                    }
                    cur = null;
                }
            }
            e = p.next();
        }
        // Best effort: decode display name if empty.
        for (DavEntry d : out) {
            if (d == null) continue;
            if (d.displayName == null || d.displayName.trim().isEmpty()) {
                d.displayName = lastSegment(d.href);
            }
        }
        return out;
    }

    private static XmlPullParser newParser(String xml) throws Exception {
        XmlPullParserFactory f = XmlPullParserFactory.newInstance();
        f.setNamespaceAware(true);
        XmlPullParser p = f.newPullParser();
        p.setInput(new StringReader(xml != null ? xml : ""));
        return p;
    }

    private static boolean sameUrl(String a, String b) {
        String aa = normalizeUrl(a);
        String bb = normalizeUrl(b);
        return !aa.isEmpty() && aa.equals(bb);
    }

    private static String normalizeUrl(String u) {
        String v = u != null ? u.trim() : "";
        while (v.endsWith("/")) v = v.substring(0, v.length() - 1);
        return v;
    }

    private static String lastSegment(String url) {
        String u = url != null ? url : "";
        String decoded = Uri.decode(u);
        String v = decoded != null ? decoded : u;
        int q = v.indexOf('?');
        if (q >= 0) v = v.substring(0, q);
        while (v.endsWith("/")) v = v.substring(0, v.length() - 1);
        int idx = v.lastIndexOf('/');
        String seg = idx >= 0 ? v.substring(idx + 1) : v;
        return seg != null ? seg.trim() : "";
    }

    private static boolean isVideoFile(String href) {
        String name = lastSegment(href).toLowerCase();
        return name.endsWith(".mp4")
                || name.endsWith(".mkv")
                || name.endsWith(".webm")
                || name.endsWith(".m4v")
                || name.endsWith(".avi")
                || name.endsWith(".mov")
                || name.endsWith(".ts")
                || name.endsWith(".m2ts");
    }

    private static String ensureSlash(String url) {
        String v = url != null ? url.trim() : "";
        if (v.isEmpty()) return "";
        return v.endsWith("/") ? v : (v + "/");
    }

    private static String safe(String s) {
        return s != null ? s.trim() : "";
    }

    private static String normalizeBaseUrl(String baseUrl) {
        String v = baseUrl != null ? baseUrl.trim() : "";
        if (v.isEmpty()) return "";
        if (!v.contains("://")) v = "http://" + v;
        while (v.endsWith("/")) v = v.substring(0, v.length() - 1);
        return v;
    }

    private static final class DavEntry {
        String href;
        String displayName;
        boolean isCollection;
    }
}
