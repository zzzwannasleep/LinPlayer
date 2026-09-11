using System;
using System.Net.NetworkInformation;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 顶栏那一格网速读数。
///
/// <para>用户 2026-09-12:「网速显示要常驻…不需要打开再统计再显示,跟随状态栏显隐就行了」。
/// 所以采样跟着**播放页**活,顶栏只管画不画 —— 不是顶栏出来才开始数。</para>
///
/// <para>口径是**整机**(所有在跑的网卡收到的字节),和安卓端 <c>fmtSpeed</c> 一致:
/// 用户要问的是「现在到底还有没有在下东西」,而播放中封面、弹幕、上报都在跑。</para>
/// </summary>
internal static class NetSpeed
{
    /// <summary>读数格式。量不出来返回空串 —— 那一格整个不画,不摆一个恒为 0 的数。</summary>
    public static string Fmt(long bytes, double seconds)
    {
        if (seconds <= 0 || bytes < 0) return "";
        var bps = bytes / seconds;
        if (bps >= 1024 * 1024) return $"{bps / 1024 / 1024:0.0} MB/s";
        if (bps >= 1024) return $"{bps / 1024:0} KB/s";
        return "0 KB/s";
    }

    /// <summary>整机累计收到的字节。问不到就 -1(不是 0 —— 0 是合法读数)。</summary>
    public static long TotalRx()
    {
        try
        {
            long sum = 0;
            foreach (var n in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (n.OperationalStatus != OperationalStatus.Up) continue;
                if (n.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                sum += n.GetIPStatistics().BytesReceived;
            }
            return sum;
        }
        // 可以静默:有的虚拟网卡问统计会抛。问不到就是不画这一格,不是故障
        catch { return -1; }
    }
}
