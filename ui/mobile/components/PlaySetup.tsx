import { useEffect, useMemo, useState } from "react";
import {
  type MediaVersion,
  type StreamInfo,
  defaultVersion,
  fmtBitrate,
  fmtRes,
  fmtSize,
  itemMedia,
  listAccounts,
  probeLine,
  setActiveLine,
} from "@shared/api";
import { haptic, toast } from "../app/motion";
import { setPrePick } from "../app/prepick";
import Sheet from "./Sheet";
import { Opt } from "./ui";

/* 播放前的四件事:**版本 / 线路 / 音频 / 字幕**。
   用户 2026-08-02:「无论是单集详情页还是电影详情页,目前都缺失了这些核心控制功能,
   这些都是用户播放前必须要选的」。

   ## 为什么以前只在播放页里
   因为那是 mpv 的地盘:音轨/字幕的真值在 mpv 的 track-list 上。
   但那意味着用户必须**先播错一次**,进 OSD 面板改,再等一次起播缓冲 ——
   字幕多的片子(实测有的片 11 条字幕)每次都要这么走一趟。

   ## 这一版怎么做到"播之前就能选"
   - **版本**:`item_media` 直接给,选完把 mediaSourceId 传给 `play()` —— 完全在起播之前。
   - **线路**:`set_active_line` 是账号级的开关,也在起播之前。
     ★ 顺手对每条线路发一次 `probe_line`,把延迟写在选项右边 ——
       "选最流畅的线路"没有延迟数字就是抓阄。
   - **音频 / 字幕**:候选来自 Emby 的 MediaStreams(和播放器面板同一份内容),
     但**生效**只能等 mpv demux 完。所以这里只记意图(见 app/prepick.ts),
     播放页在轨表稳定后照着执行。

   ## 不画点不动的东西
   只有一个版本 / 只有一条线路 / 只有一条音轨时,那颗胶囊**不画**。
   摆一个灰着按不动的按钮比不摆更糟 —— 它会让人一直以为是自己没找对地方。 */

type Props = {
  /** 真正会播的那个条目(剧集页传"会播的那一集",不是剧本身 —— 剧没有媒体流) */
  itemId?: string | null;
  /** 用户挑过版本没有。挑过才把 id 传给 play():
   *  不传的话核层走版本筛选正则,那是**默认且正确**的行为。 */
  onVersion: (versionId: string | null) => void;
};

const langOf = (s: StreamInfo) =>
  s.display_title || [s.language, s.codec?.toUpperCase()].filter(Boolean).join(" · ") || "未命名";

