//! 弹幕 → ASS 字幕。生成好交给 mpv 的 libass 渲染。
//!
//! ## 为什么要换掉前端 Canvas
//!
//! 老实现是前端 rAF 自己画:每 250ms 从 mpv 轮询一次播放位置,帧间用
//! `performance.now()` 线性插值。**那段插值里没有倍速这个变量** —— 2x 播放时
//! 弹幕按 1x 爬,每 250ms 被真实位置一把拽回去,每秒 4 次硬跳;1x 下 `time-pos`
//! 自身的抖动同样以 4Hz 拽扯画面。用户报的「正常速度也卡、倍速更卡」就是这个,
//! 不是绘制开销(纯色滚动弹幕再多也画得动)。
//!
//! 交给 libass 之后:时间轴、倍速、seek、暂停全归 mpv 自己管,运行时**零 IPC、
//! 零 JS 计算、零透明窗口重绘**。附带好处是 mpv 的截图/录制会带上弹幕。
//!
//! ## 坐标系
//!
//! 用固定的 PlayRes(1920×1080)描述版面,libass 会自己缩放到实际画面 ——
//! 所以窗口大小变化、全屏切换都不用重新生成。
//!
//! ## 已知取舍
//!
//! 文字宽度是**估算**的(全角 1.0em / 半角 0.55em),因为核层拿不到字体度量。
//! 估宽只影响轨道分配的松紧和滚出屏幕的余量,偏差几个像素不影响观感;
//! 想精确就得把字体加载进核层,不值。

use super::DanmakuComment;

/// 生成参数。全部来自播放器弹幕面板上那几个档位。
///
/// `#[serde(default)]` 在**容器**上:前端只传它关心的那几项,其余走 Default ——
/// 免得前端硬编一份默认值,两份早晚对不上(那正是「显示的和生效的不是一回事」)。
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct AssOptions {
    /// 版面分辨率。libass 按它等比缩放到实际画面。
    pub play_res_x: i32,
    pub play_res_y: i32,
    pub font: String,
    /// 字号(以 play_res_y 为基准的 ASS 单位)。
    pub font_size: i32,
    /// 不透明度 0~100。
    pub opacity: u8,
    /// 弹幕占用画面高度的百分比(25/50/75/100),对应面板的「显示区域」。
    pub area_percent: u8,
    /// 滚动弹幕横穿屏幕的秒数,越小越快。
    pub scroll_secs: f64,
    /// 顶/底固定弹幕的停留秒数。
    pub fixed_secs: f64,
    /// 描边粗细(ASS Outline)。
    pub outline: f64,
    pub bold: bool,
}

impl Default for AssOptions {
    fn default() -> Self {
        Self {
            play_res_x: 1920,
            play_res_y: 1080,
            font: "Microsoft YaHei".into(),
            // 1080p 下 48px ≈ 老 Canvas 版 canvas.height/22 的观感,换栈不改默认观感。
            font_size: 48,
            opacity: 80,
            area_percent: 50,
            scroll_secs: 8.0,
            fixed_secs: 5.0,
            outline: 2.0,
            bold: false,
        }
    }
}

/// `H:MM:SS.cc`(ASS 只认百分秒)。
fn ts(secs: f64) -> String {
    let s = secs.max(0.0);
    let cs = (s * 100.0).round() as i64;
    let (h, m, sec, c) = (cs / 360_000, cs / 6_000 % 60, cs / 100 % 60, cs % 100);
    format!("{h}:{m:02}:{sec:02}.{c:02}")
}

/// 估算显示宽度(px)。全角字算 1 个字号宽,半角算 0.55。
fn est_width(text: &str, font_size: f64) -> f64 {
    let units: f64 = text
        .chars()
        .map(|c| if (c as u32) < 0x1100 { 0.55 } else { 1.0 })
        .sum();
    units * font_size
}

/// ASS 事件文本里的元字符。`{}` 会被当成覆盖标签的括号,`\` 会起转义,
/// 换行会截断整条 Dialogue —— 不处理的话一条含 `{` 的弹幕能把后面整行吃掉。
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '{' => out.push('('),
            '}' => out.push(')'),
            '\\' => out.push('/'),
            '\r' | '\n' => out.push(' '),
            _ => out.push(c),
        }
    }
    out
}

