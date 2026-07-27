import { convertFileSrc, invoke as rawInvoke } from "@tauri-apps/api/core";

/* ============================================================
   Tauri 命令类型化封装 —— 前端调 Rust 核的唯一入口。
   所有页面走这里，不散落裸 invoke，改一处全端生效。
   Rust snake_case 参数 → JS camelCase(Tauri 自动转)。
   ============================================================ */

/** 账号表变了的广播事件名。用 window 原生 CustomEvent —— 全应用没有任何 store/事件总线,
 *  为这一件事装 zustand/redux 不值当;`accountsChanged` 订阅它即可。 */
export const ACCOUNTS_CHANGED = "lp:accounts-changed";

/* 会改动核层账号表的命令。**真源在 Rust,前端每个页面各持一份 useState 副本** ——
   副本之间没有任何连接,谁也不知道别人改了。

   ★ 为什么在 invoke 这层拦、而不是各调用点自己吼一嗓子:
     「改完记得通知别人」是靠人记的,而这正是 2026-07-15 那个 bug 的成因 ——
     ServersPage 改名称/备注/图标/密码走的是 onDone(false),压根不通知外层,
     侧栏于是永远显示旧名字。**让「改数据」这个动作本身成为信号,谁都忘不掉。**
   新增会改账号表的命令时把名字加进来(漏加 = 侧栏又不刷新,且不报错)。 */
const ACCOUNT_MUTATIONS = new Set([
  "login",
  "relogin",
  "update_account",
  "remove_account",
  "reorder_accounts",
  "set_active_server",
  "set_account_icon_file",
  "clear_account_icon",
  "set_lines",
  "set_active_line",
  "sync_lines",
  "batch_add_servers",
  "source_login", // 添加网盘/聚合源 —— 它也 upsert 账号表(第一版我写成了不存在的 add_source_server)
]);

/** 统一入口:命令成功后,若它动过账号表就广播一次;动过条目状态就清详情缓存。
 *  **失败不广播、不清** —— 没改成的东西没什么可刷的。 */
async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  const r = await rawInvoke<T>(cmd, args);
  if (ACCOUNT_MUTATIONS.has(cmd)) {
    /* 切服/重登/换线路后,详情缓存里全是**上一台服务器**的条目 —— 条目 id 在不同服上
       可以重复,不清就会拿 A 服的详情去画 B 服的条目,而且不报错。 */
    clearItemCache();
    window.dispatchEvent(new CustomEvent(ACCOUNTS_CHANGED));
  }
  if (ITEM_MUTATIONS.has(cmd)) clearItemCache();
  return r;
}

/** 订阅账号表变更。返回退订函数,直接丢给 useEffect 的 cleanup。 */
export function onAccountsChanged(fn: () => void): () => void {
  window.addEventListener(ACCOUNTS_CHANGED, fn);
  return () => window.removeEventListener(ACCOUNTS_CHANGED, fn);
}

export type LoginResult = {
  server: string;
  token: string;
  user_id: string;
  user_name: string;
};

export type Item = {
  id: string;
  name: string;
  type_: string;
  is_folder: boolean;
  has_primary: boolean;
  runtime_secs: number;
  resume_secs: number;
  /** 剧集所属剧名(Episode.Name 只是「第 35 集」,混排列表靠它认剧)。 */
  series_name: string | null;
  episode_no: number | null;
  season_no: number | null;
  /** 以下三项仅分集列表(带 Fields=MediaSources)有值,用于卡片那行「2160p · 45M · 18.4G」。 */
  video_height: number | null;
  bitrate: number | null;
  size_bytes: number | null;
  /* 以下字段核层 emby::Item 一直在传,只是这份类型漏了 —— 漏了它们,
     海报评分角标/已看反显/本地排序就会被误判成「服务端不透传」。别再删。 */
  /** 已看(UserData.Played)。setPlayed 的反显靠它。 */
  played: boolean;
  /** 未看子项数(剧集/季才 >0,电影/单集恒 0)。海报「未看集数」蓝角标用它;
   *  played=true 时必为 0 → 前端:有勾优先、否则显数字。核层 emby::Item 已透传。 */
  unplayed_item_count: number;
  genres: string[];
  year: number | null;
  rating: number | null;
  provider_ids: Record<string, string>;
  presentation_unique_key: string | null;
  path: string | null;
  series_id: string | null;
  /** 「更新时间」排序用(DateLastMediaAdded ?? DateCreated)。ISO 字符串,同服格式一致可直接比大小。 */
  date_updated: string | null;
  /** Emby 的 SortName,按名称排序优先用它。 */
  sort_name: string | null;
};

export type Person = {
  id: string;
  name: string;
  role: string | null;
  /** Director / Actor / Writer / Producer … */
  type_: string;
  has_primary: boolean;
};

export type StreamInfo = {
  index: number;
  type_: "Video" | "Audio" | "Subtitle";
  codec: string;
  profile: string | null;
  display_title: string | null;
  language: string | null;
  width: number | null;
  height: number | null;
  bitrate: number | null;
  channels: number | null;
  channel_layout: string | null;
  frame_rate: number | null;
  video_range: string | null;
  /** Emby 的 VideoRangeType(新版直接给 `DOVI`/`HDR10`/`SDR` 的结论)。
   *  核层 `is_dolby_vision` 的第一判据就是它 —— 这里原先漏了这一行,
   *  于是前端拿到的 StreamInfo 上**没有这个字段**(TS 侧压根看不见,不报错)。 */
  video_range_type: string | null;
  is_default: boolean;
  /** 外挂字幕(服务器上的独立 .ass/.srt 文件)。核层起播时用 sub-add 挂载,
   *  它**不会**出现在 mpv 的 track-list 里 —— 除非挂上了。 */
  is_external: boolean;
  delivery_url: string | null;
};

export type MediaVersion = {
  id: string;
  name: string;
  container: string | null;
  size_bytes: number | null;
  bitrate: number | null;
  runtime_secs: number;
  streams: StreamInfo[];
};

/** 列表卡片标题:剧集补上剧名。
    ★ 用户 2026-07-16「继续观看名称写具体的季度和集数,样式 SxxExx」:
      季+集都有 → 「剧名 · S1E5」;缺季号(部分番剧)→ 回落到集名(「第 35 集」),
      单看集名不知哪部,所以剧名恒在前。 */
export function itemLabel(it: Item): string {
  if (it.type_ === "Episode" && it.series_name) {
    const se =
      it.season_no != null && it.episode_no != null
        ? `S${it.season_no}E${it.episode_no}`
        : it.name;
    return `${it.series_name} · ${se}`;
  }
  return it.name;
}

export type ItemDetail = {
  id: string;
  name: string;
  type_: string;
  overview: string;
  year: number | null;
  genres: string[];
  rating: number | null;
  runtime_secs: number;
  resume_secs: number;
  has_primary: boolean;
  has_backdrop: boolean;
  is_favorite: boolean;
  series_name: string | null;
  series_id: string | null;
  season_no: number | null;
  episode_no: number | null;
  children: Item[];
  people: Person[];
};

export type Status = {
  time: number;
  duration: number;
  paused: boolean;
  buffered: number;
  /** 本片已正常播放到结尾(mpv keep-open=yes,画面停最后一帧、时间不再走)。
   *  ★ 播放器页必须监听它:不监听 = 看完不退出 = stop_playback 永远不触发 =
   *  Trakt/Bangumi 的「看完」一次都不会上报(用户报的正是这个)。 */
  eof: boolean;
  /** mpv 在这一次 seek 上已经卡了 12s 以上。
   *  ★ 真实成因是**服务器不认 HTTP Range**(宣称 Accept-Ranges,却对 Range 请求回
   *  200 + 整个文件),ffmpeg 只能从当前位置顺读丢弃到目标 —— 跳 9 分钟就是几百 MB。
   *  播放器无能为力,但必须**说出来**,否则用户只看到进度条和画面一起钉死。
   *  可选:各端还有几处"播放器没起来"的空状态字面量。 */
  seek_stalled?: boolean;
  /** 画面这条链的实况。**给"有声音没画面"用** —— 播放页据此把具体断在哪一环
   *  说出来,而不是让用户对着一块黑屏猜(2026-07-21 真栽过一轮)。
   *  可选是因为各端还有几处"空状态"字面量(播放器没起来时的占位),它们没有诊断可言;
   *  核层返回的 Status **一定**带这个字段。 */
  video?: VideoDiag;
};

export type VideoDiag = {
  /** 实际生效的 vo;空 = 视频输出根本没起来。 */
  vo: string;
  width: number;
  height: number;
  /** 当前文件有没有视频轨。false 且黑屏 = 纯音频,正常。 */
  has_video_track: boolean;
  /** 实际生效的硬解;空 = 退回软解。 */
  hwdec: string;
};

/** 说人话的画面故障描述;null = 没毛病(或本来就是纯音频)。
 *  ★ 与 crates/mpv 的 `VideoDiag::problem()` 同一套判据 —— 那边给核层日志用,
 *    这边给界面用。改判据时两边一起改。 */
export function videoProblem(v: VideoDiag | undefined): string | null {
  if (!v || !v.has_video_track) return null;
  if (!v.vo)
    return `有视频轨,但视频输出没起来(hwdec=${v.hwdec || "无"})。多半是渲染面没接上或 GPU 上下文初始化失败。`;
  if (v.width <= 0 || v.height <= 0)
    return `视频输出(${v.vo})起来了,但解不出画面尺寸 —— 解码器没吐帧。`;
  return null;
}

export type Track = {
  kind: string;
  id: string;
  title: string;
  lang: string;
  selected: boolean;
  /** 编码(mpv track-list/N/codec)。正则筛选匹配它,见 /wiki/regex-filters。 */
  codec: string;
  /** 声道数,0 = 未知/非音轨。正则里写 `6ch` 匹配。 */
  channels: number;
};

export type Prefs = {
  audio_lang: string | null;
  sub_lang: string | null;
  sub_enabled: boolean;
  /* 正则优先选择(/wiki/regex-filters)。空 = 不启用,回退语言偏好。 */
  version_regex: string;
  sub_regex: string;
  audio_regex: string;
  /** 详情页背景图模糊强度 0~100(0=清晰,100=糊成色块)。外观设置里调。 */
  detail_blur: number;
};

