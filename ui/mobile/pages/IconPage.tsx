import { useEffect, useMemo, useRef, useState } from "react";
import {
  type AccountInfo,
  type IconEntry,
  accountIcon,
  clearAccountIcon,
  iconLibrary,
  listAccounts,
  updateAccount,
} from "@shared/api";
import { useCtx } from "../app/ctx";
import { Icon } from "../app/icons";
import { haptic, toast } from "../app/motion";
import Page from "../components/Page";
import { Empty } from "../components/ui";
import { Field } from "../components/SourceForm";
import { isGlyph } from "./ServersPage";

/* 更换服务器图标。三个页签:内置字形 / 图标库 / 图片地址。

   ★ 图标三形态共用**一个字符串字段**(和 Rust `Account.icon_url` 一致):
     内置字形(1~2 个字符、不含路径符号)/ 图片地址 / 空(用源类型默认图标)。
     **别在手机端另发明一个 iconType 字段。**

   ★ 图标库有约 1468 项。PC 端铺 6 列硬滚 —— 在 390px 宽的手机上那是 245 屏。
     所以这里:**搜索框优先** + 5 列 + 分批 60 个渲染。
     不分批的话一次挂 1468 个 <img> 进 DOM,光是布局就够卡一下。 */

const GLYPHS = ["▣", "☐", "▦", "◆", "★", "♪", "▶", "⌘", "◈", "⬡", "✦", "◐", "❄", "▲", "◍", "✚", "❖", "⬟", "◑", "⬢"];
const BATCH = 60;

