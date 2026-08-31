# 给 LinPlayer 主窗口截图。**真机自检用** —— 「编译过了」不是交付。
#
# ★ 必须先 SetProcessDPIAware:PowerShell 默认是 DPI 不感知的,
#   而被截的窗口是 PerMonitorV2 —— 两边坐标系不同,截出来会整体错位
#   (第一次就是这样:窗口内容往右偏了一百多像素,看起来像布局有 bug)。
param(
  [string]$ProcName = "LinPlayer",
  [string]$Out = "shot.png"
)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;using System.Runtime.InteropServices;
public class Shot {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
  public struct RECT { public int L,T,R,B; }
}
"@
[void][Shot]::SetProcessDPIAware()
$p = Get-Process -Name $ProcName -ErrorAction SilentlyContinue |
     Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output "没有找到 $ProcName 的窗口"; exit 1 }
[void][Shot]::SetForegroundWindow($p.MainWindowHandle)
Start-Sleep -Milliseconds 700
$r = New-Object Shot+RECT
# DWMWA_EXTENDED_FRAME_BOUNDS = 9:拿真实可见边界,GetWindowRect 会多带阴影边
if ([Shot]::DwmGetWindowAttribute($p.MainWindowHandle, 9, [ref]$r, 16) -ne 0) {
  [void][Shot]::GetWindowRect($p.MainWindowHandle, [ref]$r)
}
$w = $r.R - $r.L; $h = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output "$Out  ${w}x${h}"