/** 保存详情页背景模糊强度。单独命令:setPrefs 只覆盖选轨三项,别混。 */
export const setDetailBlur = (value: number) =>
  invoke<void>("set_detail_blur", { value });

export type SourceEntry = {
  id: string;
  name: string;
  is_dir: boolean;
  is_video: boolean;
  size: number | null;
  thumb_url: string | null;
  raw?: unknown;
};

export type ServerGroup = {
  server_id: string;
  server_name: string;
  items: Item[];
};

export type ServerLine = {
  id: string;
  name: string;
  url: string;
  remark: string | null;
};

/** 源类型。**线上格式是全小写裸字符串**(核层 `SourceKind` 是 serde(transparent) 的
 *  newtype;在它还是 enum 的年代也是 rename_all="lowercase")。
 *
 *  ★ 这里曾经写成首字母大写的 "Emby" | "Openlist" | …,于是**每一处比较都恒为 false**、
 *  每一次 sourceLogin 都送出一个后端不认识的 kind —— 而两边都不报错:
 *  徽标显示成空、Ani-RSS 卡点进去落到网盘页、OpenList 登录静默失败。
 *  Rust 侧 `source_kind_wire_strings_match_the_frontend_union` 现在钉着这个联合。
 *
 *  插件贡献的源是 `plugin:<插件id>/<源id>`,不在这个闭集合里 —— 所以是开放联合,
 *  别改回 `Record<SourceKind, …>` 那种要求穷举的写法。 */
export type SourceKind =
  | "emby"
  | "openlist"
  | "quark"
  | "anirss"
  | "feiniu"
  | "stremio"
  | "aliyundrive"
  | "baidu"
  | "pan115"
  | "pan189"
  | "pan139"
  | (string & {});

/** 连通状态三态。unknown = 还没探过(按灰显示),与 down「探过确实不通」同色不同义。 */
export type AccountStatus = "ok" | "reauth" | "down" | "unknown";

export type AccountInfo = {
  server: string;
  user_name: string;
  user_id: string;
  /** 是否当前选中。**不是**连通状态 —— 状态看 status。 */
  active: boolean;
  /** 需先调 probeAccounts 刷新,否则恒为 unknown。 */
  status: AccountStatus;
  /** 显示名(用户起的名,空则回落 host)。 */
  name: string;
  remark: string | null;
  icon_url: string | null;
  lines: ServerLine[];
  active_line: number;
  /** 当前生效的上游线路(未经 CF 反代改写)。 */
  line_url: string;
  allow_insecure_tls: boolean;
  source_kind: SourceKind;
  /** 文件浏览型源(非 Emby)——据此决定进媒体库还是进文件浏览。 */
  is_file_browse: boolean;
};

export type LineProbe = {
  index: number;
  url: string;
  /** null = 该线路探测失败。 */
  ms: number | null;
};

export type ServerInfo = { name: string; version: string; id: string };

export type Filters = {
  genres: string[];
  tags: string[];
  years: number[];
  studios: string[];
  official_ratings: string[];
};

export type ItemPage = { items: Item[]; total: number };

export type DownloadStatus =
  | "Queued"
  | "Downloading"
  | "Paused"
  | "Completed"
  | "Failed"
  | "Canceled";

export type DownloadItem = {
  id: string;
  item_id: string;
  type: string;
  title: string;
  series_id: string | null;
  series_name: string | null;
  season_number: number | null;
  episode_number: number | null;
  poster_url: string | null;
  container: string;
  file_path: string;
  total_bytes: number;
  received_bytes: number;
  progress: number; // 0..1
  status: DownloadStatus;
  error: string | null;
  added_at: number;
};

export type RankingCategory = {
  id: string;
  group: "anime" | "movie" | "tv";
  source: "dandan" | "tmdb";
  label: string;
};

export type RankingEntry = {
  source: "dandan" | "tmdb";
  id: string;
  title: string;
  rank: number;
  image_url: string | null;
  rating: number | null;
  subtitle: string | null;
  is_favorited: boolean;
  media_type: string | null;
};

export type ProxyConfig = {
  type: string; // none | http | https | socks5 | socks4
  host: string;
  port: number;
  username: string;
  password: string;
  proxy_media: boolean;
};

export type DanmakuServer = {
  /** 稳定 id(增删改的身份键)。留空由核层用 api_url 补。 */
  id: string;
  /** 显示名;空则回落 host。 */
  name: string;
  api_url: string;
  auth_type: string; // none | pathToken | headerToken | queryToken
  token: string;
  enabled: boolean;
  /** 越小越先用。 */
  priority: number;
};

export type DanmakuEpisode = {
  episode_id: string;
  episode_title: string;
  episode_number: string | null;
};

export type DanmakuAnime = {
  anime_id: string;
  anime_title: string;
  type_: string | null;
  type_description: string | null;
  image_url: string | null;
  year: number | null;
  episode_count: number | null;
  episodes: DanmakuEpisode[];
};

/** 一源一组:单源失败只填 error,不拖累别的源。 */
export type DanmakuSourceGroup = {
  source_id: string;
  source_name: string;
  animes: DanmakuAnime[];
  matches: unknown[];
  error: string | null;
};

export type DanmakuMatchCandidate = {
  source_id: string;
  source_name: string;
  anime_id: string;
  anime_title: string;
  episode_id: string;
  episode_title: string;
  /** 越大越可信;与 danmakuMinAutoScore() 比较决定自动挂还是让用户挑。 */
  score: number;
};

export type DanmakuMatchInput = {
  /** 剧集用 seriesName,否则条目名。 */
  title: string;
  episode_no?: number | null;
  file_name?: string;
  file_hash?: string | null;
  file_size?: number | null;
  duration_secs?: number | null;
};

export type DanmakuFilterOptions = {
  blockwords: string[];
  user_blocklist: string[];
  /** 屏蔽类型(1=滚动 4=底 5=顶);空=不过滤。 */
  blocked_modes: number[];
  dedup: boolean;
  dedup_window: number;
};

export type SyncAccount = {
  service: string;
  access_token: string;
  refresh_token: string | null;
  expires_at: number | null;
  username: string | null;
};

export type TraktDeviceCode = {
  device_code: string;
  user_code: string;
  verification_url: string;
  expires_in: number;
  interval: number;
};

export type TraktPollResult = {
  account: SyncAccount | null;
  status: string; // pending | authorized | ...
};

// ---------- Emby ----------
export const currentSession = () =>
  invoke<LoginResult | null>("current_session");

/** 当前活跃的**文件浏览型**源(夸克/OpenList/飞牛/Ani-RSS/Stremio/插件源)。
 *
 *  ★ 必须和 currentSession 一起看:`current_session` 在核层是
 *    `.filter(|a| !a.is_file_browse())` —— 只连了网盘的用户在那边**永远返回 null**。
 *    宿主只判 session 的话,这类用户加完源仍被挡在登录页外,加一次挡一次。
 *    这个命令 2026-07 就在核层了,前端一直没接(见 [[stale-waijie-lies]])。 */
export const currentSource = () =>
  invoke<AccountInfo | null>("current_source");

/** 重新登录:**不用填地址**,核层拿账号当前生效的那条线路去认证,只换 token/账号。
 *  名称/备注/图标/线路/生效线路一律不动。
 *  ★ 不要用 login() 代替:login 按「登录时用的地址」upsert,而这里认证走的是线路地址
 *    (≠ 账号主键),会凭空多出一台服务器。 */
export const relogin = (serverId: string, username: string, password: string) =>
  invoke<void>("relogin", { serverId, username, password });

export const login = (server: string, username: string, password: string) =>
  invoke<LoginResult>("login", { server, username, password });

/** 媒体库列表。几乎不变,走缓存 —— 首页/媒体库/侧栏三处都要它,每次 mount 各打一遍太亏。 */
export const views = () => memo("views", () => invoke<Item[]>("views"));

export const listItems = (parentId: string) =>
  invoke<Item[]>("list_items", { parentId });

/** 分页+服务端排序+服务端筛选(要总数/翻页/筛选一律走它,别用 listItems 全量拉)。 */
export const listItemsPage = (
  parentId: string,
  o: {
    startIndex?: number;
    limit?: number;
    sortBy?: string;
    sortOrder?: string;
    genres?: string[];
    tags?: string[];
    years?: number[];
    studios?: string[];
    ratingMin?: number;
    ratingMax?: number;
  } = {},
) =>
  invoke<ItemPage>("list_items_page", {
    parentId,
    startIndex: o.startIndex ?? null,
    limit: o.limit ?? null,
    sortBy: o.sortBy ?? null,
    sortOrder: o.sortOrder ?? null,
    genres: o.genres ?? null,
    tags: o.tags ?? null,
    years: o.years ?? null,
    studios: o.studios ?? null,
    ratingMin: o.ratingMin ?? null,
    ratingMax: o.ratingMax ?? null,
  });

/** 某库的真实筛选分面(类型/标签/年份/工作室/分级)—— 不是从已加载条目里猜。 */
export const getFilters = (parentId: string) =>
  invoke<Filters>("get_filters", { parentId });

/** 服务端搜索(带类型过滤+条数上限)。别再用「拉全库再本地 includes」代替。 */
export const search = (query: string, types?: string[], limit?: number) =>
  invoke<Item[]>("search", { query, types: types ?? null, limit: limit ?? null });

export const listCollections = () =>
  memo("collections", () => invoke<Item[]>("list_collections"));
export const listNextUp = (limit = 20) =>
  memo(`nextUp:${limit}`, () => invoke<Item[]>("list_next_up", { limit }));

/** 标记已看/未看。played=false 亦即「移出继续观看」。 */
export const setPlayed = (itemId: string, played: boolean) =>
  invoke<void>("set_played", { itemId, played });

export const listLatest = (parentId: string, limit = 20) =>
  memo(`latest:${parentId}:${limit}`, () => invoke<Item[]>("list_latest", { parentId, limit }));

