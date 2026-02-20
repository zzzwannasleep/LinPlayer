package com.linplayer.tvlegacy.remote;

import java.util.List;

public final class RemoteInfo {
    public final int port;
    public final String token;
    public final List<String> ipv4;

    RemoteInfo(int port, String token, List<String> ipv4) {
        this.port = port;
        this.token = token != null ? token : "";
        this.ipv4 = ipv4;
    }

    public String firstRemoteUrl() {
        if (port <= 0) return "";
        if (token.trim().isEmpty()) return "";
        if (ipv4 == null || ipv4.isEmpty()) return "";
        String ip = ipv4.get(0);
        if (ip == null || ip.trim().isEmpty()) return "";
        return "http://" + ip.trim() + ":" + port + "/?token=" + token.trim();
    }
}

