/* One-shot generator for seamless animated glitter tiles (Y2K blinkie style).
   Outputs 3 frames; cycling them in CSS makes the sparkles twinkle in place,
   exactly like an old animated-GIF glitter background. Run with node. */
const fs = require('fs');
const path = require('path');

const N = 160; // tile size (px) — large enough that the repeat grid is not obvious
let seed = 1357924680;
function rnd() { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; }
function pick(a) { return a[Math.floor(rnd() * a.length)]; }

// saturated Y2K glitter palette, white-heavy
const cols = ['#ffffff', '#ffffff', '#ffffff', '#ffe1f4', '#ff79c6', '#5fe6ff', '#ffe23b', '#c89bff', '#ff2f9a', '#9bff8f'];

const M = 6;
const COUNT = 54;
const anchors = [];
for (let i = 0; i < COUNT; i++) {
  anchors.push({
    x: +(M + rnd() * (N - 2 * M)).toFixed(1),
    y: +(M + rnd() * (N - 2 * M)).toFixed(1),
    col: pick(cols),
    phase: Math.floor(rnd() * 3),
    big: rnd() < 0.30
  });
}

function star(x, y, s, col, op) {
  const i = (s * 0.26).toFixed(2);
  const pts = `${x},${(y - s).toFixed(1)} ${(x + +i).toFixed(1)},${(y - +i).toFixed(1)} ${(x + s).toFixed(1)},${y} ${(x + +i).toFixed(1)},${(y + +i).toFixed(1)} ${x},${(y + s).toFixed(1)} ${(x - +i).toFixed(1)},${(y + +i).toFixed(1)} ${(x - s).toFixed(1)},${y} ${(x - +i).toFixed(1)},${(y - +i).toFixed(1)}`;
  const arm = (s * 1.6).toFixed(1);
  return `<polygon points="${pts}" fill="${col}" opacity="${op}"/>` +
    `<rect x="${(x - +arm).toFixed(1)}" y="${(y - 0.55).toFixed(1)}" width="${(arm * 2)}" height="1.1" fill="${col}" opacity="${(op * 0.5).toFixed(2)}"/>` +
    `<rect x="${(x - 0.55).toFixed(1)}" y="${(y - +arm).toFixed(1)}" width="1.1" height="${(arm * 2)}" fill="${col}" opacity="${(op * 0.5).toFixed(2)}"/>`;
}
function dot(x, y, s, col, op) {
  return `<rect x="${(x - s / 2).toFixed(1)}" y="${(y - s / 2).toFixed(1)}" width="${s}" height="${s}" fill="${col}" opacity="${op}"/>`;
}

for (let f = 0; f < 3; f++) {
  let body = '';
  for (const a of anchors) {
    const dist = Math.min((a.phase - f + 3) % 3, (f - a.phase + 3) % 3);
    let op, size, big;
    if (dist === 0) { op = 1; size = a.big ? 6 : 3.4; big = true; }
    else if (dist === 1) { op = 0.5; size = a.big ? 3.2 : 2.1; big = true; }
    else { op = 0.18; size = 1.6; big = false; }
    body += big ? star(a.x, a.y, size, a.col, op) : dot(a.x, a.y, size, a.col, op);
  }
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${N}" height="${N}" viewBox="0 0 ${N} ${N}">${body}</svg>`;
  fs.writeFileSync(path.join(__dirname, '..', 'source', 'img', `glitter-${f + 1}.svg`), svg);
}
console.log('wrote glitter-1/2/3.svg', COUNT, 'sparkles each');