export const listResume = (limit = 20) =>
  memo(`resume:${limit}`, () => invoke<Item[]>("list_resume", { limit }));

/* ---------- 条目详情缓存 ----------
   用户 2026-07-15:「简介……每次都要重新加载,服务器压力很大」。
   此前 DetailPage 每次 mount 都 `setD(null)` + 全量重拉,来回翻两个条目 = 每次都回源,
   而且先清空必然闪一下白。

   ## 为什么是**内存** TTL,不是磁盘持久化
   用户说的是「持久化缓存」,但**图片和元数据不该一个待遇**:
   - 图片按 tag 基本不可变 → 落盘 2GB/30 天(见 core 的 image_cache)。
   - itemDetail 里带 `resume_secs`(续播进度)、`is_favorite`、`played` —— 这些**随时会变**,
     还会被别的设备改。落盘跨重启复用 = 重开 App 看到的是上次的旧进度。
     那不是省流量,是给自己造一个「进度莫名回退」的 bug。
   所以这里只解决「同一次使用里来回翻」,TTL 5 分钟,且任何会改条目状态的命令一律清缓存。 */
const DETAIL_TTL_MS = 5 * 60 * 1000;
const detailMemo = new Map<string, { at: number; v: ItemDetail }>();

/** 会改条目状态的命令 —— 一律**整体清**详情缓存。
 *
 *  ★ 为什么不按 itemId 定点清(我第一版就是,错的):
 *    - 标记分集已看,变的是**剧集**的 `children[].played`。定点清分集 → 剧集详情还是旧的
 *      → 用户点了「已看」,列表纹丝不动,且不报错。
 *    - report_progress 的参数是 {pos, paused},**压根没有 itemId**,定点清是个永远
 *      删不掉东西的空操作;而且它每几秒发一次。
 *  这些都是低频用户动作(收藏/标记/停止播放),整体清最多让几个详情重取一次,
 *  换来的是「不可能因为漏清而显示旧状态」。别为了省这点流量再引一遍那个 bug。
 *  report_progress 仍然不在表里:高频,进度由 stop_playback 收尾时清一次就够。 */
const ITEM_MUTATIONS = new Set(["set_played", "set_favorite", "stop_playback"]);

/* ---------- 列表级缓存 ----------
   详情页有 detailMemo,列表却一个都没有:首页/媒体库/收藏每次 mount 全量重拉。
   桌面上不明显(鼠标操作少),TV 上返回键是主交互 —— 每次退回首页都要重跑
   views + resume + nextUp + N×latest,机顶盒网络下就是用户说的「每次打开都要更新」。

   TTL 同样取 5 分钟,且和 detailMemo 共用一套失效规则(见 ITEM_MUTATIONS):
   标记已看/收藏/停止播放都会让「继续观看」「收藏」变脸,不清就会显示旧列表。 */
const listMemo = new Map<string, { at: number; v: unknown }>();

/** 包一层 TTL 缓存。key 必须把全部入参编进去,否则不同参数会互相串。 */
function memo<T>(key: string, fetch: () => Promise<T>): Promise<T> {
  const hit = listMemo.get(key);
  if (hit && Date.now() - hit.at <= DETAIL_TTL_MS) return Promise.resolve(hit.v as T);
  return fetch().then((v) => {
    listMemo.set(key, { at: Date.now(), v });
    return v;
  });
}

/** 同步偷看列表缓存 —— 给 UI 首屏直接画,别先空一下。 */
export function peekList<T>(key: string): T | undefined {
  const hit = listMemo.get(key);
  if (!hit) return undefined;
  if (Date.now() - hit.at > DETAIL_TTL_MS) {
    listMemo.delete(key);
    return undefined;
  }
  return hit.v as T;
}

/** 同步偷看缓存,拿不到给 undefined。给 UI 用:有缓存就先画出来,别先清空闪一下。 */
export function peekItemDetail(itemId: string): ItemDetail | undefined {
  const hit = detailMemo.get(itemId);
  if (!hit) return undefined;
  if (Date.now() - hit.at > DETAIL_TTL_MS) {
    detailMemo.delete(itemId);
    return undefined;
  }
  return hit.v;
}

/** 清空条目详情缓存。切服务器/改条目状态后必须调 —— 否则会拿 A 服的详情去画 B 服。 */
export function clearItemCache() {
  detailMemo.clear();
  listMemo.clear();
}

/** 相似推荐(剧集/电影详情页底部)。空数组不是错误 —— 有些条目没有相似项,前端整段不渲染。
 *  实测(mecf.mebimmer.de):相似度靠谱,可能混 Series+Movie,单击照常进各自详情。 */
export const similarItems = (itemId: string) => invoke<Item[]>("similar_items", { itemId });

/** 网络图标库的一个条目(改图标弹窗浏览用)。 */
export type IconEntry = { name: string; url: string; source: string };
/** 网络图标库(四个聚合源,核层 24h 缓存)。force=true 重新拉。空数组 = 拉取失败或空。 */
export const iconLibrary = (force = false) => invoke<IconEntry[]>("icon_library", { force });

export const itemDetail = async (itemId: string): Promise<ItemDetail> => {
  const hit = peekItemDetail(itemId);
  if (hit) return hit;
  const v = await invoke<ItemDetail>("item_detail", { itemId });
  detailMemo.set(itemId, { at: Date.now(), v });
  return v;
};

// ---------- 播放器能力(对齐旧 Flutter video_player_service 契约) ----------
export type PlayerOpts = {
  speed: number;
  volume: number;
  muted: boolean;
  audio_delay: number;
  sub_delay: number;
  hwdec: string;
  shader_count: number;
  /** 当前在播这一版是不是杜比视界。「杜比视界软解」开关要照它显示真状态,
   *  别写死 false —— 核层会自动切软解,写死就成了「已经在软解但开关显示关」。 */
  dolby_vision: boolean;
};

/** OSD 一次拉齐当前可调项(别逐个 get)。 */
export const playerOpts = () => invoke<PlayerOpts>("player_opts");

export const setSpeed = (speed: number) => invoke<void>("set_speed", { speed });
export const setVolume = (volume: number) => invoke<void>("set_volume", { volume });
export const setMute = (mute: boolean) => invoke<void>("set_mute", { mute });
export const setAudioDelay = (secs: number) => invoke<void>("set_audio_delay", { secs });
export const setSubDelay = (secs: number) => invoke<void>("set_sub_delay", { secs });
/** "" / "auto" = 还原源比例;否则如 "16:9" / "4:3" / "2.35"。 */
export const setAspectRatio = (ratio: string) => invoke<void>("set_aspect_ratio", { ratio });
/** "auto-safe" / "d3d11va" / "no"(软解) 等。 */
export const setHwdec = (mode: string) => invoke<void>("set_hwdec", { mode });

/** 字幕样式,不传的项不动。
 *  ★ 这些全是 mpv 的 `sub-*` 全局属性 —— **主字幕和次字幕共用同一份**,
 *  mpv 压根没有 secondary-sub-font-size/-font/-color 这些属性(2026-07-16 实测 property-list)。
 *  scale:字幕缩放倍率 = **唯一的字幕大小旋钮**。
 *  这里曾有个 size(→ mpv sub-font-size),已删:ASS 字幕在 mpv 默认的
 *  sub-ass-override=scale 下完全无视 sub-font-size,那个旋钮对内封字幕从来就没生效过。
 *  别再加回来。 */
export const setSubStyle = (o: {
  font?: string;
  scale?: number;
  position?: number;
  background?: boolean;
  blendMode?: string;
}) => invoke<void>("set_sub_style", o);

/** 次字幕(双字幕);id 为空 = 关。 */
export const setSecondarySub = (id: string) => invoke<void>("set_secondary_sub", { id });
/** assOverride:"scale" 保留 ASS 自带样式 / "strip" 剥成纯文本(mpv 默认,即「次字幕不渲染样式」)。 */
export const setSecondarySubOpts = (o: {
  delay?: number;
  position?: number;
  assOverride?: string;
}) => invoke<void>("set_secondary_sub_opts", o);

/** 加载外挂字幕(本地路径或 URL)。 */
export const addSubtitle = (url: string, title?: string, secondary?: boolean) =>
  invoke<void>("add_subtitle", { url, title, secondary });

/** 截图,返回落盘路径(dir 省略 → 图片/LinPlayer)。 */
export const screenshot = (dir?: string) => invoke<string>("screenshot", { dir });

/** 超分档位清单 [id, 显示名][]。 */
/** 画质档位 `[id, 显示名, 窗口模式是否也生效]`。
 *  ★ 第三个字段别丢:放大类滤镜(FSR EASU / Anime4K CNN)只有画面区大于源才跑,
 *  窗口里播 1080p 点了毫无变化。要在**点之前**就标出来,别让用户点完自己猜。 */
export type ShaderLevel = [id: string, name: string, family: string];
export const shaderLevels = () => invoke<ShaderLevel[]>("shader_levels");
/** 画质滤镜强度 0~100(CAS 锐化 STR + FSR RCAS SHARP)。落盘 + 立即生效。
 *  返回 false = mpv 拒了 glsl-shader-opts(参数名对不上),**它自己不会报错**,要如实告诉用户。 */
/** 应用超分档位,返回实际挂上的 shader 数;非 off 却返 0 会直接报错(超分没生效)。 */
/** 挂超分的结果。★ count>0 只说明 mpv 收下了路径,**不代表 shader 会跑** ——
 *  Anime4K 每个 pass 都带「输出 > 源 ×1.2」的门槛,窗口没比源大就整条链空转。
 *  所以必须看 will_run,别只看 count 就报「已生效」(那正是它撒过的谎)。 */
export type ShaderApplied = {
  count: number;
  /** null = 没在播,尺寸未知,核层不下结论 */
  will_run: boolean | null;
  /** will_run=false 时的人话解释(带真实数字),直接显示给用户 */
  note: string | null;
};
export const setShaderLevel = (level: string) => invoke<ShaderApplied>("set_shader_level", { level });

/** mpv 属性直通(有专用命令的优先用专用命令)。 */
export const mpvGet = (name: string) => invoke<string | null>("mpv_get", { name });
export const mpvSet = (name: string, value: string) => invoke<void>("mpv_set", { name, value });
export const mpvCommand = (args: string[]) => invoke<void>("mpv_command", { args });

