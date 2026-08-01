import { type MediaVersion, type StreamInfo, fmtBitrate, fmtRes, fmtSize } from "@shared/api";

/* 媒体信息卡 —— 平铺,**不做点击展开**(用户 2026-08-01 点名)。

   ## 为什么不再是「点开一个面板」
   上一版是详情页里一行「媒体信息 ›」,点开是个 bottom sheet。三个问题:
     1. 它是这一页唯一需要二次点击才能看到的信息,而它恰恰是最不需要交互的东西 —— 纯只读。
     2. 面板一开就盖住海报和播放按钮,看完还要关。
     3. 底部弹窗那排按钮会被悬浮底栏挡住(这次一并废掉了 bottom sheet)。
   Emby 官方客户端的做法是**直接铺在详情页最下面**:一屏之内扫完,不点任何东西。

   ## 排版口径
   左键右值两列。每一行的主标题优先用服务端的 `DisplayTitle` ——
   实测它已经是人话("English TRUEHD 7.1"、"Chinese AC3 stereo (默认)"),自己拼拼不过它。 */

type Props = {
  ver: MediaVersion | null;
  /** 多版本时给一个切换入口(只有一版就别画,那是个按了没意义的按钮) */
  onPickVersion?: () => void;
  versionCount?: number;
};

const KV = ({ k, v }: { k: string; v: React.ReactNode }) =>
  v ? (
    <div className="mkv">
      <span className="mkv-k">{k}</span>
      <span className="mkv-v">{v}</span>
    </div>
  ) : null;

/** 视频流的一行行规格。HDR/杜比这类"能不能好好播"的信息排在前面。 */
function videoRows(s: StreamInfo) {
  return (
    <>
      <KV k="分辨率" v={s.width && s.height ? `${s.width}×${s.height}` : fmtRes(s.height)} />
      <KV k="编码" v={s.codec?.toUpperCase()} />
      <KV k="动态范围" v={s.video_range_type || s.video_range} />
      <KV k="帧率" v={s.frame_rate ? `${s.frame_rate.toFixed(3)} fps` : ""} />
      <KV k="码率" v={fmtBitrate(s.bitrate)} />
    </>
  );
}

function audioRow(s: StreamInfo) {
  return [s.codec?.toUpperCase(), s.channel_layout, fmtBitrate(s.bitrate)]
    .filter(Boolean)
    .join(" · ");
}

export default function MediaCard({ ver, onPickVersion, versionCount = 1 }: Props) {
  if (!ver) {
    return (
      <div className="mcard">
        <div className="mcard-empty">服务器没给这一版的媒体信息。</div>
      </div>
    );
  }
  const vid = ver.streams?.find((s) => s.type_ === "Video") ?? null;
  const auds = (ver.streams ?? []).filter((s) => s.type_ === "Audio");
  const subs = (ver.streams ?? []).filter((s) => s.type_ === "Subtitle");

  /* 顶部一排规格标签:分辨率 / 动态范围 / 编码 / 容器 / 大小。
     这是"扫一眼就知道这文件是什么"的那一行,底下的键值对是给要细看的人的。 */
  const chips = [
    fmtRes(vid?.height ?? null),
    vid?.video_range_type || vid?.video_range || "",
    vid?.codec?.toUpperCase() ?? "",
    ver.container?.toUpperCase() ?? "",
    fmtSize(ver.size_bytes ?? 0),
  ].filter(Boolean);

  return (
    <div className="mcard">
      {chips.length > 0 && (
        <div className="mcard-chips">
          {chips.map((c) => (
            <b key={c}>{c}</b>
          ))}
          {versionCount > 1 && onPickVersion && (
            <button type="button" className="mcard-ver" onClick={onPickVersion}>
              {versionCount} 个版本 · 切换
            </button>
          )}
        </div>
      )}

      {vid && (
        <div className="mcard-sec">
          <h3>视频</h3>
          {videoRows(vid)}
        </div>
      )}

      {auds.length > 0 && (
        <div className="mcard-sec">
          <h3>音频</h3>
          {auds.map((s) => (
            <KV
              key={s.index}
              k={s.display_title || s.codec || `音轨 ${s.index}`}
              v={audioRow(s)}
            />
          ))}
        </div>
      )}

      {subs.length > 0 && (
        <div className="mcard-sec">
          <h3>字幕</h3>
          {subs.map((s) => (
            <KV
              key={s.index}
              k={s.display_title || s.codec || `字幕 ${s.index}`}
              /* 内封 / 外挂是**真会影响能不能显示**的信息(外挂要额外挂载),
                 所以它不是可有可无的装饰。 */
              v={[s.codec?.toUpperCase(), s.is_external ? "外挂" : "内封"].filter(Boolean).join(" · ")}
            />
          ))}
        </div>
      )}

      <div className="mcard-sec">
        <h3>文件</h3>
        <KV k="容器" v={ver.container?.toUpperCase()} />
        <KV k="大小" v={fmtSize(ver.size_bytes ?? 0)} />
        <KV k="总码率" v={fmtBitrate(ver.bitrate ?? null)} />
      </div>
    </div>
  );
}
