package player

// 进度条缩略图:一个**只读本地字节**的第二个 mpv 实例。
//
// ## 为什么是第二个实例
//
// 用户 2026-09-03:「鼠标放到进度条的位置……做一个缩略图的功能,
// 缓存了的进度条能用,没缓存的不能用」。
//
// 三条路都试过了,只有这一条站得住:
//
//	① 服务端 trickplay(BIF):只有新版 Emby 有,本仓要伺候一堆 fork;
//	② 让正在放的那个 mpv 跳过去截一张:会把用户正在看的画面**拽走**;
//	③ 从我们自己渲染过的帧里留一份(上一版就是这么做的):只有**放过的**位置有图,
//	   而用户要的是「已缓存的进度」—— 缓存的是**前面还没放到**的那一段。
//
// 所以起第二个实例,`vo=null` 无窗口解码。实测单张 9~12ms。
//
// ## 为什么不另外带一个 FFmpeg
//
// 用户 2026-09-03 提过「FFMPEG 实时出图就行了,搭配 FFmpeg.Skia」。查过之后没走那条路,
// 三个数摆在这儿(调研出处见 docs/lessons/ui-desktop.md「缩略图为什么不另带 FFmpeg」):
//
//	· NuGet 上**没有** FFmpeg.Skia 这个包。最接近的几个(FFMpegCore /
//	  FFMediaToolkit / Xabe.FFmpeg)本身都不含解码器,要另配原生 FFmpeg dll;
//	· 那套 dll(avcodec/avformat/avutil/swscale/swresample)**20~30MB**;
//	  换成 ffmpeg.exe 静态构建是 100~160MB。包现在总共才 99.7MB;
//	· 起进程跑一次 `ffmpeg -ss … -frames:v 1` 是**百毫秒量级**,
//	  而这条路实测 9~12ms —— 差一个数量级,而缩略图是**跟着鼠标走**的。
//
// 关键在于:`libmpv-2.dll` 里**本来就是 FFmpeg**(它静态链了 avcodec/avformat)。
// 所以这条路并不是「不用 FFmpeg」,而是**用已经在包里的那一份**,一个字节不多带。
//
// ## 它绝不碰网络
//
// 源只有两种:本地文件,或者本地代理的**只读缓存端点**(prefetch.Handle.CachedURL)。
// 那个端点只吐盘上已有的字节,没有的直接 416。于是「没缓存的不能用」这条规矩
// 是**传输层执行的事实**,不是这一层的一句 if —— 这里连判断都不需要写,
// 取不到数就是取不到图。
//
// ## 实例是**用到才开**的
//
// 上一版是起播 4 秒后就把它开起来并一直开着,理由是环形缓存会把文件头挤掉 ——
// 环转一圈之后 `avformat_open_input` 就打不开这条流了,功能**静默失效**。
// 那是拿一个常驻解码器去绕一个缓存 bug。
//
// 现在环形缓存自己把**文件头和文件尾**钉住了(见 core/net/prefetch/cache.go
// 的 slotOf),两段永不轮换,所以任何时候都开得开。于是这里改成
// **第一次要缩略图时才创建,停播就销毁** —— 用户不碰进度条就一个实例都没有。
//
// ★ 尾巴那一段和头一样重要:mp4 的 moov 原子常在**文件末尾**(没跑过 faststart 的片子),
//   mkv 的索引也在末尾。少了它照样打不开 —— 2026-09-03 自检当场撞上,
//   现象是「已缓存的位置也取不到图」,而核心层只说一句「打不开」。

/*
#cgo LDFLAGS: -L${SRCDIR}/../../third_party/libmpv -lmpv
#include <stdlib.h>
#include <stdint.h>

extern void*    mpv_create(void);
extern int      mpv_initialize(void*);
extern int      mpv_set_option_string(void*, const char*, const char*);
extern int      mpv_command(void*, const char**);
extern void*    mpv_wait_event(void*, double);
extern char*    mpv_get_property_string(void*, const char*);
extern void     mpv_free(void*);
extern void     mpv_terminate_destroy(void*);

typedef struct lp_thumb_event { int event_id; int error; uint64_t reply_userdata; void *data; } lp_thumb_event;
static int lp_ev_id(void *ev) { return ev ? ((lp_thumb_event*)ev)->event_id : 0; }
*/
import "C"

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"
	"unsafe"

	"linplayer/core/bus"
	"linplayer/core/paths"
)

// 缩略图规格。**140 宽**是用户 2026-09-03 点的名(「140x80 就够大了 占用会更小」)。
//
// 高度让 mpv 按比例算(`-2`),**不写死 80**:写死的话 2.35:1 的片子会被压变形,
// 而 4:3 的老片会被拉扁 —— 气泡里那张图是给人看构图的,比例错了就没用了。
//
// 一张的代价(实测见 docs/lessons/ui-desktop.md):JPEG 约 2KB,
// 解成 BGRA 约 45KB —— 整条时间轴 300 格全缓存下来也就 13MB。
const thumbWidth = 140