/** 首页 Hero 随机推荐(只返回有剧照的)。
 *  ★ 也走缓存:它每次都返回**不同**的条目,不缓存就意味着每次退回首页都要重新
 *  下载 5 张 1600px 大图 —— 这是 TV 上「每次打开都要更新」最刺眼的那一处。
 *  5 分钟内保持同一批,过期自然换新,随机性没丢。 */
export const listRandom = (limit = 5) =>
  memo(`random:${limit}`, () => invoke<Item[]>("list_random", { limit }));

/** 条目的全部版本+流(详情页 版本/音轨/字幕 选择器 + 媒体信息块)。 */
export const itemMedia = (itemId: string) =>
  invoke<MediaVersion[]>("item_media", { itemId });

/** 人物头像。 */
export function personUrl(session: LoginResult, personId: string, maxHeight = 160): string {
  // 演员头像在 Emby 里也是个 Item,和封面同一条路。
  return imgUrl(session, personId, "Primary", `h=${maxHeight}`);
}

/** 字节数 → 「18.4 GB」。 */
export function fmtSize(bytes: number | null): string {
  if (!bytes || bytes <= 0) return "";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let n = bytes;
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)} ${u[i]}`;
}

/** 码率 bps → 「45.0M」/「256k」(草稿媒体信息卡的写法)。 */
export function fmtBitrate(bps: number | null): string {
  if (!bps || bps <= 0) return "";
  if (bps >= 1e6) return `${(bps / 1e6).toFixed(1)}M`;
  return `${Math.round(bps / 1e3)}k`;
}

/** 高度 → 「2160p」。 */
export function fmtRes(height: number | null): string {
  return height && height > 0 ? `${height}p` : "";
}

export const aggregateSearch = (query: string) =>
  invoke<ServerGroup[]>("aggregate_search", { query });

export const setActiveServer = (serverId: string) =>
  invoke<void>("set_active_server", { serverId });

// ---------- 播放 ----------
/** mediaSourceId = 选版本(草稿 03/04「版本」选择器);省略 = 服务器给的第一个。
    指定了却不存在会报错,不会静默回落 —— 免得以为在看 4K 其实是 1080p。 */
export const play = (itemId: string, resumeSecs: number, mediaSourceId?: string | null) =>
  invoke<number>("play", { itemId, resumeSecs, mediaSourceId: mediaSourceId ?? null });

export const reportProgress = (pos: number, paused: boolean) =>
  invoke<void>("report_progress", { pos, paused }).catch(() => {});

export const stopPlayback = (pos: number) =>
  invoke<void>("stop_playback", { pos }).catch(() => {});

export const setPause = (paused: boolean) =>
  invoke<void>("set_pause", { paused });

export const seek = (pos: number) => invoke<void>("seek", { pos });

export const status = () => invoke<Status>("status");

export const tracks = () => invoke<Track[]>("tracks");

export const setTrack = (kind: string, id: string) =>
  invoke<void>("set_track", { kind, id });

export const applyPrefs = () =>
  invoke<[string | null, string | null]>("apply_prefs");

export const getPrefs = () => invoke<Prefs>("get_prefs");

/* ---------------- 应用内更新(双渠道) ---------------- */

export type UpdateChannel = "stable" | "prerelease";

export type UpdateSettings = {
  channel: UpdateChannel;
  auto_check: boolean;
  /** 当前版本,取自 tauri.conf.json(= 发行 zip 的版本号)。 */
  current_version: string;
  /** false = 安装目录不可写(如解压进了 Program Files),只能引导去网页手动下载。 */
  can_self_update: boolean;
};

export type UpdateInfo = {
  /** 原始 tag,如 `v1.2.0-build91-pre`。 */
  tag: string;
  /** 规约成 x.y.z,只用于显示。 */
  version: string;
  name: string;
  notes: string;
  html_url: string;
  prerelease: boolean;
  asset_name: string | null;
  asset_url: string | null;
  asset_size: number;
};

export const getUpdateSettings = () => invoke<UpdateSettings>("get_update_settings");
export const setUpdateSettings = (channel: UpdateChannel, autoCheck: boolean) =>
  invoke<void>("set_update_settings", { channel, autoCheck });

/** `null` = 确实已是最新;**抛错** = 没查成(断网/GitHub 限流)。两者别混为一谈。 */
export const checkUpdate = () => invoke<UpdateInfo | null>("check_update");

/** 下载 + 校验 + 覆盖 + 重启。成功时**本进程会退出**,这个 Promise 不会正常 resolve。
 *  进度监听 `update-download` 事件,载荷 `[已下载, 总大小]`。 */
export const downloadAndApplyUpdate = () => invoke<void>("download_and_apply_update");

/** ★ 只收选轨三项 —— 核层 set_prefs 也只认这三个参数(其余走 `..cfg.prefs.clone()` 保留)。
 *  以前这里标成 `p: Prefs`,逼调用方拼一个完整 Prefs 再扔掉多余字段:
 *  看着像「整体覆盖」,给人一种「不传的字段会被清掉」的错觉,新增 Prefs 字段时
 *  每个调用点都得跟着改一遍。 */
/** 三条筛选正则。**校验必须问 Rust**(validateTrackRegex):浏览器的 RegExp 支持前后瞻,
    Rust 的 regex crate 不支持 —— 拿 JS 校验会放过 Rust 编译不过的写法,
    结果是「设置存下了却永不命中」,而且两边都不报错。 */
export type TrackRegexes = Pick<Prefs, "version_regex" | "sub_regex" | "audio_regex">;
export const validateTrackRegex = (pattern: string) =>
  invoke<void>("validate_track_regex", { pattern });
export const setTrackRegexes = (r: TrackRegexes) =>
  invoke<void>("set_track_regexes", {
    versionRegex: r.version_regex,
    subRegex: r.sub_regex,
    audioRegex: r.audio_regex,
  });

export type TrackPrefs = Pick<Prefs, "audio_lang" | "sub_lang" | "sub_enabled">;
export const setPrefs = (p: TrackPrefs) =>
  invoke<void>("set_prefs", {
    audioLang: p.audio_lang,
    subLang: p.sub_lang,
    subEnabled: p.sub_enabled,
  });

// ---------- 网盘源 ----------
export const sourceLogin = (
  kind: string,
  baseUrl: string,
  username: string,
  password: string,
  cookie: string | null,
  /** 令牌/Cookie 系源用它带 refresh_token / cookie / authorization 等凭据(扫码确认后原样回传)。 */
  extra?: Record<string, string> | null,
) => invoke<void>("source_login", { kind, baseUrl, username, password, cookie, extra: extra ?? null });

/** 扫码登录:出码。image 可直接当 `<img src>`,ctx 原样回传给 sourceQrPoll。 */
export type QrStart = { image: string; ctx: string };
/** 扫码登录:轮询结果。confirmed 时 credentials 原样塞进 sourceLogin 的 extra 落库。 */
export type QrPoll =
  | { state: "pending" }
  | { state: "expired" }
  | { state: "confirmed"; credentials: Record<string, string> };

/** 只有扫码型源(baidu / aliyundrive / pan189)支持。 */
export const sourceQrStart = (kind: string) => invoke<QrStart>("source_qr_start", { kind });
export const sourceQrPoll = (kind: string, ctx: string) =>
  invoke<QrPoll>("source_qr_poll", { kind, ctx });

/** 账密登录:手机号+密码换令牌,返回的凭据原样塞进 sourceLogin 的 extra 落库。目前仅 pan189。 */
export const sourcePasswordLogin = (kind: string, username: string, password: string) =>
  invoke<Record<string, string>>("source_password_login", { kind, username, password });

export const sourceListDir = (dirId: string | null) =>
  invoke<SourceEntry[]>("source_list_dir", { dirId });

/** 源端全盘搜索。后端返回「该源不支持搜索」时,调用方应退回当前目录本地过滤。 */
export const sourceSearch = (query: string) =>
  invoke<SourceEntry[]>("source_search", { query });

export const sourcePlay = (entry: SourceEntry, resumeSecs: number) =>
  invoke<number>("source_play", {
    entryId: entry.id,
    entryName: entry.name,
    resumeSecs,
    raw: entry.raw ?? null,
  });

export const sourceWatchdog = (pos: number) =>
  invoke<boolean>("source_watchdog", { pos }).catch(() => false);

// ---------- 收藏 ----------
/** 收藏列表。**排序在前端本地做** —— 服务端 SortBy 在 UHD fork 上是死的(见 emby.rs favorites 注释)。 */
export const listFavorites = () => invoke<Item[]>("list_favorites");
export const setFavorite = (itemId: string, fav: boolean) =>
  invoke<void>("set_favorite", { itemId, fav });

/* ---------- 管理员动作(对标 Emby web 的右键菜单) ----------
   三项打的真实端点,别被名字糊弄:
     刷新媒体库 = refreshItem(id, false)  只补缺失,不覆盖已有元数据
     扫描媒体库 = scanLibraries()         整台服务器找新文件
     刷新元数据 = refreshItem(id, true)   强制重刮,替换已有元数据 */
export const isAdmin = () => invoke<boolean>("is_admin");
export const refreshItem = (itemId: string, full: boolean) =>
  invoke<void>("refresh_item", { itemId, full });
export const scanLibraries = () => invoke<void>("scan_libraries");

// ---------- 多账号/服务器 ----------
export const listAccounts = () => invoke<AccountInfo[]>("list_accounts");
export const removeAccount = (serverId: string) =>
  invoke<void>("remove_account", { serverId });

/** 并发探测所有账号连通性,返回带 status 三态的列表(状态点靠它)。 */
export const probeAccounts = () => invoke<AccountInfo[]>("probe_accounts");

/** 编辑账号。**不传的字段 = 不改**;传空串 = 清空该字段。 */
export const updateAccount = (
  serverId: string,
  o: {
    name?: string;
    remark?: string;
    iconUrl?: string;
    allowInsecureTls?: boolean;
    password?: string;
  },
) =>
  invoke<void>("update_account", {
    serverId,
    name: o.name ?? null,
    remark: o.remark ?? null,
    iconUrl: o.iconUrl ?? null,
    allowInsecureTls: o.allowInsecureTls ?? null,
    password: o.password ?? null,
  });

export const reorderAccounts = (from: number, to: number) =>
  invoke<void>("reorder_accounts", { from, to });

/** 图标:下载+缓存后返回 data URI;失败 → 前端回落内置图标。 */
export const accountIcon = (serverId: string) =>
  invoke<string>("account_icon", { serverId });
/** 本地图片存为图标,返回 data URI(同时记住原路径,缓存清了也能重建)。 */
export const setAccountIconFile = (serverId: string, filePath: string) =>
  invoke<string>("set_account_icon_file", { serverId, filePath });
export const clearAccountIcon = (serverId: string) =>
  invoke<void>("clear_account_icon", { serverId });

// ---------- 服务器线路 ----------
/** 并发探测各线路延迟(GET /System/Info/Public,非 ping)。ms=null 即不通。 */
export const probeLines = (serverId: string) =>
  invoke<LineProbe[]>("probe_lines", { serverId });
/** 只探一条线路。整表探测要等最慢那条(6s)才返回 —— 要「先出表再逐条填」就用这个。 */
export const probeLine = (serverId: string, index: number) =>
  invoke<LineProbe>("probe_line", { serverId, index });
/** 整表覆写(增删改排序都走它)。 */
export const setLines = (serverId: string, lines: ServerLine[]) =>
  invoke<void>("set_lines", { serverId, lines });
/** 切当前线路;若是活跃服务器会同时刷新会话地址,无需重启。 */
export const setActiveLine = (serverId: string, index: number) =>
  invoke<void>("set_active_line", { serverId, index });

export type SyncedLines = {
  /** 服主是否部署了 emby_ext_domains。**false 是常态**(绝大多数服务器没装),不是错误。 */
  supported: boolean;
  added: number;
  total: number;
};
/** 同步线路:从服主部署的 emby_ext_domains 拉取备用域名并入线路表(只增不删,按 url 去重)。
 *  上游 https://github.com/uhdnow/emby_ext_domains —— 服主自部署的 Go 小服务,
 *  挂在自己 Emby 的同一 origin 下(`/emby/System/Ext/ServerDomains`),靠同源隐式匹配。
 *  ★ 它**不是**测延迟。测延迟是 probeLines,两个按钮两回事。 */
export const syncLines = (serverId: string) =>
  invoke<SyncedLines>("sync_lines", { serverId });

// ---------- 测试连接 / 批量 / 深链 ----------
/** 登录**前**探服务器公开信息(草稿页 06「测试连接」)。不落账号、不动会话。 */
export const testConnection = (server: string) =>
  invoke<ServerInfo>("test_connection", { server });

export type ParsedLine = { name: string; url: string };

/** 一个账号块:一台服务器(可能多线路)+ 该账号的弹幕线路 + 用户名/密码。
    ★ 形状必须与 core/server_batch.rs 的 ParsedServerBlock 一致 —— 块要原样回传给
    batchAddServers,自己瞎编字段(如 urls/remark)会在回传时被 serde 丢掉。 */
export type ParsedServerBlock = {
  username: string | null;
  password: string | null;
  lines: ParsedLine[];
  danmaku_lines: ParsedLine[];
};
export type BatchAddResult = {
  server_id: string | null;
  name: string;
  error: string | null;
};
/** 纯解析,不登录不落盘 —— 拿去展示让用户核对,确认后再 batchAddServers。 */
export const batchParse = (text: string) =>
  invoke<ParsedServerBlock[]>("batch_parse", { text });
export const batchAddServers = (
  blocks: ParsedServerBlock[],
  fallbackUsername?: string | null,
  fallbackPassword?: string | null,
  fallbackName?: string | null,
) =>
  invoke<BatchAddResult[]>("batch_add_servers", {
    blocks,
    fallbackUsername: fallbackUsername ?? null,
    fallbackPassword: fallbackPassword ?? null,
    fallbackName: fallbackName ?? null,
  });

export type DeepLinkAddServer = { name: string | null; block: ParsedServerBlock };
/** ⚠️ 返回非 null **不等于**可以直接加 —— 深链可能来自任意网页/聊天窗。
    必须弹确认框展示地址与用户名,用户点头后才 batchAddServers。 */
export const parseDeepLink = (url: string) =>
  invoke<DeepLinkAddServer | null>("parse_deep_link", { url });
/** ★ 返回的是**原始 URL 字符串**(冷启动命令行里的 linplayer://…),不是解析结果 ——
    还要再喂给 parseDeepLink。且只在冷启动有效:App 已开着时点深链会拉起第二个进程,
    那需要单实例守卫(未接,已知缺口)。 */
export const startupDeepLink = () => invoke<string | null>("startup_deep_link");

// ---------- 夸克扫码 ----------
export type QuarkScan = { device_id: string; qr_data: string; query_token: string };
export const quarkScanStart = () => invoke<QuarkScan>("quark_scan_start");
/** false = 继续轮询;true = 已换到 token 且夸克源已装为活跃源。 */
export const quarkScanPoll = (deviceId: string, queryToken: string) =>
  invoke<boolean>("quark_scan_poll", { deviceId, queryToken });

// ---------- Ani-RSS ----------
/* 核层是 Json 直通(镜像 Ani-RSS 服务端的 map),故这里统一 Json 类型。
   set_config 必须回传 getConfig 的完整 map 改字段后的结果 —— 传半张表会丢字段。 */
export type Json = Record<string, unknown>;

export const anirssListAni = () => invoke<Json[]>("anirss_list_ani");
export const anirssGetConfig = () => invoke<Json>("anirss_get_config");
export const anirssSetConfig = (config: Json) => invoke<void>("anirss_set_config", { config });
export const anirssSearchBgm = (name: string) => invoke<Json>("anirss_search_bgm", { name });
export const anirssGetAniBySubjectId = (id: string) =>
  invoke<Json>("anirss_get_ani_by_subject_id", { id });
export const anirssAddAni = (ani: Json) => invoke<void>("anirss_add_ani", { ani });
export const anirssSetAni = (ani: Json) => invoke<void>("anirss_set_ani", { ani });
export const anirssDeleteAni = (ids: string[], deleteFiles: boolean) =>
  invoke<void>("anirss_delete_ani", { ids, deleteFiles });
export const anirssRefreshAni = (id: string) => invoke<void>("anirss_refresh_ani", { id });
export const anirssRefreshAll = () => invoke<void>("anirss_refresh_all");
/** 当前下载中的种子信息 → 订阅行的「下载中 · 62%」。 */
export const anirssTorrentsInfos = () => invoke<Json>("anirss_torrents_infos");
export const anirssProxyImageUrl = (imgUrl: string) =>
  invoke<string>("anirss_proxy_image_url", { imgUrl });

// ---------- 排行榜 ----------
export const rankingCategories = () =>
  invoke<RankingCategory[]>("ranking_categories");
export const rankingFetch = (categoryId: string, forceRefresh = false) =>
  invoke<RankingEntry[]>("ranking_fetch", { categoryId, forceRefresh });

// ---------- 下载 ----------
export const downloadList = () => invoke<DownloadItem[]>("download_list");
export const downloadEnqueue = (
  itemId: string,
  type: string,
  title: string,
  container: string,
  posterUrl: string | null,
) => invoke<string>("download_enqueue", { itemId, type, title, container, posterUrl });
export const downloadPause = (id: string) => invoke<void>("download_pause", { id });
export const downloadResume = (id: string) => invoke<void>("download_resume", { id });
export const downloadRemove = (id: string) => invoke<void>("download_remove", { id });
export const downloadSetThreads = (threads: number) =>
  invoke<void>("download_set_threads", { threads });
/** 只清记录,不删文件。返回清掉的条数。 */
export const downloadClearCompleted = () => invoke<number>("download_clear_completed");
/** 播放已下载完成的本地文件(下载页 ▶)。传任务 id,不是路径。返回续播位置。 */
export const playLocal = (id: string, resumeSecs = 0) =>
  invoke<number>("play_local", { id, resumeSecs });

// ---------- CF 优选加速 ----------
export type CfTestResult = {
  ip: string;
  latency_ms: number;
  loss_rate: number;
  download_kbps: number | null;
};
export type CfProxyStatus = { server_id: string; local_url: string; pinned_ip: string };
/** 测速,已按优劣排序。validateHost 可剔除「TCP 通但 HTTP 死」的 IP。 */
export const cfSpeedTest = (validateHost?: string | null, testUrl?: string | null) =>
  invoke<CfTestResult[]>("cf_speed_test", {
    validateHost: validateHost ?? null,
    testUrl: testUrl ?? null,
  });
/** 开优选:返回本地反代基址;已开则热换 IP,且立即生效无需重启。 */
export const cfProxyEnable = (serverId: string, ip: string) =>
  invoke<string>("cf_proxy_enable", { serverId, ip });
export const cfProxyDisable = (serverId: string) =>
  invoke<void>("cf_proxy_disable", { serverId });
export const cfProxyStatus = () => invoke<CfProxyStatus[]>("cf_proxy_status");

// ---------- 多线程加载(预取代理) ----------
/** servers = 开了该功能的账号 id(= Account.server,和 server_id 参数同一个键);空表 = 全关。
 *  粒度是服务器不是线路:选中一台服,它的所有线路都走预取。 */
export type PrefetchSettings = { servers: string[]; threads: number; cache_bytes: number };
export const getPrefetchSettings = () => invoke<PrefetchSettings>("get_prefetch_settings");
/** threads 必须 2~4、cache_bytes ≥16MB,越界核层直接报错(不静默夹紧)。 */
export const setPrefetchSettings = (settings: PrefetchSettings) =>
  invoke<void>("set_prefetch_settings", { settings });

// ---------- 播放器默认行为 ----------
/** 设置页「播放器」那一组。**核心配置**,不是 localStorage —— 2026-07-19 之前这 6 项
 *  只存在浏览器本地,改了对播放毫无影响;现在由核层在每次起播时应用。
 *  hwdec 直接是 mpv 的取值("auto-safe" 硬解 / "no" 软解),别在前端再翻译一层。 */
export type PlaybackPrefs = {
  hwdec: "auto-safe" | "no";
  default_speed: number;
  /** 片头/片尾是两个独立开关:播放页「更多」面板里就是两行。 */
  skip_intro: boolean;
  skip_outro: boolean;
  preview_thumbs: boolean;
  dolby_auto_sw: boolean;
  external_player: string;
};
export const getPlaybackPrefs = () => invoke<PlaybackPrefs>("get_playback_prefs");
/** 越界/路径不存在核层直接报错(不静默夹紧、不静默接受)。 */
export const setPlaybackPrefs = (settings: PlaybackPrefs) =>
  invoke<void>("set_playback_prefs", { settings });

/** 自定义 mpv 配置(`<数据根>/data/mpv/mpv.conf`)。
 *  存的是**文件原文**,libmpv 自己解析(我们没写 ini 解析器)。
 *  ★ 只在 `Player::new` 时读一次,而播放器是进程启动时建的 —— 改完必须重启应用。
 *  active=false 表示文件不存在,即完全不加载任何配置(出厂状态)。 */
export type MpvConf = { text: string; path: string; active: boolean };
export const getMpvConf = () => invoke<MpvConf>("get_mpv_conf");
/** 空文本 = 删掉配置文件,回到出厂状态。写不进去(权限/只读盘)会报错,不静默。 */
export const setMpvConf = (text: string) => invoke<MpvConf>("set_mpv_conf", { text });

/** 章节。跳过片头片尾与进度条缩略图**共用**这一份数据,起播后拉一次即可。
 *  chapters 为空 = 服务端没有章节(没刮削),两个功能都自动静默不工作 —— 这是正常情况。
 *  intro/outro 已由核层按开关判好:开关关着时恒为 null,前端不用再判一次。 */
export type Chapter = { index: number; start_secs: number; name: string; image_url: string | null };
export type ChapterInfo = {
  chapters: Chapter[];
  intro: [number, number] | null;
  /** 可跳过的片尾 [开始, 落点]。核层只在片尾**后面还有内容**(下集预告)时才给 ——
   *  非 null 就是可跳的,不用再自己判总时长。片尾是最后一章时这里是 null(跳过去
   *  等于把这集直接结束掉,那不是「跳过片尾」)。 */
  outro: [number, number] | null;
  thumbs: boolean;
};
export const chapterInfo = (itemId: string, runtimeSecs: number) =>
  invoke<ChapterInfo>("chapter_info", { itemId, runtimeSecs });

/** 交给外部播放器,返回它的路径。**调它就别再进内置播放页**。
 *  未设置外部播放器时会报错 —— 调用前先看 playback prefs 的 external_player。 */
export const playExternal = (itemId: string, resumeSecs: number, mediaSourceId?: string | null) =>
  invoke<string>("play_external", { itemId, resumeSecs, mediaSourceId: mediaSourceId ?? null });

// ---------- 跨服续播 / 回传 ----------
export const getCrossServerResume = () => invoke<boolean>("get_cross_server_resume");
export const setCrossServerResume = (enabled: boolean) =>
  invoke<void>("set_cross_server_resume", { enabled });

export type WritebackSettings = {
  enabled: boolean;
  /** "all" | "first" | "latest" */
  range: string;
  include_progress: boolean;
};
export const getWritebackSettings = () => invoke<WritebackSettings>("get_writeback_settings");
export const setWritebackSettings = (settings: WritebackSettings) =>
  invoke<void>("set_writeback_settings", { settings });

// ---------- 观看记录 ----------
export type WatchRecord = {
  record_id: string;
  /** `server:user_id` */
  scope_key: string;
  canonical_key: string;
  title: string;
  series_title: string | null;
  season_number: number | null;
  episode_number: number | null;
  [k: string]: unknown;
};
/** currentOnly=true 只列当前服务器+用户的记录;false = 全部(跨服)。 */
export const watchHistoryList = (currentOnly: boolean) =>
  invoke<WatchRecord[]>("watch_history_list", { currentOnly });
/** 删一条:传 record_id(不是 canonical_key)。 */
export const watchHistoryDelete = (recordId: string) =>
  invoke<void>("watch_history_delete", { recordId });
export const watchHistoryClear = () => invoke<void>("watch_history_clear");

// ---------- 字幕翻译 ----------
export type TranslationSettings = Record<string, unknown>;
export const getTranslationSettings = () =>
  invoke<TranslationSettings>("get_translation_settings");
export const setTranslationSettings = (settings: TranslationSettings) =>
  invoke<void>("set_translation_settings", { settings });
/** 各引擎是否已配好 → 设置页的状态点。 */
export const translationEngineStatus = () =>
  invoke<Record<string, boolean>>("translation_engine_status");

export type WhisperModelInfo = {
  key: string;
  display_name: string;
  size_label: string;
  downloaded: boolean;
  downloaded_bytes: number;
};
/** 依赖探测:返回**可执行文件路径**,null = 没找到(不是布尔)。 */
export type WhisperDeps = { whisper: string | null; ffmpeg: string | null };
export const whisperModels = () => invoke<WhisperModelInfo[]>("whisper_models");
export const whisperDownload = (model: string) =>
  invoke<string>("whisper_download", { model });
export const whisperDelete = (model: string) => invoke<void>("whisper_delete", { model });
export const whisperDeps = () => invoke<WhisperDeps>("whisper_deps");
export const whisperDownloadFfmpeg = () => invoke<string>("whisper_download_ffmpeg");

// ---------- 插件 ----------
/** 字段与核层 `PluginManager::list()` 一一对应 —— 这里漏一个字段,前端就会以为
 *  「后端没透传」然后去写一段假的兜底逻辑([stale-waijie-lies] 那个坑)。 */
export type PluginInfo = {
  id: string;
  name: string;
  version: string;
  author: string;
  description: string;
  permissions: string[];
  httpAllowedHosts: string[];
  icon: string | null;
  homepage: string | null;
  /** loaded / disabled / error */
  status: string;
  enabled: boolean;
  error: string | null;
  /** 开发模式挂载(目录直接映射,改完存盘热重载)。 */
  dev: boolean;
  category: string;
  apiVersion: number;
  contributes: {
    dataSources: number;
    panels: number;
    actions: number;
    sandboxViews: number;
  };
};
export const pluginList = () => invoke<PluginInfo[]>("plugin_list");
export const pluginEnable = (id: string) => invoke<void>("plugin_enable", { id });
export const pluginDisable = (id: string) => invoke<void>("plugin_disable", { id });
/** 从 **.ipk** 安装(不是 .lpk —— 核层是 install_ipk)。返回的是原始 Json,不保证是 PluginInfo。 */
export const pluginInstall = (path: string) =>
  invoke<Record<string, unknown>>("plugin_install", { path });
export const pluginUninstall = (id: string) => invoke<void>("plugin_uninstall", { id });

/** 原生文件选择器装 .ipk。返回 null = 用户取消。 */
export const pluginPickInstall = () =>
  invoke<Record<string, unknown> | null>("plugin_pick_install");
/** 原生目录选择器挂一个开发中的插件目录(改完存盘即热重载)。返回 null = 取消。 */
export const pluginPickDevDir = () =>
  invoke<Record<string, unknown> | null>("plugin_pick_dev_dir");
export const pluginReload = (id: string) => invoke<void>("plugin_reload", { id });
/** 轮询开发模式插件的文件变化;true = 有插件被重载了,该刷新界面。 */
export const pluginDevPoll = () => invoke<boolean>("plugin_dev_poll");

/** 某类贡献点的全部条目。kind: dataSources / panels / actions / sandboxViews。 */
export const pluginExtensions = (typeId: string) =>
  invoke<Record<string, unknown>[]>("plugin_extensions", { typeId });
/** 挂在某个 slot 的面板。slot 见 PANEL_SLOTS(home.stats/sidebar/settings/player.overlay/page)。 */
export const pluginPanels = (slot: string) =>
  invoke<PluginPanel[]>("plugin_panels", { slot });
/** 已启用插件贡献的数据源(「添加服务器」页据此列出可选源)。 */
export const pluginDataSources = () => invoke<PluginDataSource[]>("plugin_sources");

/** 触发某贡献点的 handler(按钮点击等)。 */
export const pluginTrigger = (
  pluginId: string,
  typeId: string,
  extId: string,
  args?: unknown[],
) => invoke<unknown>("plugin_trigger", { pluginId, typeId, extId, args });
/** 调 data 里某具名字段的 handler(面板的 render、表单的 submit)。 */
export const pluginInvokeField = (
  pluginId: string,
  typeId: string,
  extId: string,
  field: string,
  args?: unknown[],
) => invoke<unknown>("plugin_invoke_field", { pluginId, typeId, extId, field, args });
/** 回填一次需要返回值的 UI 请求(showForm/showDialog/showList/showProgress)。 */
export const pluginUiRespond = (id: number, value: unknown) =>
  invoke<void>("plugin_ui_respond", { id, value });

export type PluginPanel = {
  pluginId: string;
  id: string;
  data: Record<string, unknown>;
  [k: string]: unknown;
};
export type PluginDataSource = {
  /** 直接可当 SourceKind 用:`plugin:<插件id>/<源id>`。 */
  kind: string;
  pluginId: string;
  sourceId: string;
  name: string;
  /** manifest 里声明的登录表单字段;null = 这个源不需要登录。 */
  auth: { fields: PluginAuthField[] } | null;
};
export type PluginAuthField = {
  id: string;
  label?: string;
  type?: string;
  placeholder?: string;
  required?: boolean;
};

// ---------- 插件市场 ----------
/** 权限词表(人话说明)。**由核层透出**,前端不许抄一份 —— 抄了就会漏新权限。 */
export type PluginPermissionInfo = {
  id: string;
  title: string;
  description: string;
  dangerous: boolean;
};
export const pluginPermissionCatalog = () =>
  invoke<PluginPermissionInfo[]>("plugin_permission_catalog");

export type PluginSource = {
  id: string;
  name: string;
  url: string;
  enabled: boolean;
  /** 官方源。**可禁不可删**。 */
  builtin: boolean;
};
export type MarketVersion = {
  version: string;
  api_version: number;
  min_app_version: string | null;
  package_url: string;
  /** null = 这个源没提供校验和,UI 要如实标出来。 */
  sha256: string | null;
  published_at: string | null;
  changelog: string | null;
};
export type MarketPlugin = {
  id: string;
  name: string;
  description: string;
  author: string;
  /** 构建期内联的 data URI,不会碎图也不额外发请求。 */
  icon: string | null;
  category: string | null;
  tags: string[];
  targets: string[];
  permissions: string[];
  contributes: Record<string, unknown> | null;
  versions: MarketVersion[];
  source_id: string;
  source_name: string;
  /** false = 第三方源,卡片上要打徽章。 */
  from_builtin: boolean;
};
/** errors 是**按源**收集的:一个第三方源挂了不该让整个市场变成报错页。 */
export type MarketList = {
  plugins: MarketPlugin[];
  errors: { source: string; error: string }[];
  apiVersion: number;
  cached: boolean;
};

export const pluginMarketSources = () => invoke<PluginSource[]>("plugin_market_sources");
export const pluginMarketAddSource = (name: string, url: string) =>
  invoke<PluginSource[]>("plugin_market_add_source", { name, url });
export const pluginMarketRemoveSource = (id: string) =>
  invoke<PluginSource[]>("plugin_market_remove_source", { id });
export const pluginMarketToggleSource = (id: string, enabled: boolean) =>
  invoke<PluginSource[]>("plugin_market_toggle_source", { id, enabled });
export const pluginMarketList = (refresh?: boolean) =>
  invoke<MarketList>("plugin_market_list", { refresh });
/** 下载 → 校验 sha256 → 装。version 省略 = 当前宿主能装的最新版。 */
export const pluginMarketInstall = (id: string, version?: string) =>
  invoke<{ info: Record<string, unknown>; version: string; verified: boolean }>(
    "plugin_market_install",
    { id, version },
  );

// ---------- 代理 ----------
export const getProxy = () => invoke<ProxyConfig>("get_proxy");
export const setProxy = (config: ProxyConfig) => invoke<void>("set_proxy", { config });

// ---------- 弹幕源 ----------
/* ★ 核层收发的都是**列表**(Vec<DanmakuServer>),不是单个对象。
   曾经这里写成单对象:读回来的数组塞进对象类型 → api_url 恒 undefined(输入框永远空),
   写出去少了 sources 参数 → invoke 直接被拒、还被 .catch 吞掉 → 「保存」永远是空操作。
   两头都不报错,所以别再改回单对象。 */
/** 内置弹弹Play 默认源(凭据编译期注入,不在自建源表里)。available=false 表示这个构建没带凭据。 */
export type OfficialDanmaku = { name: string; available: boolean };
export const getOfficialDanmaku = () => invoke<OfficialDanmaku>("get_official_danmaku");
export const getDanmakuConfig = () => invoke<DanmakuServer[]>("get_danmaku_config");
export const setDanmakuConfig = (sources: DanmakuServer[]) =>
  invoke<void>("set_danmaku_config", { sources });

/** 按标题搜番剧,多源并行分组返回(每组自带 error,别丢)。
 *  ★ 回来的 anime.episodes 恒为空 —— 集列表要按需走 danmakuEpisodes 取。 */
export const danmakuSearch = (keyword: string) =>
  invoke<DanmakuSourceGroup[]>("danmaku_search", { keyword });

/** 取某源某条目的集列表(点开条目时才发)。 */
export const danmakuEpisodes = (sourceId: string, animeId: string, animeTitle: string) =>
  invoke<DanmakuEpisode[]>("danmaku_episodes", { sourceId, animeId, animeTitle });

/** sourceId 必须带上:episodeId 在各源之间**不同号**,不指定源会从别的源的 id 空间里
 *  瞎捞一份对不上的弹幕(旧版就漏了这个参数)。 */
export const danmakuLoad = (episodeId: string, sourceId?: string) =>
  invoke<DanmakuComment[]>("danmaku_load", { episodeId, sourceId: sourceId ?? null });

/** 智能匹配候选(带评分)。 */
export const danmakuMatch = (input: DanmakuMatchInput) =>
  invoke<DanmakuMatchCandidate[]>("danmaku_match", { input });

/** 自动挂弹幕:返回 null = 没有够可信的匹配,该回落到 danmakuMatch 让用户挑。 */
export const danmakuAutoLoad = (
  input: DanmakuMatchInput,
  options: DanmakuFilterOptions,
  chConvert?: number | null,
  anchorKey?: string | null,
) =>
  invoke<DanmakuComment[] | null>("danmaku_auto_load", {
    input,
    options,
    chConvert: chConvert ?? null,
    anchorKey: anchorKey ?? null,
  });

/** 自动挂载的评分门槛(低于它就别自动挂,交给用户挑)。 */
export const danmakuMinAutoScore = () => invoke<number>("danmaku_min_auto_score");

export const danmakuLoadLocal = (path: string) =>
  invoke<DanmakuComment[]>("danmaku_load_local", { path });

/** 弹幕过滤/去重的默认参数(核层只管过滤,渲染参数是前端的事)。 */
export const defaultDanmakuFilter = (): DanmakuFilterOptions => ({
  blockwords: [],
  user_blocklist: [],
  blocked_modes: [],
  dedup: true,
  dedup_window: 10,
});

export type DanmakuComment = {
  time: number;
  text: string;
  mode: number; // 1=滚动 4=底 5=顶
  color: number;
  source: string;
  cid: string | null;
  user_id: string | null;
  count: number;
};

// ---------- Trakt / Bangumi 同步 ----------
export const traktAccount = () => invoke<SyncAccount | null>("trakt_account");
export const traktDeviceCode = () => invoke<TraktDeviceCode>("trakt_device_code");
export const traktPoll = (deviceCode: string) =>
  invoke<TraktPollResult>("trakt_poll", { deviceCode });
export const traktLogout = () => invoke<void>("trakt_logout");
export const bangumiAccount = () => invoke<SyncAccount | null>("bangumi_account");
export const bangumiAuthorizeUrl = () => invoke<string>("bangumi_authorize_url", {});
export const bangumiExchange = (code: string) =>
  invoke<SyncAccount>("bangumi_exchange", { code });
export const bangumiLogout = () => invoke<void>("bangumi_logout");
/** 个人 Access Token 直登(https://next.bgm.tv/demo/access-token 自助生成)。
 *  相比授权码流的好处:不经我们的 CF 代理,代理挂了也能登;TV 上尤其重要 ——
 *  授权码要在电视上一个字符一个字符敲。核层会先打 /v0/me 验真,不存废令牌。 */
export const bangumiLoginToken = (token: string) =>
  invoke<SyncAccount>("bangumi_login_token", { token });

// ---------- 追剧日历(付费解锁) ----------
export type CalendarEntry = {
  title: string;
  subtitle: string | null;
  /** 精确放送时刻 ISO8601(Trakt 有);为空时用 weekday 归组。 */
  air_date: string | null;
  /** 每周放送日 1=周一…7=周日(Bangumi 用)。 */
  weekday: number | null;
  /** 每周固定放送时刻(ISO8601 UTC 首播时刻,按周重复 → 时分即每周更新时间)。
      Bangumi 官方 API 不给时刻,核层用 bangumi-data 补(约 64% 覆盖);取不到为 null,不显示时刻。 */
  broadcast_at: string | null;
  image_url: string | null;
  tmdb_id: number | null;
  /** 评分(10 分制,两源同口径)。★ null = 没人评过,**不是 0 分** —— 别画成 0.0。 */
  rating: number | null;
  /** 简介。Trakt 内联给(TMDB 那次请求顺手就有);**Bangumi 恒为 null**,
   *  要走 bangumiSummary(bangumi_id) 按需拉(/calendar 的 summary 实测整周全空)。 */
  summary: string | null;
  /** Bangumi subject id —— 按需拉简介用。Trakt 侧为 null。 */
  bangumi_id: number | null;
  source: "trakt" | "bangumi";
};

export type AfdianVerifyResult = {
  valid: boolean;
  plan_title: string;
  amount: string;
  reason: string | null;
};

export const traktCalendar = (onlyMine: boolean) =>
  invoke<CalendarEntry[]>("trakt_calendar", { onlyMine });
/** 单部番的简介(Bangumi)。核层带进程内缓存,重复调是瞬时的。null = 没有,别画。 */
export const bangumiSummary = (subjectId: number) =>
  invoke<string | null>("bangumi_summary", { subjectId });

export const bangumiCalendar = (onlyMine: boolean) =>
  invoke<CalendarEntry[]>("bangumi_calendar", { onlyMine });
export const afdianVerify = (orderNo: string) =>
  invoke<AfdianVerifyResult>("afdian_verify", { orderNo });
/** 赞助下单页地址。**别在前端硬编 URL** —— 收款地址只有核层那一份(见 lib.rs 的长注释)。 */
export const afdianSponsorUrl = () => invoke<string>("afdian_sponsor_url");

// ---------- 配置迁移(扫码搬服务器) ----------
export const configExportQr = () => invoke<string>("config_export_qr");
export const configImportQr = (payload: string) =>
  invoke<number>("config_import_qr", { payload });

/* ==== @shell-only:android 开始 ====================================
   手机控制台(电视出码,手机扫码当遥控器)。**只有安卓壳注册这几条命令**
   (见 apps/android/src/lib.rs 的 companion_*)。电视没摄像头,方向只能是
   电视出码、手机扫:核层在局域网起一个小网页,这里拿到它的地址去编二维码。
   手机上那一页能遥控、控播放、搜索、改设置、加/切服务器 —— 不只是登录。

   ★ 这对标记**不是注释,是契约**:两端的契约测试都按它切分 ——
     桌面壳那条("每个 invoke 都注册过")跳过本区块,安卓壳那条**只查**本区块。
     少了它,要么桌面 CI 因为查不到这几条而红(就是 2026-07-21 那次),
     要么把区块整个豁免掉、这几条从此没人把门。移动绑定时连标记一起移。 */

/** 手机控制台的真实状态。**别再回到只返回一个 url 的老形态** ——
 *  界面拿到 null 只能瞎猜原因,而 2026-07-21 的真因(开关默认值 false)
 *  和界面猜的"没连上局域网"毫无关系,用户照着提示查了半天网线。
 *  查状态时核层顺带自愈:开关开着却没在跑就重试起服。 */
export type CompanionStatus = {
  enabled: boolean;
  running: boolean;
  url: string | null;
  port: number | null;
  /** 说人话的失败原因;null = 一切正常。**界面直接显示它,不要自己编。** */
  error: string | null;
};
export const companionUrl = () => invoke<CompanionStatus>("companion_url");
/** 开/关手机控制台。开启失败会抛,别吞掉 —— 用户拨了开关得知道成没成。 */
export const companionSetEnabled = (enabled: boolean) =>
  invoke<void>("companion_set_enabled", { enabled });
/** 播放页把"现在放的是什么"报给核层 —— 手机控制台要显示片名,mpv 的状态里没有。 */
export const setNowPlaying = (title: string | null, sub?: string | null) =>
  invoke<void>("set_now_playing", { title, sub: sub ?? null });
/** 把当前主题镜像到核层,好让手机控制台显示对的当前值。 */
export const setThemePref = (theme: string) => invoke<void>("set_theme_pref", { theme });
/* ==== @shell-only:android 结束 ==================================== */

/* ---------- 图片 URL ----------
   走 `lpimg` 自定义协议(见 src-tauri/src/imgcache.rs):字节由 Rust 给,
   命中 2GB/30 天的磁盘缓存,miss 才回源。

   ## 两个变化,都别退回去
   1. **URL 里不再有 api_key。** 以前是 `?api_key=${session.token}` 直接进 `<img src>` ——
      token 就摊在 DOM 里、webview 网络日志里、Emby access log 里。现在上游地址由 Rust
      从会话现拼,前端只给条目 id。
   2. **不再依赖 session.server。** 换线路不会让缓存整盘失效(Rust 那边用账号主键当缓存键)。

   ## 前缀因平台而异,必须用 convertFileSrc 取
   Windows/Android 是 `http://lpimg.localhost/`,Linux/macOS 是 `lpimg://localhost/`
   (tauri 注入的 core.js 里就是这么分的)。写死任何一个,另一个平台上全站图片挂掉。
   ★ 只拿它取**前缀**:convertFileSrc 会对入参做 encodeURIComponent,
     把整个路径压成一个段(`/Items/1/x` → `%2FItems%2F1%2Fx`),路径得自己拼。 */
