/* Ani-RSS 的**纯模型层** —— 不碰 React / DOM / Tauri。

   2026-07-26 从 `ui/desktop/pages/AniRssPage.tsx` 原样搬出来(逻辑一行没改),
   为的是手机端能用同一份。这里面全是"看着简单、错了很难发现"的东西:

   - `parseEpisode` 的五条正则是按字幕组常见约定排的优先级,顺序有意义
   - `scoreMatch` 的 3/2/1 分档决定"这个种子属于哪部番",抄错一档就会
     **把进度标到另一部番上**,而界面看起来完全正常
   - `norm` 要去掉的 token 是一条一条踩出来的

   抄第二份 = 把这些坑复制一遍,而且两份会慢慢长歪。加字段/改判据只改这里。
   页面私有的东西(轮询间隔、右键菜单上下文、每行显示几集)**留在各自的页面里** ——
   那些各端本来就该不一样。 */

import type { Json } from "@shared/api";

/** Ani-RSS 服务端的番剧对象。字段可能全缺,故一律可空由 aniOf 兜底。 */
export type Ani = {
  /** ★ 完整原始 map。setAni/addAni 必须回传完整对象 —— 只传改过的字段会丢字段。 */
  raw: Json;
  /** 服务端 id。可能为空串 —— 空的话增删改refresh 都没法定位,故 UI 上要挡掉(见 canManage)。 */
  id: string;
  /** 列表/映射用的稳定键:id 空时回退 title(核层 flatten_week_list 也是这个去重口径)。 */
  key: string;
  title: string;
  image: string | null;
  enable: boolean;
  currentEpisodeNumber: number | null;
  totalEpisodeNumber: number | null;
  week: number | null;
  season: number | null;
  lastDownloadTime: number | null;
  subgroup: string | null;
  score: number | null;
  // 以下三项只为把下载中的种子关联到订阅(见 scoreMatch),不上屏。
  tags: string[];
  downloadPath: string | null;
  themoviedbName: string | null;
  jpTitle: string | null;
};

export const WEEK = ["一", "二", "三", "四", "五", "六", "日"];
// 长番(百集以上)全渲染会刷出几百个格子拖垮列表,超出部分折成 +N。

export function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

export function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

export function strArr(v: unknown): string[] {
  return Array.isArray(v) ? v.map((e) => String(e)).filter(Boolean) : [];
}

export function aniOf(j: Json): Ani {
  const id = str(j.id) ?? "";
  const title = str(j.title) ?? "未命名";
  return {
    raw: j,
    id,
    key: id || title,
    title,
    image: str(j.image),
    // enable 缺省视为 true:Ani-RSS 只在显式暂停时才写 false。
    enable: j.enable !== false,
    currentEpisodeNumber: num(j.currentEpisodeNumber),
    totalEpisodeNumber: num(j.totalEpisodeNumber),
    week: num(j.week),
    season: num(j.season),
    lastDownloadTime: num(j.lastDownloadTime),
    subgroup: str(j.subgroup),
    score: num(j.score),
    tags: strArr(j.tags),
    downloadPath: str(j.downloadPath),
    themoviedbName: str(j.themoviedbName),
    jpTitle: str(j.jpTitle),
  };
}

/* ---------- 下载中的种子 → 订阅/集号关联 ---------- */
/* /api/torrentsInfos 是 Json 直通(核层不定义 TorrentInfo),字段名与匹配启发式
   照搬旧 Flutter 端 lib/core/sources/anirss/{models/torrent_info,anirss_match}.dart,
   那是对着真服务端调出来的,别凭感觉重写。 */

export type Torrent = {
  name: string;
  progress: number; // 0..1
  state: string;
  tags: string[];
  downloadDir: string | null;
};

export const DOWNLOADING = new Set([
  "downloading",
  "metaDownload",
  "forcedMetaDownload",
  "forcedDL",
  "stalledDL",
  "queuedDL",
]);

export function torrentOf(j: Json): Torrent {
  return {
    name: str(j.name) ?? "",
    progress: Math.min(1, Math.max(0, num(j.progress) ?? 0)),
    state: str(j.state) ?? "",
    tags: strArr(j.tags),
    downloadDir: str(j.downloadDir),
  };
}

/** 归一化:去 [..]/【..】/(..) 块、清晰度/季度 token、所有符号空白,转小写。 */

/** 归一化:去 [..]/【..】/(..) 块、清晰度/季度 token、所有符号空白,转小写。 */
export function norm(s: string): string {
  return s
    .toLowerCase()
    .replace(/[[【(][^\]】)]*[\]】)]/g, " ")
    .replace(/\b(1080p|720p|2160p|4k|x264|x265|hevc|avc|web-?dl|bdrip|baha|cr)\b/g, " ")
    .replace(/\b(s\d{1,2}|season\s*\d{1,2})\b/g, " ")
    .replace(/第[0-9一二三四五六七八九十]+[季部]/g, " ")
    .replace(/[^0-9a-z一-鿿぀-ヿ]/g, "")
    .trim();
}