/// RGB int → ASS 的 `&HBBGGRR&`(ASS 是 BGR 序,写反了整片弹幕会红蓝互换)。
fn ass_color(rgb: i32) -> String {
    let v = rgb & 0xff_ffff;
    let (r, g, b) = ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
    format!("&H{b:02X}{g:02X}{r:02X}&")
}

/// 生成完整的 ASS 文件内容。`comments` 不要求有序,内部会按时间排。
pub fn to_ass(comments: &[DanmakuComment], o: &AssOptions) -> String {
    let fs = o.font_size.max(8) as f64;
    let lane_h = fs * 1.4;
    let area = (o.area_percent.clamp(10, 100) as f64) / 100.0;
    let usable_h = o.play_res_y as f64 * area;
    let lanes = ((usable_h / lane_h).floor() as usize).max(1);
    let w = o.play_res_x as f64;

    // 每条轨道的「下一次可用时刻」。滚动与顶/底各自一套(它们不互相挡)。
    let mut scroll_free = vec![f64::NEG_INFINITY; lanes];
    let mut top_free = vec![f64::NEG_INFINITY; lanes];
    let mut bottom_free = vec![f64::NEG_INFINITY; lanes];

    let mut idx: Vec<usize> = (0..comments.len()).collect();
    idx.sort_by(|&a, &b| {
        comments[a].time.partial_cmp(&comments[b].time).unwrap_or(std::cmp::Ordering::Equal)
    });

    let mut events = String::new();
    for i in idx {
        let c = &comments[i];
        let text = escape(c.text.trim());
        if text.is_empty() {
            continue;
        }
        let t = c.time.max(0.0);
        let color = ass_color(c.color);
        match c.mode {
            // 顶(5)/底(4):居中固定,停留 fixed_secs。
            4 | 5 => {
                let (free, top) = if c.mode == 5 {
                    (&mut top_free, true)
                } else {
                    (&mut bottom_free, false)
                };
                let lane = pick_lane(free, t, t + o.fixed_secs);
                // an8=上居中 / an2=下居中,\pos 给的是对应锚点的坐标。
                let (an, y) = if top {
                    (8, lane as f64 * lane_h)
                } else {
                    (2, o.play_res_y as f64 - lane as f64 * lane_h)
                };
                events.push_str(&format!(
                    "Dialogue: 0,{},{},LP,,0,0,0,,{{\\an{an}\\pos({:.0},{:.0})\\c{color}}}{text}\n",
                    ts(t),
                    ts(t + o.fixed_secs),
                    w / 2.0,
                    y,
                ));
            }
            // 其余一律当滚动。从右侧屏外进,走到完全离开左侧。
            _ => {
                let tw = est_width(&text, fs);
                let dur = o.scroll_secs.max(0.5);
                // 入口空出时刻:这条的尾巴完全进屏之后,下一条才好接上。
                let speed = (w + tw) / dur;
                let lane = pick_lane(&mut scroll_free, t, t + (tw + fs) / speed);
                let y = lane as f64 * lane_h;
                events.push_str(&format!(
                    "Dialogue: 0,{},{},LP,,0,0,0,,{{\\an7\\move({:.0},{:.0},{:.0},{:.0})\\c{color}}}{text}\n",
                    ts(t),
                    ts(t + dur),
                    w,
                    y,
                    -tw,
                    y,
                ));
            }
        }
    }

    let alpha = 255 - (o.opacity.min(100) as u32 * 255 / 100);
    let bold = if o.bold { -1 } else { 0 };
    format!(
        "[Script Info]\n\
         ScriptType: v4.00+\n\
         PlayResX: {}\n\
         PlayResY: {}\n\
         WrapStyle: 2\n\
         ScaledBorderAndShadow: yes\n\
         \n\
         [V4+ Styles]\n\
         Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n\
         Style: LP,{},{},&H{alpha:02X}FFFFFF,&H{alpha:02X}FFFFFF,&H{alpha:02X}000000,&H{alpha:02X}000000,{bold},0,0,0,100,100,0,0,1,{:.1},0,7,0,0,0,1\n\
         \n\
         [Events]\n\
         Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n\
         {events}",
        o.play_res_x, o.play_res_y, o.font, o.font_size, o.outline,
    )
}

