package com.linplayer.tvlegacy.backend;

import android.content.Context;
import com.linplayer.tvlegacy.Episode;
import com.linplayer.tvlegacy.NetworkClients;
import com.linplayer.tvlegacy.Show;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import okhttp3.HttpUrl;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

final class EmbyLikeMediaBackend implements MediaBackend {
    private final Context appContext;
    private final String serverName;
    private final String apiKey;
    private final HttpUrl baseUrl;

    private final Object userLock = new Object();
    private String userId;

    EmbyLikeMediaBackend(Context context, String baseUrl, String apiKey, String serverName) {
        this.appContext = context.getApplicationContext();
        this.serverName = serverName != null && !serverName.trim().isEmpty() ? serverName.trim() : "Server";

        String rawKey = apiKey != null ? apiKey.trim() : "";
        this.apiKey = rawKey;

        String rawBase = normalizeBaseUrl(baseUrl);
        this.baseUrl = rawBase.isEmpty() ? null : HttpUrl.parse(rawBase);
    }

    @Override
    public void listShows(Callback<List<Show>> cb) {
        if (!isConfigured()) {
            failNotConfigured(cb);
            return;
        }

        AppExecutors.io(
                () -> {
                    try {
                        String uid = requireUserId();
                        HttpUrl url =
                                apiUrl("Users/" + uid + "/Items")
                                        .addQueryParameter("IncludeItemTypes", "Series")
                                        .addQueryParameter("Recursive", "true")
                                        .addQueryParameter("Fields", "Overview")
                                        .addQueryParameter("SortBy", "SortName")
                                        .addQueryParameter("SortOrder", "Ascending")
                                        .addQueryParameter("Limit", "50")
                                        .build();
                        JSONObject root = getJsonObject(url);
                        JSONArray items = root.optJSONArray("Items");
                        List<Show> shows = parseShows(items);
                        AppExecutors.main(() -> cb.onSuccess(shows));
                    } catch (Exception e) {
                        AppExecutors.main(() -> cb.onError(e));
                    }
                });
    }

    @Override
    public void getShow(String showId, Callback<Show> cb) {
        if (!isConfigured()) {
            failNotConfigured(cb);
            return;
        }
        if (showId == null || showId.trim().isEmpty()) {
            AppExecutors.main(() -> cb.onSuccess(null));
            return;
        }

        AppExecutors.io(
                () -> {
                    try {
                        String uid = requireUserId();
                        HttpUrl url =
                                apiUrl("Users/" + uid + "/Items/" + showId.trim())
                                        .addQueryParameter("Fields", "Overview")
                                        .build();
                        JSONObject item = getJsonObject(url);
                        Show show = parseShow(item);
                        AppExecutors.main(() -> cb.onSuccess(show));
                    } catch (Exception e) {
                        AppExecutors.main(() -> cb.onError(e));
                    }
                });
    }

    @Override
    public void listEpisodes(String showId, Callback<List<Episode>> cb) {
        if (!isConfigured()) {
            failNotConfigured(cb);
            return;
        }
        if (showId == null || showId.trim().isEmpty()) {
            AppExecutors.main(() -> cb.onSuccess(Collections.emptyList()));
            return;
        }

        AppExecutors.io(
                () -> {
                    try {
                        List<Episode> episodes = loadEpisodes(showId.trim());
                        AppExecutors.main(() -> cb.onSuccess(episodes));
                    } catch (Exception e) {
                        AppExecutors.main(() -> cb.onError(e));
                    }
                });
    }

