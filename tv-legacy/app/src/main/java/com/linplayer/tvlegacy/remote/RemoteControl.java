package com.linplayer.tvlegacy.remote;

import android.content.Context;
import com.linplayer.tvlegacy.AppPrefs;
import java.util.List;
import java.util.Random;

public final class RemoteControl {
    private static final Object LOCK = new Object();
    private static RemoteHttpServer server;

    private RemoteControl() {}

    public static RemoteInfo ensureStarted(Context context) {
        if (context == null) return new RemoteInfo(0, "", java.util.Collections.emptyList());
        Context appContext = context.getApplicationContext();
        synchronized (LOCK) {
            if (server == null) {
                server = new RemoteHttpServer(appContext);
            }
            if (!server.isRunning()) {
                String token = AppPrefs.getRemoteToken(appContext);
                if (token == null || token.trim().isEmpty()) {
                    token = randomToken(10);
                    AppPrefs.setRemoteToken(appContext, token);
                }
                int preferredPort = AppPrefs.getRemotePort(appContext);
                server.start(token, preferredPort);
                AppPrefs.setRemotePort(appContext, server.getPort());
            }
            List<String> ips = NetUtil.listIpv4();
            return new RemoteInfo(server.getPort(), server.getToken(), ips);
        }
    }

    public static void stop() {
        synchronized (LOCK) {
            if (server != null) {
                server.stop();
                server = null;
            }
        }
    }

    private static String randomToken(int len) {
        String chars = "abcdefghijklmnopqrstuvwxyz0123456789";
        Random r = new Random();
        StringBuilder sb = new StringBuilder(len);
        for (int i = 0; i < len; i++) {
            sb.append(chars.charAt(r.nextInt(chars.length())));
        }
        return sb.toString();
    }
}

