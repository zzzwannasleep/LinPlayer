package com.linplayer.tvlegacy.backend;

import android.content.Context;
import com.linplayer.tvlegacy.Episode;
import com.linplayer.tvlegacy.NetworkClients;
import com.linplayer.tvlegacy.Show;
import java.io.IOException;
import java.io.StringReader;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import okhttp3.HttpUrl;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.xmlpull.v1.XmlPullParser;
import org.xmlpull.v1.XmlPullParserFactory;

final class PlexMediaBackend implements MediaBackend {
    private final Context appContext;
    private final String token;
    private final HttpUrl baseUrl;
    private final OkHttpClient client;

    private final Object sectionLock = new Object();
    private String tvSectionKey;

    PlexMediaBackend(Context context, String baseUrl, String token) {
        this.appContext = context.getApplicationContext();
        this.token = token != null ? token.trim() : "";
        String raw = normalizeBaseUrl(baseUrl);
        this.baseUrl = raw.isEmpty() ? null : HttpUrl.parse(raw + "/");
        this.client = NetworkClients.okHttp(this.appContext);
    }

    @Override
    public void listShows(Callback<List<Show>> cb) {
        if (!isConfigured()) {
            AppExecutors.main(() -> cb.onError(new IllegalStateException("Plex not configured")));
            return;
        }
        AppExecutors.io(
                () -> {
                    try {
                        String section = requireTvSectionKey();
                        HttpUrl url =
                                plexUrl("library/sections/" + section + "/all")
                                        .addQueryParameter("type", "2")
                                        .addQueryParameter("sort", "titleSort:asc")
                                        .build();
                        String xml = httpGet(url);
                        List<Show> shows = parseShows(xml);
                        AppExecutors.main(() -> cb.onSuccess(shows));
                    } catch (Exception e) {
                        AppExecutors.main(() -> cb.onError(e));
                    }
                });
    }

