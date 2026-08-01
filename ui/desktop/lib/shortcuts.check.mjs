/* 快捷键表的不变量自检(纯逻辑,不需要浏览器)。
 *
 * 跑法:node --experimental-strip-types ui/desktop/lib/shortcuts.check.mjs
 *
 * ## 为什么值得测这几条
 * 鼠标手势是「登记在表里让用户看得见,但实现不在 dispatch 里」的特殊条目。这种双轨结构
 * 很容易被后来的人破坏,而且**破坏了不报错**:
 *   - 新加一条鼠标手势忘了 `fixed:true` → 设置页给它渲染出「改键」按钮,
 *     用户点了、录了一个真键位进去,而那个键位永远不会触发任何东西(实现只认鼠标事件);
 *   - `mouse:` 伪 combo 忘了配显示名 → 设置页把 "mouse:rhold" 这种内部字符串直接摆给用户看;
 *   - 哪天有人给鼠标条目配了个真键位 → 它会和键盘命令抢 combo,而冲突检测本来是能发现的,
 *     只是没人看这份表。
 *
 * ## 纪律
 * 断言必须先红过(见 [[test-must-fail-first]])。实测:
 *   去掉 m-mute 的 fixed        → 第 1 条红
 *   MOUSE_LABEL 删掉 mouse:mid  → 第 4 条红
 */
import { COMMANDS, comboLabel, conflicts, allBindings } from "./shortcuts.ts";

let bad = 0;
const ok = (cond, msg) => {
  console.log(`${cond ? "  ok" : "FAIL"}  ${msg}`);
  if (!cond) bad++;
};

const mouse = COMMANDS.filter((c) => c.group === "鼠标");
const fixed = COMMANDS.filter((c) => c.fixed);

ok(mouse.length > 0 && mouse.every((c) => c.fixed), `「鼠标」组 ${mouse.length} 条全部 fixed`);
ok(
  fixed.every((c) => c.keys.every((k) => k.startsWith("mouse:"))),
  "fixed 条目的 keys 全是 mouse: 伪 combo(配了真键位=那个键永远不触发)",
);
ok(
  fixed.every((c) => c.group === "鼠标"),
  "fixed 只出现在「鼠标」组",
);

/* 显示名:漏配就会把内部字符串摆给用户看。
   ★ 判据是「结果里还带 mouse: 字样」,不能写 comboLabel(k) === k ——
     缺映射时会掉进通用分支被 toUpperCase 成 "MOUSE:MID",和原串不相等,断言恒真(实测过)。 */
const unlabeled = fixed.flatMap((c) => c.keys).filter((k) => /mouse:/i.test(comboLabel(k)));
ok(unlabeled.length === 0, `每个 mouse: combo 都有中文显示名(缺:${unlabeled.join(", ") || "无"})`);

// 伪 combo 不可能和真键位撞 —— 撞了说明有人把 mouse: 写进了键盘命令。
const kbd = new Set(COMMANDS.filter((c) => !c.fixed).flatMap((c) => c.keys));
const clash = fixed.flatMap((c) => c.keys).filter((k) => kbd.has(k));
ok(clash.length === 0, `mouse: 伪 combo 不与键盘键位重合(撞:${clash.join(", ") || "无"})`);
ok(![...conflicts()].some((k) => k.startsWith("mouse:")), "冲突检测不会把鼠标手势报成冲突");

// id 唯一 —— 重了的话 BY_ID 只留后一条,前一条的注册永远轮不到,而且不报错。
const ids = COMMANDS.map((c) => c.id);
ok(new Set(ids).size === ids.length, `命令 id 唯一(${ids.length} 条)`);
ok(allBindings().every(({ keys }) => Array.isArray(keys)), "allBindings() 每条都有 keys 数组");

console.log(bad === 0 ? "\n全部通过" : `\n${bad} 条失败`);
process.exit(bad === 0 ? 0 : 1);
