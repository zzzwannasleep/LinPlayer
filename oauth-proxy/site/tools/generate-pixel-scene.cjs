/* One-shot generator for the Y2K Blingee pixel scene (run with node, output committed).
   Builds a low-res dot-matrix grid, dithers the gradients with a Bayer matrix for that
   early-digital look, then layers glow + sparkle bling on top. */
const fs = require('fs');

const S = 18, COLS = 90, ROWS = 56, W = COLS * S, H = ROWS * S;

let seed = 20260618;
function rnd() { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; }
function chance(p) { return rnd() < p; }
function pick(a) { return a[Math.floor(rnd() * a.length)]; }
function pickW(pairs) { let t = 0; for (const [, w] of pairs) t += w; let x = rnd() * t; for (const [v, w] of pairs) { if ((x -= w) <= 0) return v; } return pairs[0][0]; }

const bayer = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]];
function dither(c, r, f) { return f > (bayer[((r % 4) + 4) % 4][((c % 4) + 4) % 4] + 0.5) / 16; }

const grid = Array.from({ length: ROWS }, () => Array(COLS).fill(null));
function set(c, r, col) { c = Math.round(c); r = Math.round(r); if (c >= 0 && c < COLS && r >= 0 && r < ROWS) grid[r][c] = col; }
function get(c, r) { return (r >= 0 && r < ROWS && c >= 0 && c < COLS) ? grid[r][c] : null; }

/* ---- SKY: saturated azure -> cyan -> pink -> peach, dithered ---- */
const sky = [
  { r: 0, c: '#1f8bf0' }, { r: 8, c: '#3ea6f7' }, { r: 15, c: '#74c9fb' },
  { r: 21, c: '#bce8ff' }, { r: 27, c: '#ffbbe2' }, { r: 34, c: '#ffd2bd' }
];
const skySet = new Set(sky.map(s => s.c));
function skyAt(c, r) {
  for (let i = 0; i < sky.length - 1; i++) if (r >= sky[i].r && r <= sky[i + 1].r) {
    const f = (r - sky[i].r) / (sky[i + 1].r - sky[i].r);
    return dither(c, r, f) ? sky[i + 1].c : sky[i].c;
  }
  return sky[sky.length - 1].c;
}
for (let r = 0; r < ROWS; r++) for (let c = 0; c < COLS; c++) set(c, r, skyAt(c, r));

/* ---- RAINBOW: chunky stepped arc (behind hills) ---- */
const rain = ['#ff2f6e', '#ff7a1f', '#ffd62b', '#37cf4a', '#1f9eff', '#a64dff'];
const rainLt = ['#ff6f99', '#ffa861', '#ffe879', '#74e081', '#69bfff', '#c489ff'];
{
  const cx = 41, cy = 52, rOut = 36;
  for (let c = 0; c < COLS; c++) {
    const dx = c - cx, ins = rOut * rOut - dx * dx;
    if (ins > 0) {
      const yt = cy - Math.sqrt(ins);
      for (let b = 0; b < 6; b++) {
        const r = Math.round(yt) + b;
        // dither a lighter inner edge for a glossy band
        set(c, r, dither(c, r, 0.7) ? rain[b] : rainLt[b]);
      }
    }
  }
}

/* ---- SUN: pixel disc + dithered corona ---- */
const sun = { cx: 70, cy: 10, r: 7 };
for (let r = 0; r < ROWS; r++) for (let c = 0; c < COLS; c++) {
  const d = Math.hypot(c - sun.cx, r - sun.cy);
  if (d <= sun.r) set(c, r, d < 2.4 ? '#fff7b4' : d < 4 ? '#ffe23b' : d < 5.4 ? '#ffcf24' : '#ffb71c');
}
for (let r = 0; r < ROWS; r++) for (let c = 0; c < COLS; c++) {
  const d = Math.hypot(c - sun.cx, r - sun.cy);
  if (d > sun.r && d < sun.r + 3 && dither(c, r, (sun.r + 3 - d) / 3)) set(c, r, chance(0.5) ? '#ffe23b' : '#fff2a0');
}