/* ★ 惰性求值,不能在模块顶层直接算。convertFileSrc 读的是 Tauri 注入的
   `window.__TAURI_INTERNALS__`,它一旦缺席(壳还没注入完、或者拿这个模块跑测试/
   在浏览器里开发)这一行就抛在**模块加载期** —— React 连挂载都轮不到,
   PageBoundary 也接不住(它只吃渲染期的错),结果是 `#root` 空着、整屏纯黑、
   遥控器毫无反应,和 [[transparent-window-crash-looks-like-blackscreen]] 是同一个病。
   一个取前缀的常量不值得赌上整个应用起不起得来。 */
let imgBase: string | null = null;
function IMG_BASE(): string {
  if (imgBase === null) imgBase = convertFileSrc("", "lpimg");
  return imgBase;
}

/* ---------- 插件自带文件的 URL(`lpplugin` 协议) ----------
   插件目录里的图标、逃生舱页面都从这里取。后端见 apps/desktop/src/pluginassets.rs。

   ★ 和 lpimg 一样,前缀因平台而异,必须用 convertFileSrc 取:
     Windows 是 `http://lpplugin.localhost/`,Linux 是 `lpplugin://localhost/`。
     插件 id 和相对路径拼在**路径**里(后端只认 path 的第一段做插件 id,不看 host ——
     host 在两个平台上都不是插件 id)。 */