/** 从种子名解析集号,按字幕组常见约定优先级。 */

/** 从种子名解析集号,按字幕组常见约定优先级。 */
export function parseEpisode(name: string): number | null {
  const pats = [
    /-\s*(\d{1,3}(?:\.5)?)(?=\s|$|\[|\()/, // "- 12"
    /\[\s*(\d{1,3}(?:\.5)?)\s*\]/, // "[12]"
    /(?<![A-Za-z])[Ee][Pp]?\s?(\d{1,3}(?:\.5)?)/, // "E12" / "EP 12"
    /第\s*(\d{1,3}(?:\.5)?)\s*[话話集]/, // "第12话"
    /\s(\d{1,3}(?:\.5)?)\s*(?:v\d)?\s*[[(]/, // " 12 ["
  ];
  for (const p of pats) {
    const m = p.exec(name);
    if (m) {
      const v = Number(m[1]);
      if (Number.isFinite(v)) return v;
    }
  }
  return null;
}

/** (订阅, 种子) 匹配置信分:3=标签 / 2=目录 / 1=标题模糊 / 0=不匹配。 */

/** (订阅, 种子) 匹配置信分:3=标签 / 2=目录 / 1=标题模糊 / 0=不匹配。 */
export function scoreMatch(a: Ani, t: Torrent): number {
  const aniTags = new Set(a.tags.map(norm).filter(Boolean));
  const torTags = t.tags.map(norm).filter(Boolean);
  if (aniTags.size > 0 && torTags.some((x) => aniTags.has(x))) return 3;

  const title = norm(a.title);
  const tmdb = norm(a.themoviedbName ?? "");
  if (torTags.some((tag) => (title && tag.includes(title)) || (tmdb && tag.includes(tmdb)))) {
    return 3;
  }

  const dir = norm(t.downloadDir ?? "");
  if (dir) {
    const dp = norm(a.downloadPath ?? "");
    if ((dp && dir.includes(dp)) || (tmdb && dir.includes(tmdb)) || (title && dir.includes(title))) {
      return 2;
    }
  }

  const name = norm(t.name);
  if (name) {
    const jp = norm(a.jpTitle ?? "");
    if (
      (title.length >= 2 && name.includes(title)) ||
      (jp.length >= 2 && name.includes(jp)) ||
      (tmdb.length >= 2 && name.includes(tmdb))
    ) {
      return 1;
    }
  }
  return 0;
}

/** 某订阅当前正在下的那一集(取进度最高的一条;取不到集号也算,只是没有 E 号)。 */

/** 某订阅当前正在下的那一集(取进度最高的一条;取不到集号也算,只是没有 E 号)。 */
export type Dl = { ep: number | null; pct: number };

/** 种子按最佳订阅归组 —— 一个种子只归一部番,免得同名番互相抢。 */

/** 种子按最佳订阅归组 —— 一个种子只归一部番,免得同名番互相抢。 */
export function matchTorrents(list: Ani[], torrents: Torrent[]): Map<string, Dl> {
  const out = new Map<string, Dl>();
  for (const t of torrents) {
    if (!DOWNLOADING.has(t.state)) continue; // 只关心下载中的,做种/校验的不上屏
    let best: Ani | null = null;
    let bestScore = 0;
    for (const a of list) {
      const s = scoreMatch(a, t);
      if (s > bestScore) {
        bestScore = s;
        best = a;
      }
    }
    if (!best || bestScore === 0) continue; // 匹配不上就不标,不硬塞给某部番
    const cur = out.get(best.key);
    const next = { ep: parseEpisode(t.name), pct: Math.round(t.progress * 100) };
    if (!cur || next.pct > cur.pct) out.set(best.key, next);
  }
  return out;
}

export function fmtDate(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** 状态小字。有真种子进度时给草稿 42 那行「E4 下载中 · 62% · Mikan 源」。 */

/** 状态小字。有真种子进度时给草稿 42 那行「E4 下载中 · 62% · Mikan 源」。 */
export function statusOf(a: Ani, dl: Dl | undefined): string {
  if (!a.enable) return "已暂停订阅";
  if (dl) {
    const head = dl.ep != null ? `E${dl.ep} 下载中` : "下载中";
    const src = a.subgroup ? ` · ${a.subgroup} 源` : "";
    return `${head} · ${dl.pct}%${src}`;
  }
  if (a.week != null && a.week >= 1 && a.week <= 7) {
    const base = `等待更新 · 每周${WEEK[a.week - 1]}`;
    return a.subgroup ? `${base} · ${a.subgroup} 源` : base;
  }
  const last =
    a.lastDownloadTime != null && a.lastDownloadTime > 0
      ? ` · 上次更新 ${fmtDate(a.lastDownloadTime)}`
      : "";
  return `未排期${last}`;
}