    @Override
    public void getEpisode(String showId, int episodeIndex, Callback<Episode> cb) {
        if (!isConfigured()) {
            failNotConfigured(cb);
            return;
        }
        if (showId == null || showId.trim().isEmpty()) {
            AppExecutors.main(() -> cb.onSuccess(null));
            return;
        }
        int index = episodeIndex;

        AppExecutors.io(
                () -> {
                    try {
                        List<Episode> episodes = loadEpisodes(showId.trim());
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
        return baseUrl != null && apiKey != null && !apiKey.isEmpty();
    }

    private <T> void failNotConfigured(Callback<T> cb) {
        AppExecutors.main(
                () ->
                        cb.onError(
                                new IllegalStateException(
                                        serverName
                                                + " not configured. Open Settings and set Server URL + API key.")));
    }

    private HttpUrl.Builder apiUrl(String path) {
        if (baseUrl == null) throw new IllegalStateException("baseUrl == null");
        String p = path != null ? path.trim() : "";
        if (p.startsWith("/")) p = p.substring(1);
        HttpUrl.Builder b = baseUrl.newBuilder();
        if (!p.isEmpty()) b.addPathSegments(p);
        if (apiKey != null && !apiKey.isEmpty()) b.addQueryParameter("api_key", apiKey);
        return b;
    }

    private String requireUserId() throws IOException, JSONException {
        String cached = userId;
        if (cached != null && !cached.isEmpty()) return cached;
        synchronized (userLock) {
            cached = userId;
            if (cached != null && !cached.isEmpty()) return cached;

            HttpUrl url = apiUrl("Users/Me").build();
            JSONObject obj = getJsonObject(url);
            String id = obj.optString("Id", "");
            if (id == null || id.trim().isEmpty()) {
                throw new IOException(serverName + ": missing user id from /Users/Me");
            }
            userId = id.trim();
            return userId;
        }
    }

    private List<Episode> loadEpisodes(String showId) throws IOException, JSONException {
        String uid = requireUserId();
        HttpUrl url =
                apiUrl("Shows/" + showId + "/Episodes")
                        .addQueryParameter("UserId", uid)
                        .addQueryParameter("SortBy", "IndexNumber")
                        .addQueryParameter("SortOrder", "Ascending")
                        .addQueryParameter("Limit", "200")
                        .build();
        JSONObject root = getJsonObject(url);
        JSONArray items = root.optJSONArray("Items");
        if (items == null) return Collections.emptyList();

        List<Episode> list = new ArrayList<>(items.length());
        for (int i = 0; i < items.length(); i++) {
            JSONObject it = items.optJSONObject(i);
            if (it == null) continue;

            String id = it.optString("Id", "");
            if (id == null || id.trim().isEmpty()) continue;

            String name = it.optString("Name", "");
            int season = it.optInt("ParentIndexNumber", 0);
            int ep = it.optInt("IndexNumber", 0);
            String prefix = "";
            if (season > 0 && ep > 0) {
                prefix = "S" + season + "E" + ep + " ";
            } else if (ep > 0) {
                prefix = "EP " + ep + " ";
            }

            int index = list.size() + 1;
            String title =
                    (prefix + (name != null && !name.trim().isEmpty() ? name.trim() : "Episode " + index))
                            .trim();
            String mediaUrl = streamUrl(id.trim());
            list.add(new Episode(id.trim(), index, title, mediaUrl));
        }
        return Collections.unmodifiableList(list);
    }

    private String streamUrl(String itemId) {
        HttpUrl url =
                apiUrl("Videos/" + itemId + "/stream")
                        .addQueryParameter("static", "true")
                        .build();
        return url.toString();
    }

    private JSONObject getJsonObject(HttpUrl url) throws IOException, JSONException {
        OkHttpClient client = NetworkClients.okHttp(appContext);
        Request req =
                new Request.Builder()
                        .url(url)
                        .get()
                        .header("Accept", "application/json")
                        .build();
        try (Response resp = client.newCall(req).execute()) {
            if (!resp.isSuccessful()) {
                throw new IOException(
                        serverName
                                + ": HTTP "
                                + resp.code()
                                + " "
                                + resp.message()
                                + " for "
                                + url);
            }
            ResponseBody body = resp.body();
            String s = body != null ? body.string() : "";
            return new JSONObject(s);
        }
    }

    private static List<Show> parseShows(JSONArray items) {
        if (items == null) return Collections.emptyList();
        List<Show> list = new ArrayList<>(items.length());
        for (int i = 0; i < items.length(); i++) {
            JSONObject it = items.optJSONObject(i);
            if (it == null) continue;
            Show s = parseShow(it);
            if (s != null) list.add(s);
        }
        return Collections.unmodifiableList(list);
    }

    private static Show parseShow(JSONObject it) {
        if (it == null) return null;
        String id = it.optString("Id", "");
        if (id == null || id.trim().isEmpty()) return null;

        String name = it.optString("Name", "");
        String title = name != null && !name.trim().isEmpty() ? name.trim() : id.trim();
        String overview = it.optString("Overview", "");
        String ov = overview != null ? overview : "";
        return new Show(id.trim(), title, ov);
    }

    private static String normalizeBaseUrl(String baseUrl) {
        String v = baseUrl != null ? baseUrl.trim() : "";
        while (v.endsWith("/")) v = v.substring(0, v.length() - 1);
        return v;
    }
}