let pluginBase: string | null = null;
function PLUGIN_BASE(): string {
  // 惰性求值的理由同 IMG_BASE:模块顶层直接算会在 Tauri 未注入时抛在加载期,整屏纯黑。
  if (pluginBase === null) pluginBase = convertFileSrc("", "lpplugin");
  return pluginBase;
}

/** 插件目录内某个文件的可用 URL。 */
export function pluginAssetUrl(pluginId: string, rel: string): string {
  return `${PLUGIN_BASE()}${pluginId}/${rel.replace(/^\/+/, "")}`;
}

/**
 * 把插件描述树里写的 `lpplugin://<插件id>/<相对路径>` 换成当前平台真正取得到的 URL。
 *
 * 插件作者写的是协议原样(文档也是这么教的),但那个字符串**只在 Linux 上碰巧能用**;
 * Windows 上 WebView2 根本不认 `lpplugin://` 这个 scheme,`<img src>` 直接是坏图,
 * 而且没有任何报错 —— 又一个「不报错,只是不显示」。
 * 其它协议(https / data:)原样返回。
 */
export function resolvePluginAssetUrl(url: string): string {
  if (!url.startsWith("lpplugin://")) return url;
  const rest = url.slice("lpplugin://".length).replace(/^\/+/, "");
  const slash = rest.indexOf("/");
  if (slash <= 0) return url; // 只有插件 id 没有文件名,原样丢回去让它坏得明显
  return pluginAssetUrl(rest.slice(0, slash), rest.slice(slash + 1));
}

