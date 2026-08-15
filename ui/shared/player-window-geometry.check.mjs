/* 播放窗几何 —— 挂**打包好的真 exe** 自检(桌面端)。
 *
 * ## 为什么必须挂真 exe
 * 这两条断言量的是 Win32 窗口矩形,不是 DOM:
 *   1. 播放窗新建出来的尺寸(用户 2026-08-16:「默认尺寸很大,做的像第一次打开软件那么大就行」);
 *   2. 主窗最大化时,播放窗自己的最大化按钮还灵不灵(用户同日:「外面先最大化,里面的就点不动了」)。
 * 前端 headless 那套(player-chrome.check.mjs)连窗口都没有,照不到。
 *
 * ## 跑法
 *   npm run pack:fast   # 先出 dist-portable/LinPlayer/LinPlayer.exe
 *   node ui/shared/player-window-geometry.check.mjs
 *
 * ## 纪律(见 [[test-must-fail-first]])
 * 两条都在**修之前**的 exe 上跑出过红:
 *   · 尺寸:主窗最大化后开播放窗 → 量到 2560x1392(整屏),不是 1180x720;
 *   · 最大化:toggle 前后 outer_rect 一模一样 → 「点了里面的最大化,几何必须变」红。
 * 改回 `.inner_size(main.inner_size())` 就能再复现一次。
 *
 * ## 注意
 * 本机 scale_factor=1 时,"位置单位用错(physical 当 logical)"这类 DPI bug 照不出来 ——
 * 那条只能在缩放 >100% 的机器上量。代码里已按 logical 换算(builder 的 position 是 logical,
 * 而 outer_position() 返回 physical,老代码把两者直接对接了)。
 */