/// 选一条轨:优先已空出的最上面那条;都占着就选最早空出的(允许重叠,总比丢弹幕好)。
fn pick_lane(free: &mut [f64], now: f64, busy_until: f64) -> usize {
    let mut best = 0usize;
    let mut best_free = f64::INFINITY;
    for (i, f) in free.iter().enumerate() {
        if now >= *f {
            best = i;
            break;
        }
        if *f < best_free {
            best_free = *f;
            best = i;
        }
    }
    free[best] = busy_until;
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(time: f64, text: &str, mode: i32, color: i32) -> DanmakuComment {
        DanmakuComment { time, text: text.into(), mode, color, ..Default::default() }
    }

    fn events(s: &str) -> Vec<&str> {
        s.lines().filter(|l| l.starts_with("Dialogue:")).collect()
    }

    #[test]
    fn header_declares_playres_and_style() {
        let out = to_ass(&[c(0.0, "hi", 1, 0xffffff)], &AssOptions::default());
        assert!(out.contains("PlayResX: 1920"));
        assert!(out.contains("PlayResY: 1080"));
        assert!(out.contains("Style: LP,Microsoft YaHei,48,"));
        assert!(out.contains("[Events]"));
    }

    /// 滚动弹幕必须用 `\move` 而不是 `\pos` —— 这是「让 mpv 自己动」的全部要点。
    /// 一旦退回 \pos,弹幕就不动了,而且不报错。
    #[test]
    fn scroll_uses_move_from_right_edge_to_offscreen_left() {
        let out = to_ass(&[c(1.0, "测试", 1, 0xffffff)], &AssOptions::default());
        let ev = events(&out);
        assert_eq!(ev.len(), 1);
        let line = ev[0];
        assert!(line.contains("\\move("), "滚动弹幕必须 \\move:{line}");
        assert!(line.contains("\\move(1920,"), "应从画面右缘外进入:{line}");
        // 终点必须是负数(完全滚出左侧),否则末尾会卡在屏幕上
        let end_x: f64 = line
            .split("\\move(")
            .nth(1)
            .unwrap()
            .split(',')
            .nth(2)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert!(end_x < 0.0, "终点 x 应为负(滚出屏外),实际 {end_x}:{line}");
        assert!(line.starts_with("Dialogue: 0,0:00:01.00,0:00:09.00,LP,"), "起止时刻不对:{line}");
    }

    #[test]
    fn fixed_modes_are_centered_and_anchored() {
        let out = to_ass(&[c(2.0, "顶", 5, 0xffffff), c(2.0, "底", 4, 0xffffff)], &AssOptions::default());
        let ev = events(&out);
        let top = ev.iter().find(|l| l.ends_with("顶")).unwrap();
        let bottom = ev.iter().find(|l| l.ends_with("底")).unwrap();
        assert!(top.contains("\\an8"), "顶部弹幕锚点应是 an8:{top}");
        assert!(bottom.contains("\\an2"), "底部弹幕锚点应是 an2:{bottom}");
        assert!(top.contains("\\pos(960,"), "应水平居中:{top}");
        assert!(!top.contains("\\move("), "固定弹幕不该有 \\move:{top}");
        // 停留 fixed_secs
        assert!(top.contains("0:00:02.00,0:00:07.00"), "{top}");
    }

    /// ASS 是 BGR 序。写反了整片弹幕红蓝互换,而且看起来「有颜色」所以很难发现。
    #[test]
    fn color_is_bgr_not_rgb() {
        let out = to_ass(&[c(0.0, "红", 1, 0xFF0000)], &AssOptions::default());
        assert!(out.contains("\\c&H0000FF&"), "纯红 0xFF0000 应写成 &H0000FF&:{out}");
        let out2 = to_ass(&[c(0.0, "蓝", 1, 0x0000FF)], &AssOptions::default());
        assert!(out2.contains("\\c&HFF0000&"), "纯蓝 0x0000FF 应写成 &HFF0000&:{out2}");
    }

    /// 一条带 `{` 或换行的弹幕不处理就能吃掉后面整行 —— 弹幕文本是**用户输入**,
    /// 站点不保证干净。
    #[test]
    fn escapes_ass_metacharacters() {
        let out = to_ass(&[c(0.0, "{\\an8}恶意", 1, 0xffffff), c(1.0, "换\n行", 1, 0xffffff)], &AssOptions::default());
        let ev = events(&out);
        assert_eq!(ev.len(), 2, "两条弹幕都要在,不能被吃掉:{out}");
        // 覆盖标签块只应有我们自己那一个
        assert_eq!(ev[0].matches("{").count(), 1, "用户的 {{ 必须被中和:{}", ev[0]);
        assert!(!ev[1].contains('\n'));
        assert!(ev[1].ends_with("换 行"), "换行应换成空格:{}", ev[1]);
    }

    /// 显示区域 = 只用画面上半部分时,轨道数要跟着减半,弹幕不能画到区域外。
    #[test]
    fn area_percent_limits_lane_count() {
        let many: Vec<DanmakuComment> =
            (0..60).map(|i| c(0.0, &format!("第{i}条"), 1, 0xffffff)).collect();
        let full = to_ass(&many, &AssOptions { area_percent: 100, ..Default::default() });
        let half = to_ass(&many, &AssOptions { area_percent: 50, ..Default::default() });
        let max_y = |s: &str| {
            events(s)
                .iter()
                .filter_map(|l| l.split("\\move(").nth(1))
                .filter_map(|r| r.split(',').nth(1))
                .filter_map(|y| y.trim().parse::<f64>().ok())
                .fold(0.0f64, f64::max)
        };
        let (yf, yh) = (max_y(&full), max_y(&half));
        assert!(yh < yf, "50% 区域的最大 y({yh}) 应小于 100%({yf})");
        assert!(yh <= 1080.0 * 0.5, "弹幕跑出了指定显示区域:{yh}");
    }

    #[test]
    fn opacity_maps_to_style_alpha() {
        let opaque = to_ass(&[c(0.0, "x", 1, 0xffffff)], &AssOptions { opacity: 100, ..Default::default() });
        assert!(opaque.contains("&H00FFFFFF"), "100% 不透明 = alpha 00:{opaque}");
        let half = to_ass(&[c(0.0, "x", 1, 0xffffff)], &AssOptions { opacity: 50, ..Default::default() });
        assert!(half.contains("&H80FFFFFF"), "50% 应是 alpha 80:{half}");
        let gone = to_ass(&[c(0.0, "x", 1, 0xffffff)], &AssOptions { opacity: 0, ..Default::default() });
        assert!(gone.contains("&HFFFFFFFF"), "0% 应是全透明 alpha FF:{gone}");
    }

    /// 弹幕站返回的顺序不保证按时间。ASS 事件乱序时 libass 仍能放,但轨道分配会算错
    /// (后来的弹幕被判成「早就空出来了」),表现为大量重叠。
    #[test]
    fn events_are_emitted_in_time_order() {
        let out = to_ass(
            &[c(9.0, "晚", 1, 0xffffff), c(1.0, "早", 1, 0xffffff), c(5.0, "中", 1, 0xffffff)],
            &AssOptions::default(),
        );
        let ev = events(&out);
        let starts: Vec<&str> = ev.iter().map(|l| l.split(',').nth(1).unwrap()).collect();
        assert_eq!(starts, vec!["0:00:01.00", "0:00:05.00", "0:00:09.00"], "{ev:?}");
    }

    #[test]
    fn empty_text_is_dropped_not_emitted_blank() {
        let out = to_ass(&[c(0.0, "   ", 1, 0xffffff), c(1.0, "有内容", 1, 0xffffff)], &AssOptions::default());
        assert_eq!(events(&out).len(), 1);
    }

    #[test]
    fn timestamps_use_centiseconds() {
        assert_eq!(ts(0.0), "0:00:00.00");
        assert_eq!(ts(1.234), "0:00:01.23");
        assert_eq!(ts(3661.5), "1:01:01.50");
        assert_eq!(ts(-5.0), "0:00:00.00");
    }
}