/* ---- CLOUDS: blocky white with dithered cyan underside ---- */
function cloud(ox, oy, w) {
  const rows = [[0, 0, w, 2], [-2, 2, w + 4, 2], [-1, 4, w + 2, 1]];
  for (const [bx, by, bw, bh] of rows) for (let i = 0; i < bw; i++) for (let j = 0; j < bh; j++) {
    const r = oy + by + j;
    set(ox + bx + i, r, (j === bh - 1 && dither(ox + bx + i, r, 0.5)) ? '#c7ecff' : '#ffffff');
  }
}
cloud(22, 7, 8); cloud(50, 4, 7); cloud(9, 14, 6); cloud(40, 17, 5);

/* ---- HILLS: layered, dithered tops + speckle texture + a pond ---- */
function wave(base, amp, ph, c, fr) { return base + Math.round(amp * Math.sin(c * fr + ph)); }
const layers = [
  { topB: 34, amp: 2, ph: 0.0, fr: 0.20, base: '#67c93f', light: '#85dd5c', dark: '#4fae31' },
  { topB: 38, amp: 2, ph: 1.1, fr: 0.17, base: '#4cb734', light: '#69cc4c', dark: '#3a9826' },
  { topB: 44, amp: 2, ph: 2.2, fr: 0.26, base: '#359327', light: '#4fab38', dark: '#287a1d' }
];
for (const L of layers) for (let c = 0; c < COLS; c++) {
  const top = wave(L.topB, L.amp, L.ph, c, L.fr);
  for (let r = top; r < ROWS; r++) {
    let col = L.base; const near = r - top;
    if (near < 2 && dither(c, r, 0.5)) col = L.light;
    else if (chance(0.10)) col = L.light;
    else if (chance(0.06)) col = L.dark;
    set(c, r, col);
  }
}
// pond bottom-center with dithered cyan + reflected rainbow shimmer
{
  const pondTop = 50;
  for (let r = pondTop; r < ROWS; r++) for (let c = 30; c < 64; c++) {
    const edge = (c < 33 || c > 60);
    if (edge && chance(0.6)) continue;
    let col = dither(c, r, 0.5) ? '#3fc7e8' : '#7ee0f4';
    if (chance(0.08)) col = pick(rainLt);
    if (chance(0.05)) col = '#ffffff';
    set(c, r, col);
  }
}

/* ---- CHERRY TREES: trunk + dense dithered blossom canopy ---- */
function tree(cxc) {
  const tb = wave(layers[2].topB, 2, 2.2, cxc, 0.26);
  for (let r = 20; r < tb + 2; r++) for (let c = cxc - 1; c <= cxc + 1; c++) {
    set(c, r, chance(0.28) ? '#5a3418' : '#7c4a26');
  }
  // a couple of branches
  for (let i = 0; i < 4; i++) set(cxc - 2 - i, 24 + i, '#7c4a26');
  for (let i = 0; i < 4; i++) set(cxc + 2 + i, 23 + i, '#7c4a26');
  const ccx = cxc, ccy = 15, rx = 8, ry = 7.5;
  for (let r = ccy - ry - 1; r <= ccy + ry; r++) for (let c = ccx - rx - 1; c <= ccx + rx + 1; c++) {
    const nx = (c - ccx) / rx, ny = (r - ccy) / ry;
    if (nx * nx + ny * ny <= 1) {
      let col = pickW([['#ff4fa3', 26], ['#ff79bb', 34], ['#ffa9d2', 22], ['#ffd3ea', 18]]);
      if (chance(0.07)) col = '#ffffff';
      else if (chance(0.07)) col = '#e23184';
      set(c, r, col);
    }
  }
}
tree(7); tree(83);

/* ---- FLOWERS scattered on the grass ---- */
const greenSet = new Set(layers.flatMap(L => [L.base, L.light, L.dark]));
for (let i = 0; i < 110; i++) {
  const c = Math.floor(rnd() * COLS), r = 34 + Math.floor(rnd() * 22);
  if (greenSet.has(get(c, r))) set(c, r, pick(['#ff2f5e', '#ffffff', '#ffe23b', '#a64dff', '#ff79bb', '#ff7a1f', '#1f9eff']));
}

