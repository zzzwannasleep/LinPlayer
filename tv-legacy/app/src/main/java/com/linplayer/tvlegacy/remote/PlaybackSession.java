package com.linplayer.tvlegacy.remote;

import android.os.Handler;
import android.os.Looper;
import com.google.android.exoplayer2.C;
import com.google.android.exoplayer2.SimpleExoPlayer;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.json.JSONException;
import org.json.JSONObject;

public final class PlaybackSession {
    private static final Object LOCK = new Object();
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    private static SimpleExoPlayer player;
    private static String title = "";

    private PlaybackSession() {}

    public static void attach(SimpleExoPlayer p, String titleText) {
        if (p == null) return;
        synchronized (LOCK) {
            player = p;
            title = titleText != null ? titleText : "";
        }
    }

    public static void detach(SimpleExoPlayer p) {
        synchronized (LOCK) {
            if (player == p) {
                player = null;
                title = "";
            }
        }
    }

    public static JSONObject status() {
        final JSONObject[] out = new JSONObject[1];
        final CountDownLatch latch = new CountDownLatch(1);
        MAIN.post(
                () -> {
                    out[0] = buildStatusLocked();
                    latch.countDown();
                });
        try {
            // Best-effort: remote calls should respond quickly.
            latch.await(250, TimeUnit.MILLISECONDS);
        } catch (InterruptedException ignored) {
        }
        JSONObject v = out[0];
        return v != null ? v : jsonError("timeout");
    }

    public static JSONObject control(String action, long value) {
        final JSONObject[] out = new JSONObject[1];
        final CountDownLatch latch = new CountDownLatch(1);
        final String a = action != null ? action.trim().toLowerCase() : "";
        MAIN.post(
                () -> {
                    out[0] = applyControlLocked(a, value);
                    latch.countDown();
                });
        try {
            latch.await(600, TimeUnit.MILLISECONDS);
        } catch (InterruptedException ignored) {
        }
        JSONObject v = out[0];
        return v != null ? v : jsonError("timeout");
    }

    private static JSONObject applyControlLocked(String action, long value) {
        SimpleExoPlayer p;
        synchronized (LOCK) {
            p = player;
        }
        if (p == null) return inactive();

        try {
            if ("toggle".equals(action)) {
                p.setPlayWhenReady(!p.getPlayWhenReady());
            } else if ("play".equals(action)) {
                p.setPlayWhenReady(true);
            } else if ("pause".equals(action)) {
                p.setPlayWhenReady(false);
            } else if ("stop".equals(action)) {
                p.stop();
                p.setPlayWhenReady(false);
            } else if ("seekbyms".equals(action) || "seek_by_ms".equals(action) || "seekby".equals(action)) {
                long pos = p.getCurrentPosition();
                long dur = p.getDuration();
                if (dur == C.TIME_UNSET) dur = -1;
                long next = pos + value;
                if (next < 0) next = 0;
                if (dur > 0 && next > dur) next = dur;
                p.seekTo(next);
            } else if ("seektoms".equals(action) || "seek_to_ms".equals(action)) {
                long dur = p.getDuration();
                if (dur == C.TIME_UNSET) dur = -1;
                long next = value;
                if (next < 0) next = 0;
                if (dur > 0 && next > dur) next = dur;
                p.seekTo(next);
            } else {
                return jsonError("unknown action");
            }
            return buildStatusLocked();
        } catch (Exception e) {
            return jsonError(String.valueOf(e.getMessage()));
        }
    }

    private static JSONObject buildStatusLocked() {
        SimpleExoPlayer p;
        String t;
        synchronized (LOCK) {
            p = player;
            t = title;
        }
        if (p == null) return inactive();

        long pos = 0;
        long dur = 0;
        boolean playing = false;
        try {
            pos = p.getCurrentPosition();
            long d = p.getDuration();
            dur = d == C.TIME_UNSET ? 0 : Math.max(0, d);
            playing = p.getPlayWhenReady() && p.getPlaybackState() == com.google.android.exoplayer2.Player.STATE_READY;
        } catch (Exception ignored) {
        }

        try {
            JSONObject o = new JSONObject();
            o.put("ok", true);
            o.put("active", true);
            o.put("title", t != null ? t : "");
            o.put("playing", playing);
            o.put("positionMs", pos);
            o.put("durationMs", dur);
            return o;
        } catch (JSONException e) {
            return jsonError("json error");
        }
    }

    private static JSONObject inactive() {
        try {
            JSONObject o = new JSONObject();
            o.put("ok", true);
            o.put("active", false);
            return o;
        } catch (JSONException e) {
            return new JSONObject();
        }
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
}