/** session 形参保留:换服务器/重登时 session 变 → React 会重算 src → 图片跟着换。
 *  真去掉它,调用点就没有依赖能触发重渲染了(而且不报错,只是图不刷新)。 */
function imgUrl(_session: LoginResult, itemId: string, kind: string, q: string): string {
  return `${IMG_BASE()}i/${itemId}/${kind}?${q}`;
}

export function posterUrl(session: LoginResult, itemId: string, maxHeight = 480): string {
  return imgUrl(session, itemId, "Primary", `h=${maxHeight}`);
}

/** 横向缩略图(剧集封面/媒体库封面用 Primary，按宽度取，不裁剪比例)。 */
export function thumbUrl(session: LoginResult, itemId: string, maxWidth = 640): string {
  return imgUrl(session, itemId, "Primary", `w=${maxWidth}`);
}

export function backdropUrl(session: LoginResult, itemId: string, maxWidth = 1600): string {
  return imgUrl(session, itemId, "Backdrop", `w=${maxWidth}`);
}

/** 首页 Hero 的片名 Logo。原先长在 HomePage 里,注释写着「那份文件不归这里改」——
 *  图片走自定义协议后这话不成立了:路径白名单在 Rust 侧(imgcache::parse),
 *  散在页面里的拼法会绕开它。图片 URL 只此一处。
 *  ★ 核层 Item 没有 has_logo 标志位 → 调用点仍需 <img onError> 兜底回文字标题。 */