/* ---- stray blossom petals drifting in the lower sky ---- */
for (let i = 0; i < 40; i++) {
  const c = Math.floor(rnd() * COLS), r = 14 + Math.floor(rnd() * 20);
  if (skySet.has(get(c, r))) set(c, r, pick(['#ff79bb', '#ffa9d2', '#ffd3ea', '#ffffff']));
}

/* ===== emit grid as run-length-merged rects ===== */
let rects = '';
for (let r = 0; r < ROWS; r++) {
  let c = 0;
  while (c < COLS) {
    const col = grid[r][c];
    if (!col) { c++; continue; }
    let c2 = c; while (c2 < COLS && grid[r][c2] === col) c2++;
    rects += `<rect x="${c * S}" y="${r * S}" width="${(c2 - c) * S}" height="${S}" fill="${col}"/>`;
    c = c2;
  }
}

/* ===== overlay bling: glow halos + sparkle stars (smooth) ===== */
function star(x, y, s, fill, op) {
  const i = s * 0.16;
  const pts = `${x},${y - s} ${x + i},${y - i} ${x + s},${y} ${x + i},${y + i} ${x},${y + s} ${x - i},${y + i} ${x - s},${y} ${x - i},${y - i}`;
  return `<circle cx="${x}" cy="${y}" r="${s * 1.5}" fill="url(#spk)" opacity="${op * 0.7}"/>` +
    `<polygon points="${pts}" fill="${fill}" opacity="${op}"/>` +
    `<rect x="${x - s * 1.4}" y="${y - 1}" width="${s * 2.8}" height="2" fill="${fill}" opacity="${op * 0.5}"/>` +
    `<rect x="${x - 1}" y="${y - s * 1.4}" width="2" height="${s * 2.8}" fill="${fill}" opacity="${op * 0.5}"/>`;
}
let bling = '';
// sun corona glow
bling += `<circle cx="${sun.cx * S}" cy="${sun.cy * S}" r="${(sun.r + 9) * S}" fill="url(#sunGlow)"/>`;
// scattered sparkles across the upper scene
const spkCols = ['#ffffff', '#ffffff', '#fff2a0', '#bdefff', '#ffc8e8'];
for (let i = 0; i < 46; i++) {
  const x = Math.floor(rnd() * W);
  const y = Math.floor(rnd() * (H * 0.62));
  const s = 7 + Math.floor(rnd() * 18);
  bling += star(x, y, s, pick(spkCols), 0.55 + rnd() * 0.4);
}
// glints right on the blossom canopies
for (const tx of [7, 83]) for (let i = 0; i < 6; i++) {
  bling += star((tx + (rnd() * 16 - 8)) * S, (15 + (rnd() * 14 - 7)) * S, 6 + rnd() * 7, '#ffffff', 0.8);
}

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid slice" shape-rendering="crispEdges">
<defs>
<radialGradient id="sunGlow" cx="50%" cy="50%" r="50%">
<stop offset="0%" stop-color="#fff7b4" stop-opacity="0"/>
<stop offset="34%" stop-color="#ffe23b" stop-opacity="0.5"/>
<stop offset="64%" stop-color="#ffd62b" stop-opacity="0.22"/>
<stop offset="100%" stop-color="#ffd62b" stop-opacity="0"/>
</radialGradient>
<radialGradient id="spk" cx="50%" cy="50%" r="50%">
<stop offset="0%" stop-color="#ffffff" stop-opacity="0.95"/>
<stop offset="100%" stop-color="#ffffff" stop-opacity="0"/>
</radialGradient>
</defs>
<g>${rects}</g>
<g shape-rendering="geometricPrecision">${bling}</g>
</svg>`;

fs.writeFileSync(require('path').join(__dirname, '..', 'source', 'img', 'pixel-scene.svg'), svg);
console.log('wrote pixel-scene.svg', (svg.length / 1024).toFixed(1) + 'KB', 'rects~', (rects.match(/<rect/g) || []).length);