import { spawn, execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const EXE_DIR = join(process.cwd(), "dist-portable", "LinPlayer");
const PORT = 9334;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
if (!existsSync(join(EXE_DIR, "LinPlayer.exe"))) {
  console.error("★ 没有可测的 exe —— 先跑 `npm run pack:fast`");
  process.exit(1);
}

const proc = spawn(join(EXE_DIR, "LinPlayer.exe"), [], {
  cwd: EXE_DIR,
  env: { ...process.env, WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${PORT}` },
  stdio: "ignore",
});
const die = () => {
  proc.kill();
  try { execFileSync("taskkill", ["/F", "/IM", "LinPlayer.exe"], { stdio: "ignore" }); } catch {}
};

const targets = async () => {
  try { return await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json(); } catch { return []; }
};
function connect(url) {
  const ws = new WebSocket(url);
  const pend = new Map();
  let id = 0;
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pend.has(m.id)) (pend.get(m.id)(m), pend.delete(m.id));
  };
  const ready = new Promise((r) => (ws.onopen = r));
  const cmd = (method, params = {}) =>
    new Promise((r) => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  return {
    ready,
    ev: async (expr) => {
      const r = await cmd("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
      if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 300));
      return r.result?.result?.value;
    },
  };
}


/* mpv 的视频窗是**独立顶层窗口**(类 lpvid),CDP 看不见它,只能从进程外用 Win32 量。
   最大化是条新的几何路径:视频窗跟不上 = 用户见过的那种"全屏一圈白边"
   (见 [[fullscreen-white-edge-geometry]])。

   ★ 第一行的 SetProcessDpiAwarenessContext(-4) 不能删:PS 进程默认 DPI-unaware,
     那样 GetWindowRect 返回的是**虚拟化后的逻辑坐标**(150% 缩放下量到 1707 = 2560/1.5),
     和 Tauri 那边的物理像素对不上,看着就像"视频窗没跟上"——
     见 [[windows-maximize-overhang]] 里同一个坑。
   ★ PS 脚本体内一个非 ASCII 字符都别放,见 [[powershell-gbk-utf8-corruption]]。 */
const PS = `
Add-Type @"
using System;using System.Runtime.InteropServices;using System.Text;
public class W{
  public delegate bool Cb(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(Cb cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [StructLayout(LayoutKind.Sequential)] public struct RECT{public int L,T,R,B;}
}
"@
try { [void][W]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {}
$out = @()
$cb = [W+Cb]{ param($h,$l)
  $sb = New-Object System.Text.StringBuilder 64
  [void][W]::GetClassName($h, $sb, 64)
  if ($sb.ToString() -eq 'lpvid') {
    $r = New-Object W+RECT
    [void][W]::GetWindowRect($h, [ref]$r)
    $script:out += [pscustomobject]@{ x=$r.L; y=$r.T; w=($r.R-$r.L); h=($r.B-$r.T) }
  }
  return $true
}
[void][W]::EnumWindows($cb, [IntPtr]::Zero)
$out | ConvertTo-Json -Compress
`;
const videoRect = () => {
  const s = execFileSync("powershell", ["-NoProfile", "-Command", PS], { encoding: "utf8" }).trim();
  if (!s) return null;
  const j = JSON.parse(s);
  return Array.isArray(j) ? j[0] : j;
};

let mainT;
for (let i = 0; i < 120 && !mainT; i++) {
  mainT = (await targets()).find((t) => t.type === "page" && !t.url.includes("#player"));
  if (!mainT) await sleep(500);
}
if (!mainT) { die(); throw new Error("连不上主窗 CDP"); }
const m = connect(mainT.webSocketDebuggerUrl);
await m.ready;
await sleep(2000); // 等前端起来

const inv = (c, a = {}) => `__TAURI_INTERNALS__.invoke(${JSON.stringify(c)}, ${JSON.stringify(a)})`;
const win = (label, c, a = {}) => m.ev(inv(`plugin:window|${c}`, { label, ...a }));
/** 一个窗口的完整几何(物理像素)+ 缩放,量什么都从这儿取。 */
const geo = async (label) => {
  const [p, s, ip, is, sf, mx, fs] = await Promise.all([
    win(label, "outer_position"), win(label, "outer_size"),
    win(label, "inner_position"), win(label, "inner_size"),
    win(label, "scale_factor"), win(label, "is_maximized"), win(label, "is_fullscreen"),
  ]);
  /* 外框 vs 客户区:无边框窗在 Windows 上外框每边还宽出一圈隐形缩放边(150% 下 11px),
     "多大"要量客户区,别量外框。 */
  return { x: p.x, y: p.y, w: s.width, h: s.height, sf, maxed: mx, fs,
           ix: ip.x, iy: ip.y, iw: is.width, ih: is.height,
           lw: Math.round(is.width / sf), lh: Math.round(is.height / sf) };
};
const rect = (g) => `外框 ${g.x},${g.y} ${g.w}x${g.h} / 客户区 ${g.ix},${g.iy} ${g.iw}x${g.ih}(逻辑 ${g.lw}x${g.lh})`;
/** 可见区域的中心点 —— 居中要按它算,按外框算会差一个边框宽。 */
const c = (g) => [g.ix + g.iw / 2, g.iy + g.ih / 2];

const fails = [];
const ok = (cond, msg, extra = "") => {
  console.log(`${cond ? "OK " : "FAIL"} ${msg}${extra ? "  " + extra : ""}`);
  if (!cond) fails.push(msg);
};

try {
  // 1) 把主窗最大化 —— 这就是用户复现路径的第一步「点外面这个框的最大化」
  if (!(await win("main", "is_maximized"))) await win("main", "toggle_maximize");
  await sleep(600);
  const mainG = await geo("main");
  ok(mainG.maxed, "主窗已最大化(复现前提)", rect(mainG));

  // 2) 开播放窗。条目是假的,起播会失败 —— 无所谓,这里只量窗口几何。
  await m.ev(inv("player_window_open", {
    payload: { kind: "source", entry: { id: "__probe__", name: "几何自检", is_dir: false, is_video: true, size: null, thumb_url: null, raw: null } },
  }));
  let pt;
  for (let i = 0; i < 40 && !pt; i++) {
    pt = (await targets()).find((t) => t.type === "page" && t.url.includes("#player"));
    if (!pt) await sleep(500);
  }
  ok(!!pt, "播放窗打开了");
  if (!pt) throw new Error("播放窗没起来");
  await sleep(800);

  // 3) ★ 尺寸:固定 1180x720(= 首次打开软件那么大),不跟主窗当前尺寸走
  const p0 = await geo("player");
  ok(p0.lw === 1180 && p0.lh === 720,
     "播放窗新建尺寸 = 主窗首开尺寸 1180x720(不照抄最大化后的主窗)", rect(p0));
  ok(!p0.maxed, "播放窗不是最大化态(全屏由用户自己按)");
  // 居中在主窗上(容差放到 24px:无边框窗上下边框不对称,视觉上看不出来)
  const [cx0, cy0] = c(p0), [mx0, my0] = c(mainG);
  ok(Math.abs(cx0 - mx0) < 24 && Math.abs(cy0 - my0) < 24,
     "播放窗居中在主窗上", `播放窗中心 ${Math.round(cx0)},${Math.round(cy0)} / 主窗中心 ${mx0},${my0}`);

  // 4) ★ 主窗还最大化着,点播放窗里面的最大化 —— 几何必须真的变
  await win("player", "toggle_maximize");
  await sleep(700);
  const p1 = await geo("player");
  ok(p1.maxed, "播放窗窗口态 = 最大化", rect(p1));
  /* ★ 判据是"变大了一大截",不是"矩形变了一点点"。老代码里播放窗一建出来就是
     2586x1626(整块屏幕),点最大化只从 2586x1626 挪到 2582x1622 —— 矩形确实变了,
     可用户看到的就是"按了没反应"。用面积比才钉得住这个症状。 */
  const area = (g) => g.iw * g.ih;
  ok(area(p1) > area(p0) * 1.3,
     "点了播放窗里的最大化,窗口真的变大了(用户报的「点不动」就是这条)",
     `${p0.iw}x${p0.ih} → ${p1.iw}x${p1.ih}`);
  ok(p1.x === mainG.x && p1.y === mainG.y && p1.w === mainG.w && p1.h === mainG.h,
     "播放窗最大化后的矩形和主窗最大化一致(没有多出/少掉溢出边)", `播放窗 ${rect(p1)} vs 主窗 ${rect(mainG)}`);

  // 5) 视频窗(mpv 那块独立顶层窗)必须跟着最大化走,不然全屏一圈白边
  const v = videoRect();
  const inset = v ? v.y - p1.iy : -1;
  ok(v && v.x === p1.ix && v.w === p1.iw && inset > 40 && inset < 70 && v.h === p1.ih - inset,
     "视频窗跟上了播放窗的最大化(顶部让出 36 逻辑px 标题栏)",
     `视频窗 ${JSON.stringify(v)} / 让位 ${inset}px`);

  /* 6) ★ 最大化态下切全屏。

     Windows 的硬规矩:**最大化着直接切全屏是不生效的** —— is_fullscreen 翻成 true,
     窗口客户区一个像素都不动(这里量过:2560x1599 → 2560x1599),于是标题栏还在、
     画面还让着 36px,用户看到的就是"全屏按钮无效"(2026-08-16 报的)。
     App.tsx 的 applyFullscreen 因此**先 unmaximize 再全屏**,这里量的就是那两步。
     ★ 为什么不点真按钮:那个按钮只在播放中才渲染,这条自检不起真片(起一次要几十秒
       还要网络)。"前端确实走 applyFullscreen"由 Rust 侧的
       fullscreen_never_starts_from_a_maximized_window 钉,两边合起来才是完整的。 */
  await win("player", "unmaximize");
  await win("player", "set_fullscreen", { value: true });
  await sleep(1200);
  const pf = await geo("player");
  ok(pf.fs, "窗口态 = 全屏");
  ok(!pf.maxed && pf.ih > p1.ih,
     "先退最大化再全屏,窗口真的铺满整块屏(让给标题栏的那 36px 收回来了)",
     `${p1.iw}x${p1.ih}(最大化) → ${pf.iw}x${pf.ih}(全屏)`);
  const vf = videoRect();
  ok(vf && vf.y === pf.iy && vf.h === pf.ih,
     "全屏下视频窗不再给标题栏让位(否则上面一条黑边)", JSON.stringify(vf));
  // 退出全屏要回到最大化,不能掉回 1180x720 的小窗(applyFullscreen 记着进来前的态)
  await win("player", "set_fullscreen", { value: false });
  await win("player", "maximize");
  await sleep(1200);
  const pu = await geo("player");
  ok(!pu.fs && pu.maxed && pu.iw === p1.iw && pu.ih === p1.ih, "退出全屏回到最大化", rect(pu));

  // 7) 还原也得灵
  await win("player", "toggle_maximize");
  await sleep(700);
  const p2 = await geo("player");
  ok(!p2.maxed && p2.lw === 1180 && p2.lh === 720, "再点一次还原回 1180x720", rect(p2));
} finally {
  die();
}
console.log(fails.length ? `\n★ ${fails.length} 条不过:${fails.join(" | ")}` : "\n全过");
process.exit(fails.length ? 1 : 0);
