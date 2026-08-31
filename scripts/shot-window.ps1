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
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
  public struct RECT { public int L,T,R,B; }
}
"@
[void][Shot]::SetProcessDPIAware()
$p = Get-Process -Name $ProcName -ErrorAction SilentlyContinue |
     Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output "没有找到 $ProcName 的窗口"; exit 1 }
# ★★ 截图是 CopyFromScreen —— 抓的是**屏幕那块区域**,不是窗口自身内容。
#   窗口被别的程序压住时,截出来的是压在上面那个窗口,而脚本照样报「成功」。
#   2026-08-31 真栽过:截到了另一个程序的界面,差点当成 LinPlayer 的界面来读。
#
# ★ 判据是「屏幕上那个位置显示的到底是谁」(WindowFromPoint),**不是「谁是前台」**。
#   一开始写成前台判定,结果自检窗口置顶(Topmost)时 z 序明明在最上、
#   内容也截得对,却因为前台是别的程序被判失败 —— 判据选错了。
$hwnd = $p.MainWindowHandle
$GA_ROOT = 2
function Get-Center([Shot+RECT]$rc) {
  $pt = New-Object Shot+POINT
  $pt.X = [int](($rc.L + $rc.R) / 2); $pt.Y = [int](($rc.T + $rc.B) / 2)
  return $pt
}
function Test-Visible {
  $probe = New-Object Shot+RECT
  if ([Shot]::DwmGetWindowAttribute($hwnd, 9, [ref]$probe, 16) -ne 0) {
    [void][Shot]::GetWindowRect($hwnd, [ref]$probe)
  }
  $top = [Shot]::WindowFromPoint((Get-Center $probe))
  if ($top -eq [IntPtr]::Zero) { return $false }
  return ([Shot]::GetAncestor($top, $GA_ROOT) -eq $hwnd)
}
for ($i = 0; $i -lt 5; $i++) {
  if (Test-Visible) { break }
  [void][Shot]::ShowWindow($hwnd, 9)          # SW_RESTORE:最小化时先还原
  [void][Shot]::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds 500
}
if (-not (Test-Visible)) {
  Write-Output "!! $ProcName 的窗口被别的程序遮住了,截出来会是别人的界面,已中止"
  exit 2
}
Start-Sleep -Milliseconds 300
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