export default function IconPage({ serverId }: { serverId?: string }) {
  const { back } = useCtx();
  const [acc, setAcc] = useState<AccountInfo | null>(null);
  const [tab, setTab] = useState<"glyph" | "lib" | "url">("glyph");
  const [lib, setLib] = useState<IconEntry[] | null>(null);
  const [q, setQ] = useState("");
  const [shown, setShown] = useState(BATCH);
  const [url, setUrl] = useState("");
  const [preview, setPreview] = useState<string | null>(null);
  const sentinel = useRef<HTMLDivElement>(null);

  useEffect(() => {
    listAccounts()
      .then((as) => {
        const me = as.find((a) => a.server === serverId) ?? as.find((a) => a.active) ?? as[0];
        setAcc(me ?? null);
        if (me?.icon_url && !isGlyph(me.icon_url)) {
          setUrl(me.icon_url);
          accountIcon(me.server).then(setPreview).catch(() => {});
        }
      })
      .catch((e) => toast(String(e), "bad"));
  }, [serverId]);

  useEffect(() => {
    if (tab !== "lib" || lib) return;
    iconLibrary().then(setLib).catch((e) => {
      setLib([]);
      toast(`图标库拉不下来:${e}`, "bad");
    });
  }, [tab, lib]);

  const hits = useMemo(() => {
    const s = q.trim().toLowerCase();
    const all = lib ?? [];
    return s ? all.filter((x) => x.name.toLowerCase().includes(s)) : all;
  }, [lib, q]);

  useEffect(() => setShown(BATCH), [q, tab]);

  /* 触底再放 60 个。用 IntersectionObserver 而不是监听 scroll —— 同 LibraryPage。 */
  useEffect(() => {
    const el = sentinel.current;
    if (!el || tab !== "lib" || shown >= hits.length) return;
    const io = new IntersectionObserver((es) => es[0].isIntersecting && setShown((n) => n + BATCH), { threshold: 0.1 });
    io.observe(el);
    return () => io.disconnect();
  }, [tab, shown, hits.length]);

  const apply = (iconUrl: string) => {
    if (!acc) return;
    haptic("sel");
    updateAccount(acc.server, { iconUrl })
      .then(() => {
        toast("图标已换", "ok");
        setAcc({ ...acc, icon_url: iconUrl });
        if (isGlyph(iconUrl)) setPreview(null);
        else accountIcon(acc.server).then(setPreview).catch(() => setPreview(null));
      })
      .catch((e) => toast(String(e), "bad"));
  };

  if (!acc) return <Page title="更换图标" onBack={back}><div className="pad dim" style={{ fontSize: 13 }}>加载中…</div></Page>;

  return (
    <Page title="更换图标" sub={acc.name} onBack={back}>
      {/* 实时预览 —— 挑图标最要紧的就是"换上去长什么样" */}
      <div className="ico-prev">
        <span className="lit-ic" style={{ width: 56, height: 56 }}>
          {preview ? (
            <img className="srv-ic-img" src={preview} alt="" />
          ) : isGlyph(acc.icon_url) ? (
            <span className="srv-gly" style={{ fontSize: 26 }}>{acc.icon_url}</span>
          ) : (
            <Icon n="server" size={26} />
          )}
        </span>
        <div>
          <div className="lit-n">{acc.name}</div>
          <div className="lit-s">{acc.icon_url ? "已自定义" : "用源类型默认图标"}</div>
        </div>
        {acc.icon_url && (
          <button
            type="button"
            className="btn"
            onClick={() => {
              clearAccountIcon(acc.server)
                .then(() => {
                  setAcc({ ...acc, icon_url: null });
                  setPreview(null);
                  toast("已恢复默认图标", "ok");
                })
                .catch((e) => toast(String(e), "bad"));
            }}
          >
            恢复默认
          </button>
        )}
      </div>

      <div className="chips">
        {(["glyph", "lib", "url"] as const).map((t) => (
          <button
            key={t}
            type="button"
            className={`chip${tab === t ? " on" : ""}`}
            onClick={() => {
              haptic("sel");
              setTab(t);
            }}
          >
            {t === "glyph" ? "内置字形" : t === "lib" ? "图标库" : "图片地址"}
          </button>
        ))}
      </div>

      {tab === "glyph" && (
        <div className="ico-grid">
          {GLYPHS.map((g) => (
            <button
              key={g}
              type="button"
              className={`ico-it${acc.icon_url === g ? " on" : ""}`}
              onClick={() => apply(g)}
            >
              <span style={{ fontSize: 22 }}>{g}</span>
            </button>
          ))}
        </div>
      )}

      {tab === "lib" && (
        <>
          {/* ★ 搜索框在最上面:1468 项靠滚是找不到的 */}
          <div className="search-wrap">
            <div className="sf">
              <Icon n="search" size={18} />
              <input
                type="search"
                placeholder="搜图标名,比如 群晖 / plex / emby"
                value={q}
                onChange={(e) => setQ(e.target.value)}
              />
            </div>
          </div>
          {lib === null ? (
            <div className="pad dim" style={{ fontSize: 13 }}>正在拉图标库…</div>
          ) : !hits.length ? (
            <Empty
              icon="image"
              title={q ? `没有叫「${q}」的图标` : "图标库是空的"}
              desc={q ? "换个词试试 —— 很多图标用的是英文名。" : "图标库要联网拉一次索引,检查一下网络。"}
            />
          ) : (
            <>
              <div className="lp-total">
                {q ? `匹配 ${hits.length} 个` : `共 ${hits.length} 个`}
              </div>
              <div className="ico-grid">
                {hits.slice(0, shown).map((x) => (
                  <button
                    key={x.url}
                    type="button"
                    className={`ico-it${acc.icon_url === x.url ? " on" : ""}`}
                    title={x.name}
                    onClick={() => apply(x.url)}
                  >
                    <img src={x.url} alt={x.name} loading="lazy" decoding="async" />
                  </button>
                ))}
              </div>
              {shown < hits.length && (
                <div className="lp-more" ref={sentinel}>
                  <Icon n="refresh" size={15} className="spin-ic" />
                  再来 {Math.min(BATCH, hits.length - shown)} 个…
                </div>
              )}
            </>
          )}
        </>
      )}

      {tab === "url" && (
        <div className="pad">
          {/* ★ 这里**不做**「从本机相册选」:那要走安卓的 SAF,是另一套交互,
              而且 `set_account_icon_file` 收的是**本地文件路径** ——
              手机上没有稳定的文件路径概念(内容 URI 不是路径)。说清楚,别做半截。 */}
          <Field
            label="图片地址"
            type="url"
            placeholder="https://example.com/icon.png"
            value={url}
            onChange={setUrl}
          />
          <p className="f-note">
            填一个图片直链。核层会下载并缓存成 data URI,之后离线也显示得出来。
            <br />
            从相册选图这条路要走安卓的 SAF,还没接 —— 可以先把图传到任意图床再填地址。
          </p>
          <button
            type="button"
            className="btn primary"
            disabled={!url.trim()}
            onClick={() => apply(url.trim())}
          >
            用这张图
          </button>
        </div>
      )}
    </Page>
  );
}