// thumber 缩略图实例。**全进程一个**,请求靠 mu 串行 —— 单张 10ms,排队排不出问题,
// 而两个请求同时进一个 mpv 句柄是未定义行为。
type thumber struct {
	mu  sync.Mutex
	h   unsafe.Pointer
	src string
}

var thumbs thumber

// ensure 保证实例活着、且装的是 src。src 变了要重新 loadfile。
func (t *thumber) ensure(src string) error {
	if t.h == nil {
		h := C.mpv_create()
		if h == nil {
			return fmt.Errorf("mpv_create 失败")
		}
		for _, kv := range [][2]string{
			{"vo", "null"},          // 无窗口。screenshot-to-file 在 vo=null 下实测可用
			{"audio", "no"},         // 不解音频:白花 CPU,还会抢音频设备
			{"sid", "no"},           // 不要字幕:缩略图上盖字幕没意义
			{"hwdec", "no"},         // 硬解在这种「跳一下截一张」的用法上没有收益,还占独显
			{"pause", "yes"},        // 永远暂停:我们只要一帧
			{"keep-open", "always"}, // 播到尾也别卸载文件,不然最后几秒截不到
			{"terminal", "no"},
			{"config", "no"},       // 不读用户的 mpv.conf —— 它可能带上 vo/滤镜
			{"load-scripts", "no"}, // 同上
			{"osc", "no"},
			{"ytdl", "no"},
			{"sub-auto", "no"},        // 别去扫同目录的字幕文件
			{"audio-file-auto", "no"}, // 同上
			{"vd-lavc-fast", "yes"},
			{"vd-lavc-skiploopfilter", "all"}, // 缩到 140 宽,去环滤波一个像素都看不出来
			{"vd-lavc-threads", "2"},
			{"vf", "scale=" + strconv.Itoa(thumbWidth) + ":-2"},
			{"screenshot-format", "jpg"},
			{"screenshot-jpeg-quality", "80"},
			{"cache", "no"}, // 不要它自己的缓存:字节本来就在本地
		} {
			ck, cv := C.CString(kv[0]), C.CString(kv[1])
			C.mpv_set_option_string(h, ck, cv)
			C.free(unsafe.Pointer(ck))
			C.free(unsafe.Pointer(cv))
		}
		if r := C.mpv_initialize(h); r < 0 {
			C.mpv_terminate_destroy(h)
			return fmt.Errorf("mpv_initialize 失败: %d", int(r))
		}
		t.h = unsafe.Pointer(h)
	}
	if t.src == src {
		return nil
	}
	t.src = ""
	if err := t.cmd("loadfile", src, "replace"); err != nil {
		return err
	}
	// 等到真的能放了才算装好。START_FILE(6)先来,别拿它当数。
	if !t.wait(evPlaybackRestart, 10*time.Second) {
		return fmt.Errorf("打不开(这一段多半没在本地缓存里)")
	}
	t.src = src
	return nil
}

// seekSlack 允许落在目标前后多少秒。关键帧 seek 只能落在关键帧上,
// 差几秒是正常的;差几十秒就说明**根本没跳**。
const seekSlack = 30.0

// grab 截 pos 秒处的一帧,返回 JPEG 字节。
func (t *thumber) grab(pos float64) ([]byte, error) {
	/* ☠☠ **先把事件队列抽干**。
	   不抽的话下面那个 wait 会当场吃到上一次(装载 / 上一张缩略图)留下的
	   PLAYBACK_RESTART,于是「等 seek 完成」变成了「立刻返回」——
	   截出来的是**上一帧**。表现极其迷惑:每张图都有、尺寸对、不是全黑,
	   只是**每张都一模一样**,而且没缓存的位置也「有图」。 */
	t.drain()
	// ★ 关键帧 seek,不用 exact:exact 要从前一个关键帧解到目标帧,慢一个数量级,
	//   而缩略图差个几秒没人看得出来 —— 别的播放器也都是关键帧粒度。
	if err := t.cmd("seek", strconv.FormatFloat(pos, 'f', 3, 64), "absolute+keyframes"); err != nil {
		return nil, err
	}
	if !t.wait(evPlaybackRestart, 3*time.Second) {
		return nil, fmt.Errorf("跳到 %.1fs 没跳到(那一段不在缓存里)", pos)
	}
	/* ★★ 光有 PLAYBACK_RESTART **不代表跳到了**:读不到那一段字节时
	   mpv 照样发这个事件,只是位置没动。所以要**核对落点** ——
	   这条就是「没缓存的位置不许出图」在核心层的最后一道闸,
	   只读端点回 416 之后,它保证我们不会把上一帧当成这个位置的图交出去。 */
	if at := t.propF("time-pos"); at < pos-seekSlack || at > pos+seekSlack {
		return nil, fmt.Errorf("要 %.1fs 却停在 %.1fs(那一段不在缓存里)", pos, at)
	}
	dir := paths.TempDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	f := filepath.Join(dir, "thumb.jpg")
	// ★ 先删。不删的话截图失败时读到的是**上一张**,而它长得完全正常 ——
	//   那是这一类功能最难发现的一种错。
	_ = os.Remove(f)
	if err := t.cmd("screenshot-to-file", f, "video"); err != nil {
		return nil, err
	}
	b, err := os.ReadFile(f)
	if err != nil {
		return nil, fmt.Errorf("截图没落地: %w", err)
	}
	return b, nil
}

