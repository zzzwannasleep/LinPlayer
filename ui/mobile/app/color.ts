/* 从海报里取主色 —— 详情页背景那条向下延伸的渐变靠它。

   ## 为什么必须真去读像素,不能按 id 哈希
   首页那个 `ambientOf` 是按条目 id 哈希选一档配色的("确定性的假主色")。
   在首页成立:Hero 每 5 秒换一张,用户不会去核对颜色对不对。
   详情页不成立 —— 海报就在渐变正上方,颜色对不上一眼就看出来了。
   用户的原话是「海报主色调是红色,页面背景就延伸为红色」,那就只能真取。

   ## 三个会让它静默失效的坑
   1. **canvas 污染**:`lpimg` 和页面不同源(`http://lpimg.localhost` vs
      `http://tauri.localhost`)。没有 `Access-Control-Allow-Origin` + `crossOrigin="anonymous"`
      这一对,`getImageData` 抛 SecurityError,而 try/catch 一吞就**一点痕迹都没有**,
      表现是"渐变永远不出现"。后端那一半在 imgcache.rs。
   2. **平均色是灰的**:一张海报里深色背景占大多数,直接求平均永远得到脏灰。
      所以按色相分桶、用饱和度加权投票,取票最多的那一桶。
   3. **深色主题下不能用原色**:海报主色常常是高亮度的(明黄、亮红),
      直接铺成背景会刺眼且压过封面。取到色相/饱和度之后**把明度按主题重钉**。 */

export type Dominant = {
  /** 0~360 */
  h: number;
  /** 0~100 */
  s: number;
};

/** 色相分桶数。24 桶 = 每桶 15°,足够把"红"和"橙"分开,又不会被噪点打散。 */
const BUCKETS = 24;
/** 取样边长。16×16=256 个像素,足够投票,而且解码+绘制在手机上是微秒级。 */
const N = 16;

function rgbToHsl(r: number, g: number, b: number) {
  r /= 255;
  g /= 255;
  b /= 255;
  const mx = Math.max(r, g, b);
  const mn = Math.min(r, g, b);
  const l = (mx + mn) / 2;
  const d = mx - mn;
  if (d === 0) return { h: 0, s: 0, l };
  const s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
  let h: number;
  if (mx === r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
  else if (mx === g) h = ((b - r) / d + 2) / 6;
  else h = ((r - g) / d + 4) / 6;
  return { h: h * 360, s, l };
}

/** 从一张**已经加载完**的图里投票选主色。取不到彩色像素返回 null(整张灰的海报是有的)。 */
export function dominantOf(img: HTMLImageElement): Dominant | null {
  if (!img.naturalWidth) return null;
  let data: Uint8ClampedArray;
  try {
    const c = document.createElement("canvas");
    c.width = N;
    c.height = N;
    const ctx = c.getContext("2d", { willReadFrequently: true });
    if (!ctx) return null;
    ctx.drawImage(img, 0, 0, N, N);
    data = ctx.getImageData(0, 0, N, N).data;
  } catch {
    // 跨源污染 / 图还没解码完。**不是错误**,回落到"不画渐变"就好。
    return null;
  }

  const votes = new Float64Array(BUCKETS);
  const sumS = new Float64Array(BUCKETS);
  const cnt = new Float64Array(BUCKETS);
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] < 200) continue; // 透明像素不参与
    const { h, s, l } = rgbToHsl(data[i], data[i + 1], data[i + 2]);
    // 太灰 / 太黑 / 太白的像素没有色相信息,投了只会把结果拉回灰
    if (s < 0.18 || l < 0.1 || l > 0.9) continue;
    const b = Math.min(BUCKETS - 1, Math.floor((h / 360) * BUCKETS));
    // 权重:越饱和越算数;中等明度的像素最能代表"这张图是什么颜色"
    votes[b] += s * (1 - Math.abs(l - 0.5) * 1.2);
    sumS[b] += s;
    cnt[b]++;
  }

  let best = -1;
  let bestV = 0;
  for (let i = 0; i < BUCKETS; i++) {
    if (votes[i] > bestV) {
      bestV = votes[i];
      best = i;
    }
  }
  if (best < 0) return null;
  const h = (best + 0.5) * (360 / BUCKETS);
  const s = Math.round(Math.min(0.72, Math.max(0.34, sumS[best] / cnt[best])) * 100);
  return { h, s };
}

/** 主色 → 详情页那层背景色。★ 明度在这里**重钉**,不用海报的 ——
 *  海报的主色可能是明黄,铺成整屏背景会盖过封面本身。 */
export function washColor(d: Dominant | null, dark = true): string | null {
  if (!d) return null;
  return dark ? `hsl(${d.h.toFixed(0)} ${d.s}% 26%)` : `hsl(${d.h.toFixed(0)} ${d.s}% 84%)`;
}