    @Override
    public void getShow(String showId, Callback<Show> cb) {
        if (!isConfigured()) {
            AppExecutors.main(() -> cb.onError(new IllegalStateException("Plex not configured")));
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
                        HttpUrl url = plexUrl("library/metadata/" + id).build();
                        String xml = httpGet(url);
                        Show show = parseShow(xml);
                        AppExecutors.main(() -> cb.onSuccess(show));
                    } catch (Exception e) {
                        AppExecutors.main(() -> cb.onError(e));
                    }
                });
    }

    @Override
    public void listEpisodes(String showId, Callback<List<Episode>> cb) {
        if (!isConfigured()) {
            AppExecutors.main(() -> cb.onError(new IllegalStateException("Plex not configured")));
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
                        List<Episode> episodes = loadEpisodes(id);
                        AppExecutors.main(() -> cb.onSuccess(episodes));
                    } catch (Exception e) {
                        AppExecutors.main(() -> cb.onError(e));
                    }
                });
    }

    @Override
    public void getEpisode(String showId, int episodeIndex, Callback<Episode> cb) {
        if (!isConfigured()) {
            AppExecutors.main(() -> cb.onError(new IllegalStateException("Plex not configured")));
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
                        List<Episode> episodes = loadEpisodes(id);
                        Episode found = null;
                        for (Episode e : episodes) {
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

    private boolean isConfigured() {
        return baseUrl != null && token != null && !token.isEmpty();
    }

    private HttpUrl.Builder plexUrl(String path) {
        if (baseUrl == null) throw new IllegalStateException("baseUrl == null");
        String p = path != null ? path.trim() : "";
        while (p.startsWith("/")) p = p.substring(1);
        HttpUrl.Builder b = baseUrl.newBuilder();
        if (!p.isEmpty()) b.addPathSegments(p);
        b.addQueryParameter("X-Plex-Token", token);
        return b;
    }

    private String requireTvSectionKey() throws Exception {
        String cached = tvSectionKey;
        if (cached != null && !cached.trim().isEmpty()) return cached;
        synchronized (sectionLock) {
            cached = tvSectionKey;
            if (cached != null && !cached.trim().isEmpty()) return cached;
            HttpUrl url = plexUrl("library/sections").build();
            String xml = httpGet(url);
            String key = parseTvSectionKey(xml);
            if (key == null || key.trim().isEmpty()) {
                throw new IOException("Plex: cannot find TV show library section");
            }
            tvSectionKey = key.trim();
            return tvSectionKey;
        }
    }

    private List<Episode> loadEpisodes(String showId) throws Exception {
        HttpUrl url = plexUrl("library/metadata/" + showId + "/allLeaves").build();
        String xml = httpGet(url);
        List<EpisodeItem> items = parseEpisodeItems(xml);
        Collections.sort(
                items,
                new Comparator<EpisodeItem>() {
                    @Override
                    public int compare(EpisodeItem a, EpisodeItem b) {
                        int sa = a != null ? a.season : 0;
                        int sb = b != null ? b.season : 0;
                        if (sa != sb) return sa - sb;
                        int ea = a != null ? a.episode : 0;
                        int eb = b != null ? b.episode : 0;
                        if (ea != eb) return ea - eb;
                        String ta = a != null ? a.title : "";
                        String tb = b != null ? b.title : "";
                        return ta.compareToIgnoreCase(tb);
                    }
                });

        List<Episode> out = new ArrayList<>(items.size());
        int idx = 1;
        for (EpisodeItem it : items) {
            if (it == null) continue;
            String mediaUrl = buildPartUrl(it.partKey);
            String title = it.title != null && !it.title.trim().isEmpty() ? it.title.trim() : ("Episode " + idx);
            out.add(new Episode(it.id, idx, title, mediaUrl));
            idx++;
        }
        return Collections.unmodifiableList(out);
    }

    private String buildPartUrl(String partKey) {
        String key = partKey != null ? partKey.trim() : "";
        if (key.isEmpty() || baseUrl == null) return "";
        HttpUrl resolved = baseUrl.resolve(key.startsWith("/") ? key.substring(1) : key);
        if (resolved == null) return "";
        HttpUrl u = resolved.newBuilder().addQueryParameter("X-Plex-Token", token).build();
        return u.toString();
    }

    private String httpGet(HttpUrl url) throws IOException {
        Request req =
                new Request.Builder()
                        .url(url)
                        .get()
                        .header("Accept", "application/xml")
                        .build();
        try (Response resp = client.newCall(req).execute()) {
            if (!resp.isSuccessful()) {
                throw new IOException("Plex: HTTP " + resp.code() + " " + resp.message());
            }
            ResponseBody body = resp.body();
            return body != null ? body.string() : "";
        }
    }

    private static List<Show> parseShows(String xml) throws Exception {
        List<Show> out = new ArrayList<>();
        XmlPullParser p = newParser(xml);
        int e = p.getEventType();
        while (e != XmlPullParser.END_DOCUMENT) {
            if (e == XmlPullParser.START_TAG) {
                String name = p.getName();
                if ("Directory".equals(name)) {
                    String id = attr(p, "ratingKey");
                    String title = attr(p, "title");
                    String overview = attr(p, "summary");
                    if (!id.isEmpty()) {
                        out.add(new Show(id, title.isEmpty() ? id : title, overview));
                    }
                }
            }
            e = p.next();
        }
        return Collections.unmodifiableList(out);
    }

    private static Show parseShow(String xml) throws Exception {
        XmlPullParser p = newParser(xml);
        int e = p.getEventType();
        while (e != XmlPullParser.END_DOCUMENT) {
            if (e == XmlPullParser.START_TAG) {
                String name = p.getName();
                if ("Directory".equals(name) || "Video".equals(name)) {
                    String id = attr(p, "ratingKey");
                    String title = attr(p, "title");
                    String overview = attr(p, "summary");
                    if (!id.isEmpty()) {
                        return new Show(id, title.isEmpty() ? id : title, overview);
                    }
                }
            }
            e = p.next();
        }
        return null;
    }

    private static String parseTvSectionKey(String xml) throws Exception {
        XmlPullParser p = newParser(xml);
        int e = p.getEventType();
        while (e != XmlPullParser.END_DOCUMENT) {
            if (e == XmlPullParser.START_TAG && "Directory".equals(p.getName())) {
                String type = attr(p, "type").toLowerCase();
                if ("show".equals(type)) {
                    String key = attr(p, "key");
                    if (!key.isEmpty()) return key;
                }
            }
            e = p.next();
        }
        return "";
    }

    private static List<EpisodeItem> parseEpisodeItems(String xml) throws Exception {
        List<EpisodeItem> out = new ArrayList<>();
        XmlPullParser p = newParser(xml);
        int e = p.getEventType();
        EpisodeItem cur = null;
        while (e != XmlPullParser.END_DOCUMENT) {
            if (e == XmlPullParser.START_TAG) {
                String name = p.getName();
                if ("Video".equals(name)) {
                    String type = attr(p, "type").toLowerCase();
                    if ("episode".equals(type)) {
                        cur = new EpisodeItem();
                        cur.id = attr(p, "ratingKey");
                        cur.title = attr(p, "title");
                        cur.season = parseInt(attr(p, "parentIndex"), 0);
                        cur.episode = parseInt(attr(p, "index"), 0);
                        cur.partKey = "";
                    } else {
                        cur = null;
                    }
                } else if ("Part".equals(name)) {
                    if (cur != null && (cur.partKey == null || cur.partKey.isEmpty())) {
                        cur.partKey = attr(p, "key");
                    }
                }
            } else if (e == XmlPullParser.END_TAG) {
                if ("Video".equals(p.getName()) && cur != null) {
                    if (cur.id != null
                            && !cur.id.trim().isEmpty()
                            && cur.partKey != null
                            && !cur.partKey.trim().isEmpty()) {
                        out.add(cur);
                    }
                    cur = null;
                }
            }
            e = p.next();
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

    private static String attr(XmlPullParser p, String name) {
        if (p == null) return "";
        String v = p.getAttributeValue(null, name);
        return v != null ? v.trim() : "";
    }

    private static int parseInt(String s, int fallback) {
        if (s == null) return fallback;
        try {
            return Integer.parseInt(s.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static String normalizeBaseUrl(String baseUrl) {
        String v = baseUrl != null ? baseUrl.trim() : "";
        if (v.isEmpty()) return "";
        if (!v.contains("://")) v = "http://" + v;
        while (v.endsWith("/")) v = v.substring(0, v.length() - 1);
        return v;
    }

    private static final class EpisodeItem {
        String id;
        String title;
        int season;
        int episode;
        String partKey;
    }
}