export default function PlaySetup({ itemId, onVersion }: Props) {
  const [versions, setVersions] = useState<MediaVersion[]>([]);
  const [ver, setVer] = useState<MediaVersion | null>(null);
  const [verPicked, setVerPicked] = useState(false);
  const [lines, setLines] = useState<{ name: string }[]>([]);
  const [lineIdx, setLineIdx] = useState(0);
  const [pings, setPings] = useState<Record<number, number | null>>({});
  const [server, setServer] = useState<string | null>(null);
  const [audio, setAudio] = useState<number | null>(null);
  const [sub, setSub] = useState<number | null>(null);
  const [open, setOpen] = useState<null | "ver" | "line" | "audio" | "sub">(null);

  useEffect(() => {
    if (!itemId) return;
    let alive = true;
    setVer(null);
    setVerPicked(false);
    setAudio(null);
    setSub(null);
    itemMedia(itemId)
      .then((v) => {
        if (!alive) return;
        setVersions(v);
        // 显示正则**会**挑中的那条,不是列表第一条 —— 高亮错了等于告诉用户"设置没生效"
        setVer(defaultVersion(v));
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [itemId]);

  /* 线路。★ 逐条 probe,不用整表 probe_lines —— 后者要等最慢那条(最坏 6s)
     才一起返回,一条死线就把整排延迟数字扣住。 */
  useEffect(() => {
    let alive = true;
    listAccounts()
      .then((as) => {
        const me = as.find((a) => a.active) ?? as[0];
        if (!me || !alive) return;
        setServer(me.server);
        setLines(me.lines.map((l) => ({ name: l.name })));
        setLineIdx(me.active_line);
        me.lines.forEach((_, i) =>
          probeLine(me.server, i)
            .then((p) => alive && setPings((m) => ({ ...m, [p.index]: p.ms })))
            .catch(() => alive && setPings((m) => ({ ...m, [i]: null }))),
        );
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, []);

  const audios = useMemo(() => (ver?.streams ?? []).filter((s) => s.type_ === "Audio"), [ver]);
  const subs = useMemo(() => (ver?.streams ?? []).filter((s) => s.type_ === "Subtitle"), [ver]);

  /* 意图往外交接。★ 每次变都写一遍,而不是等点播放时才写 ——
     播放按钮在这个组件**外面**(它是页面的主按钮),这里拿不到那个时刻。 */
  useEffect(() => {
    setPrePick({ audio, sub });
  }, [audio, sub]);
  useEffect(() => {
    onVersion(verPicked ? (ver?.id ?? null) : null);
  }, [verPicked, ver, onVersion]);

  const chips: { id: "ver" | "line" | "audio" | "sub"; label: string; value: string; off?: boolean }[] = [];
  if (versions.length > 1) {
    chips.push({ id: "ver", label: "版本", value: ver?.name ?? "自动", off: !verPicked });
  }
  if (lines.length > 1) {
    chips.push({ id: "line", label: "线路", value: lines[lineIdx]?.name ?? `线路 ${lineIdx + 1}` });
  }
  if (audios.length > 1) {
    chips.push({
      id: "audio",
      label: "音频",
      value: audio == null ? "自动" : langOf(audios[audio]),
      off: audio == null,
    });
  }
  if (subs.length > 0) {
    chips.push({
      id: "sub",
      label: "字幕",
      value: sub == null ? "自动" : sub < 0 ? "关闭" : langOf(subs[sub]),
      off: sub == null,
    });
  }
  if (!chips.length) return null;

  return (
    <>
      <div className="ps-bar">
        {chips.map((c) => (
          <button
            key={c.id}
            type="button"
            className={`ps-chip${c.off ? " off" : ""}`}
            onClick={() => {
              haptic("sel");
              setOpen(c.id);
            }}
          >
            <i>{c.label}</i>
            <b>{c.value}</b>
          </button>
        ))}
      </div>

      <Sheet open={open === "ver"} onClose={() => setOpen(null)} title="选择版本" snap>
        <div className="opts">
          {versions.map((v, i) => (
            <Opt
              key={v.id}
              i={i}
              on={verPicked && v.id === ver?.id}
              label={v.name}
              sub={[
                fmtRes(v.streams?.find((s) => s.type_ === "Video")?.height ?? null),
                fmtSize(v.size_bytes ?? 0),
                v.container?.toUpperCase(),
                fmtBitrate(v.bitrate),
              ]
                .filter(Boolean)
                .join(" · ")}
              onClick={() => {
                setVer(v);
                setVerPicked(true);
                /* 换版本 = 换了一份流表,原来选的第 N 条音轨/字幕在新版本里可能压根不存在。
                   清掉比"沿用一个可能对不上的序号"安全 —— 后者是静默播错轨。 */
                setAudio(null);
                setSub(null);
                haptic("sel");
                setOpen(null);
              }}
            />
          ))}
        </div>
      </Sheet>

      <Sheet open={open === "line"} onClose={() => setOpen(null)} title="选择线路" snap>
        <div className="opts">
          {lines.map((l, i) => (
            <Opt
              key={i}
              i={i}
              on={i === lineIdx}
              label={l.name || `线路 ${i + 1}`}
              /* ★ 只写延迟,**不写地址**(用户 2026-08-02:「任何地方都不要展示具体的线路地址」)。 */
              sub={pings[i] === undefined ? "测速中…" : pings[i] === null ? "连不上" : `${pings[i]} ms`}
              onClick={() => {
                if (!server) return;
                const prev = lineIdx;
                setLineIdx(i);
                setOpen(null);
                haptic("sel");
                setActiveLine(server, i)
                  .then(() => toast(`已切到 ${l.name || `线路 ${i + 1}`}`, "ok"))
                  .catch((e) => {
                    setLineIdx(prev); // 切失败要**退回去**,否则界面在说谎
                    toast(String(e), "bad");
                  });
              }}
            />
          ))}
        </div>
      </Sheet>

      <Sheet open={open === "audio"} onClose={() => setOpen(null)} title="音频" snap>
        <div className="opts">
          <Opt
            i={0}
            on={audio == null}
            label="自动"
            sub="按设置里的音频正则 / 首选语言挑"
            onClick={() => {
              setAudio(null);
              setOpen(null);
            }}
          />
          {audios.map((s, i) => (
            <Opt
              key={i}
              i={i + 1}
              on={audio === i}
              label={langOf(s)}
              sub={[s.codec?.toUpperCase(), s.channels ? `${s.channels}ch` : null].filter(Boolean).join(" · ")}
              onClick={() => {
                setAudio(i);
                haptic("sel");
                setOpen(null);
              }}
            />
          ))}
        </div>
      </Sheet>

      <Sheet open={open === "sub"} onClose={() => setOpen(null)} title="字幕" snap>
        <div className="opts">
          <Opt
            i={0}
            on={sub == null}
            label="自动"
            sub="按设置里的字幕正则 / 首选语言挑"
            onClick={() => {
              setSub(null);
              setOpen(null);
            }}
          />
          <Opt
            i={1}
            on={sub === -1}
            label="关闭字幕"
            onClick={() => {
              setSub(-1);
              haptic("sel");
              setOpen(null);
            }}
          />
          {subs.map((s, i) => (
            <Opt
              key={i}
              i={i + 2}
              on={sub === i}
              label={langOf(s)}
              sub={[s.codec?.toUpperCase(), s.is_external ? "外挂" : "内封"].filter(Boolean).join(" · ")}
              onClick={() => {
                setSub(i);
                haptic("sel");
                setOpen(null);
              }}
            />
          ))}
        </div>
      </Sheet>
    </>
  );
}