// drain 把事件队列抽干(timeout=0,取到 NONE 为止)。
func (t *thumber) drain() {
	for i := 0; i < 256; i++ {
		if int(C.lp_ev_id(C.mpv_wait_event(t.h, 0))) == 0 {
			return
		}
	}
}

// propF 读一个数值属性。读不到给 -1(别给 0 —— 0 是合法位置)。
func (t *thumber) propF(name string) float64 {
	cn := C.CString(name)
	defer C.free(unsafe.Pointer(cn))
	p := C.mpv_get_property_string(t.h, cn)
	if p == nil {
		return -1
	}
	s := C.GoString(p)
	C.mpv_free(unsafe.Pointer(p))
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return -1
	}
	return v
}

func (t *thumber) cmd(args ...string) error {
	cargs := make([]*C.char, len(args)+1)
	for i, a := range args {
		cargs[i] = C.CString(a)
	}
	defer func() {
		for i := range args {
			C.free(unsafe.Pointer(cargs[i]))
		}
	}()
	if r := C.mpv_command(t.h, (**C.char)(unsafe.Pointer(&cargs[0]))); r < 0 {
		return fmt.Errorf("mpv %s 失败: %d", args[0], int(r))
	}
	return nil
}

// wait 抽事件直到等到 want。超时返回 false。
func (t *thumber) wait(want int, d time.Duration) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		ev := C.mpv_wait_event(t.h, 0.05)
		if int(C.lp_ev_id(ev)) == want {
			return true
		}
	}
	return false
}

// close 收掉实例(换片 / 停播)。
func (t *thumber) close() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.h != nil {
		C.mpv_terminate_destroy(t.h)
		t.h = nil
	}
	t.src = ""
}

// inCache 这个时间点的字节在不在本地。
//
// ★ spans 是**按字节**算的比例,这里拿时间比例去比 —— 线性折算。
// 误差来自码率起伏,而这条判断的用途是「值不值得去解这一帧」,差几个百分点无所谓:
// 猜错了也只是白跑一趟,后面还有落点核对兜底。
func inCache(pos float64, spans [][2]float64) bool {
	d := propF("duration")
	if d <= 0 {
		return false
	}
	f := pos / d
	for _, sp := range spans {
		if f >= sp[0] && f < sp[1] {
			return true
		}
	}
	return false
}

func registerThumbCommands() {
	// player.thumbnail 取进度条某一点的缩略图。
	//
	// ★ 「没缓存」不是这里判的 —— 只读端点回 416,mpv 打不开/跳不过去,
	//   于是这里自然地返回 available=false。**规矩只写一处**。
	bus.Register("player.thumbnail", func(ctx context.Context, seq int64, a map[string]any) (any, error) {
		pos, _ := a["position"].(float64)
		if pos < 0 {
			pos = 0
		}
		src, spans, _ := localSource()
		if src == "" {
			return map[string]any{"available": false, "why": "这条流没有本地缓存"}, nil
		}
		/* ★★ 先按区间挡掉。只读端点回 416 已经能保证「没缓存的取不出图」,
		   但那条路是**让它失败**,而一次失败的读会把那个 mpv 实例卡在 EOF ——
		   之后连已经缓存的位置也跳不动了(自检当场逮到:
		   「要 225.0s 却停在 1800.0s」)。挡在前面,失败就不会发生。
		   ★ 判据仍然是环形缓存自己报的那份区间,没有第二份真相。 */
		if !inCache(pos, spans) {
			return map[string]any{"available": false, "why": "这个位置还没缓存到本地"}, nil
		}
		thumbs.mu.Lock()
		defer thumbs.mu.Unlock()
		if err := thumbs.ensure(src); err != nil {
			return map[string]any{"available": false, "why": err.Error()}, nil
		}
		b, err := thumbs.grab(pos)
		if err != nil {
			// ★ 失败过一次就把实例作废,下一次重开 —— 读失败会让 ffmpeg 那条流
			//   进入错误态,不重开的话后面**每一次**都失败。
			thumbs.src = ""
			return map[string]any{"available": false, "why": err.Error()}, nil
		}
		// []byte 过 encoding/json 自动变 base64 字符串,UI 侧直接解成 JPEG。
		return map[string]any{"available": true, "jpeg": b, "position": pos}, nil
	})
}
