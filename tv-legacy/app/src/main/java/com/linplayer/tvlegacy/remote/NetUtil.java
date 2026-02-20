package com.linplayer.tvlegacy.remote;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.List;

final class NetUtil {
    private NetUtil() {}

    static List<String> listIpv4() {
        try {
            Enumeration<NetworkInterface> ifs = NetworkInterface.getNetworkInterfaces();
            if (ifs == null) return Collections.emptyList();
            List<String> out = new ArrayList<>();
            while (ifs.hasMoreElements()) {
                NetworkInterface ni = ifs.nextElement();
                if (ni == null) continue;
                if (!ni.isUp()) continue;
                if (ni.isLoopback()) continue;

                Enumeration<InetAddress> addrs = ni.getInetAddresses();
                while (addrs != null && addrs.hasMoreElements()) {
                    InetAddress a = addrs.nextElement();
                    if (a == null) continue;
                    if (a.isLoopbackAddress()) continue;
                    if (!(a instanceof Inet4Address)) continue;
                    String ip = a.getHostAddress();
                    if (ip == null) continue;
                    ip = ip.trim();
                    if (ip.isEmpty()) continue;
                    if ("0.0.0.0".equals(ip)) continue;
                    out.add(ip);
                }
            }
            return Collections.unmodifiableList(out);
        } catch (Exception e) {
            return Collections.emptyList();
        }
    }
}