export function logoUrl(session: LoginResult, itemId: string, maxHeight = 150): string {
  return imgUrl(session, itemId, "Logo", `h=${maxHeight}`);
}

/** 格式化时长(秒 → h:mm:ss / m:ss)。 */
export function fmtTime(t: number): string {
  if (!isFinite(t) || t < 0) t = 0;
  const s = Math.floor(t % 60).toString().padStart(2, "0");
  const m = Math.floor((t / 60) % 60).toString().padStart(2, "0");
  const h = Math.floor(t / 3600);
  return h > 0 ? `${h}:${m}:${s}` : `${m}:${s}`;
}

/* ============================================================
   数据目录 —— 软件把东西放哪了,让用户看得见
   ============================================================ */

/** Portable=正常(exe 同级 userdata/) / Overridden=LP_DATA_DIR 指定 /
 *  SystemFallback=**异常**,exe 目录写不进去,数据没能留在包里,UI 必须告警。 */
export type RootKind = "Portable" | "Overridden" | "SystemFallback";

export type DataPaths = {
  root: string;
  config: string;
  data: string;
  cache: string;
  temp: string;
  webview: string;
  logs: string;
  downloads: string;
  kind: RootKind;
  /** exe 所在目录(= 解压出来的那个文件夹)。 */
  exe_dir: string;
};

export const dataPaths = () => invoke<DataPaths>("data_paths");
/** 弹系统原生选择文件夹对话框。返回 null = 用户取消(不是错误,别弹提示)。 */
export const pickDirectory = (start?: string | null) =>
  invoke<string | null>("pick_directory", { start: start ?? null });
/** 弹系统原生选择**文件**对话框。start 传当前文件路径(会定位到它所在目录)。
 *  返回 null = 用户取消(不是错误,别弹提示)。 */
export const pickFile = (
  start?: string | null,
  filterName?: string,
  extensions?: string[],
) =>
  invoke<string | null>("pick_file", {
    start: start ?? null,
    filterName: filterName ?? null,
    extensions: extensions ?? null,
  });
/** dir=null 表示用默认(系统图片文件夹/LinPlayer);effective 是实际会写入的路径。 */
export type ScreenshotDir = { dir: string | null; effective: string };
export const getScreenshotDir = () => invoke<ScreenshotDir>("get_screenshot_dir");
/** 传 null / 空串 = 恢复默认。核层会当场建目录验证可写,不可写直接报错。 */
export const setScreenshotDir = (dir: string | null) =>
  invoke<ScreenshotDir>("set_screenshot_dir", { dir });

/** 缓存占用字节数(递归统计,可能耗时几百 ms —— Rust 侧已丢阻塞线程池)。 */
export const cacheSize = () => invoke<number>("cache_size");

/** 清空缓存。只删 cache/,不碰账号/观看记录/下载/模型。 */
export const clearCache = () => invoke<void>("clear_cache");

/** 在系统文件管理器里打开数据目录。 */
export const openDataDir = (sub?: "logs" | "downloads") =>
  invoke<void>("open_data_dir", { sub });

/* 字节格式化用现成的 fmtSize(本文件上方) —— 别再写一个。
   它对 0 返回空串,占用为 0 时调用点自己 `|| "0 B"`。 */
