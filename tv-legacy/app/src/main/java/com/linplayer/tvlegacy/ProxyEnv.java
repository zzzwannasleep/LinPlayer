package com.linplayer.tvlegacy;

import java.net.ProxySelector;

final class ProxyEnv {
    private static final Object LOCK = new Object();
    private static ProxySelector original;

    private static String origHttpProxyHost;
    private static String origHttpProxyPort;
    private static String origHttpsProxyHost;
    private static String origHttpsProxyPort;
    private static String origNonProxyHosts;

    private ProxyEnv() {}

    static void enable() {
        synchronized (LOCK) {
            if (original == null) {
                original = ProxySelector.getDefault();
                captureProxyProps();
            }
            ProxySelector.setDefault(
                    new PerAppProxySelector(
                            "127.0.0.1",
                            MihomoConfig.MIXED_PORT,
                            original));

            // Ensure Java/HttpURLConnection based stacks (e.g. ExoPlayer DefaultHttpDataSource)
            // also go through the per-app proxy.
            System.setProperty("http.proxyHost", "127.0.0.1");
            System.setProperty("http.proxyPort", String.valueOf(MihomoConfig.MIXED_PORT));
            System.setProperty("https.proxyHost", "127.0.0.1");
            System.setProperty("https.proxyPort", String.valueOf(MihomoConfig.MIXED_PORT));
            System.setProperty("http.nonProxyHosts", "localhost|127.*|[::1]");
        }
    }

    static void disable() {
        synchronized (LOCK) {
            if (original != null) {
                ProxySelector.setDefault(original);
                original = null;
            }
            restoreProxyProps();
        }
    }

    private static void captureProxyProps() {
        origHttpProxyHost = System.getProperty("http.proxyHost");
        origHttpProxyPort = System.getProperty("http.proxyPort");
        origHttpsProxyHost = System.getProperty("https.proxyHost");
        origHttpsProxyPort = System.getProperty("https.proxyPort");
        origNonProxyHosts = System.getProperty("http.nonProxyHosts");
    }

    private static void restoreProxyProps() {
        setOrClear("http.proxyHost", origHttpProxyHost);
        setOrClear("http.proxyPort", origHttpProxyPort);
        setOrClear("https.proxyHost", origHttpsProxyHost);
        setOrClear("https.proxyPort", origHttpsProxyPort);
        setOrClear("http.nonProxyHosts", origNonProxyHosts);

        origHttpProxyHost = null;
        origHttpProxyPort = null;
        origHttpsProxyHost = null;
        origHttpsProxyPort = null;
        origNonProxyHosts = null;
    }

    private static void setOrClear(String key, String value) {
        if (key == null) return;
        if (value == null || value.trim().isEmpty()) {
            System.clearProperty(key);
        } else {
            System.setProperty(key, value);
        }
    }
}
