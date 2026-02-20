package com.linplayer.tvlegacy;

import android.content.Context;
import java.io.IOException;
import java.net.Proxy;
import java.net.ProxySelector;
import okhttp3.Interceptor;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

public final class NetworkClients {
    private static final Object LOCK = new Object();

    private static OkHttpClient directClient;
    private static OkHttpClient proxyClient;

    private NetworkClients() {}

    public static OkHttpClient okHttp(Context context) {
        boolean enabled = AppPrefs.isProxyEnabled(context);
        return enabled ? proxyOkHttp() : directOkHttp();
    }

    private static OkHttpClient directOkHttp() {
        synchronized (LOCK) {
            if (directClient != null) return directClient;
            directClient =
                    baseBuilder()
                            // Force direct connection (ignore system proxy).
                            .proxy(Proxy.NO_PROXY)
                            .build();
            return directClient;
        }
    }

    private static OkHttpClient proxyOkHttp() {
        synchronized (LOCK) {
            if (proxyClient != null) return proxyClient;
            proxyClient =
                    baseBuilder()
                            .proxySelector(
                                    new PerAppProxySelector(
                                            "127.0.0.1",
                                            MihomoConfig.MIXED_PORT,
                                            ProxySelector.getDefault()))
                            .build();
            return proxyClient;
        }
    }

    private static OkHttpClient.Builder baseBuilder() {
        return new OkHttpClient.Builder()
                .addInterceptor(
                        new Interceptor() {
                            @Override
                            public Response intercept(Chain chain) throws IOException {
                                Request r =
                                        chain.request()
                                                .newBuilder()
                                                .header("User-Agent", NetworkConfig.userAgent())
                                                .build();
                                return chain.proceed(r);
                            }
                        });
    }
}
