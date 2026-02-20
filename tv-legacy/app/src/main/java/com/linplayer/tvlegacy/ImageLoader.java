package com.linplayer.tvlegacy;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Handler;
import android.os.Looper;
import android.util.LruCache;
import android.widget.ImageView;
import java.lang.ref.WeakReference;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;

public final class ImageLoader {
    private static final ExecutorService IO = Executors.newFixedThreadPool(2);
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    private static final LruCache<String, Bitmap> CACHE =
            new LruCache<String, Bitmap>(cacheSizeKb()) {
                @Override
                protected int sizeOf(String key, Bitmap value) {
                    if (value == null) return 0;
                    return Math.max(1, value.getByteCount() / 1024);
                }
            };

    private ImageLoader() {}

    public static void load(ImageView view, String url, int maxSizePx) {
        if (view == null) return;
        String u = url != null ? url.trim() : "";
        view.setTag(R.id.tag_image_url, u);
        if (u.isEmpty()) {
            view.setImageDrawable(null);
            return;
        }

        Bitmap cached = CACHE.get(u);
        if (cached != null) {
            view.setImageBitmap(cached);
            return;
        }

        view.setImageDrawable(null);

        WeakReference<ImageView> ref = new WeakReference<>(view);
        Context appContext = view.getContext().getApplicationContext();
        IO.execute(
                () -> {
                    Bitmap bmp = null;
                    try {
                        bmp = fetchBitmap(appContext, u, maxSizePx);
                    } catch (Exception ignored) {
                        // ignore
                    }
                    Bitmap result = bmp;
                    if (result != null) {
                        CACHE.put(u, result);
                    }
                    MAIN.post(
                            () -> {
                                ImageView v = ref.get();
                                if (v == null) return;
                                Object tag = v.getTag(R.id.tag_image_url);
                                if (tag == null || !u.equals(tag.toString())) return;
                                if (result != null) {
                                    v.setImageBitmap(result);
                                }
                            });
                });
    }

    private static Bitmap fetchBitmap(Context context, String url, int maxSizePx) throws Exception {
        if (context == null) return null;
        OkHttpClient client = NetworkClients.okHttp(context);
        Request req = new Request.Builder().url(url).get().build();
        try (Response resp = client.newCall(req).execute()) {
            if (!resp.isSuccessful()) return null;
            ResponseBody body = resp.body();
            byte[] bytes = body != null ? body.bytes() : null;
            if (bytes == null || bytes.length == 0) return null;
            return decodeDownsampled(bytes, maxSizePx);
        }
    }

    private static Bitmap decodeDownsampled(byte[] data, int maxSizePx) {
        if (data == null || data.length == 0) return null;
        int max = maxSizePx > 0 ? maxSizePx : 0;

        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(data, 0, data.length, bounds);
        int w = bounds.outWidth;
        int h = bounds.outHeight;
        if (w <= 0 || h <= 0) {
            return BitmapFactory.decodeByteArray(data, 0, data.length);
        }

        int sample = 1;
        if (max > 0) {
            while ((w / sample) > max || (h / sample) > max) {
                sample *= 2;
            }
        }

        BitmapFactory.Options opts = new BitmapFactory.Options();
        opts.inSampleSize = Math.max(1, sample);
        opts.inPreferredConfig = Bitmap.Config.RGB_565;
        opts.inDither = true;
        return BitmapFactory.decodeByteArray(data, 0, data.length, opts);
    }

    private static int cacheSizeKb() {
        long maxBytes = Runtime.getRuntime().maxMemory();
        long target = maxBytes / 8;
        if (target < 8L * 1024 * 1024) target = 8L * 1024 * 1024;
        if (target > 32L * 1024 * 1024) target = 32L * 1024 * 1024;
        return (int) (target / 1024);
    }
}

