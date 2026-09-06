//go:build android

// libass 桥 —— 给 **ExoPlayer 内核**画特效字幕(U1.6b)。
//
// ## 为什么不再编一份 libass
//
// 实测:我们已经在用的 `libmpv.so`(media-kit full 变体)**导出了 191 个 `ass_*` 符号**,
// `ass_library_init` / `ass_renderer_init` / `ass_new_track` / `ass_process_codec_private` /
// `ass_process_chunk` / `ass_set_frame_size` / `ass_render_frame` 一条不缺
// (`llvm-nm -D --defined-only` 查得到)。Kotlin 侧 `System.loadLibrary("mpv")` 排在
// `loadLibrary("lpcore")` 之前,符号进的是全局命名空间 —— 所以这里**只声明不链接**,
// 和 `mpv_*`、`av_jni_set_java_vm` 走的是同一条路,`CGO_LDFLAGS` 里不必加 `-lass`。
// 再引一份 libass 等于把包里已有的东西又编一遍,还多一份要跟着升级的依赖。
//
// ## 为什么 mpv 内核用不着它
//
// mpv 那条路的字幕是 libmpv 自己用同一个 libass 画进画面里的。这一层**只服务 Exo**:
// media3 的 `SsaParser` 只认位置和基本样式,`\pos` `\move` `\fad`、卡拉OK 全丢。
//
// ## 没有 fontconfig
//
// 实测这份 libmpv 里一个 `Fc*` 符号都没有,所以字体只能走 libass 的**目录提供者**:
// `ass_set_fonts_dir("/system/fonts")`。和 mpv 那条的 `sub-fonts-dir` 是同一件事 ——
// 不给的话 libass 找不到字体,**文本一个字都不显示**而且不报错。
package main

/*
#cgo LDFLAGS: -ljnigraphics

#include <jni.h>
#include <android/bitmap.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// libass 的最小 ABI。声明在这里而不是引头文件:仓库里没有 libass 的头,
// 而为三个 struct 指针和十来个函数去 vendor 一整套 LGPL 头文件不划算。
//
// ASS_Image 的字段顺序**必须逐字对**(下面那段是 libass/ass.h 的原样),
// 错一个字段就是读到野指针 —— 而它不会报错,只会花屏或者当场 SIGSEGV。
// 版本护栏见 lp_ass_open 里对 ass_library_version 的判断。
typedef struct ass_library  ASS_Library;
typedef struct ass_renderer ASS_Renderer;
typedef struct ass_track    ASS_Track;

typedef struct ass_image {
    int w, h;
    int stride;
    unsigned char *bitmap;
    uint32_t color;
    int dst_x, dst_y;
    struct ass_image *next;
    int type;
} ASS_Image;

extern int           ass_library_version(void);
extern ASS_Library  *ass_library_init(void);
extern void          ass_library_done(ASS_Library *);
extern void          ass_set_fonts_dir(ASS_Library *, const char *);
extern void          ass_set_extract_fonts(ASS_Library *, int);
extern ASS_Renderer *ass_renderer_init(ASS_Library *);
extern void          ass_renderer_done(ASS_Renderer *);
extern void          ass_set_frame_size(ASS_Renderer *, int, int);
extern void          ass_set_storage_size(ASS_Renderer *, int, int);
extern void          ass_set_pixel_aspect(ASS_Renderer *, double);
extern void          ass_set_fonts(ASS_Renderer *, const char *, const char *, int, const char *, int);
extern ASS_Track    *ass_new_track(ASS_Library *);
extern ASS_Track    *ass_read_memory(ASS_Library *, char *, size_t, char *);
extern void          ass_free_track(ASS_Track *);
extern void          ass_process_codec_private(ASS_Track *, const char *, int);
extern void          ass_process_chunk(ASS_Track *, const char *, int, long long, long long);
extern ASS_Image    *ass_render_frame(ASS_Renderer *, ASS_Track *, long long, int *);

extern int __android_log_print(int prio, const char *tag, const char *fmt, ...);
#define LPA_LOG(...) __android_log_print(4, "lp-libass", __VA_ARGS__)

// AUTODETECT:这份构建里没有 fontconfig / coretext / directwrite,
// 于是它实际落到目录提供者上 —— 也就是 ass_set_fonts_dir 给的那个目录。
#define LPA_FONTPROVIDER_AUTODETECT 1

// 已知能对上 ASS_Image 布局的 libass API 版本区间。
// 0x01000000 ~ 0x01FFFFFF 覆盖 libass 0.10 ~ 0.17.x —— 这段里结构体一个字段没动过。
// 超出区间就**拒绝渲染并说清楚**,不去赌:赌错的表现是花屏或者进程直接没。
#define LPA_VER_MIN 0x01000000
#define LPA_VER_MAX 0x01FFFFFF

static ASS_Library  *g_lib;
static ASS_Renderer *g_rend;
static ASS_Track    *g_track;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

// 上一次真的画过东西没有。用来回答「detect_change=0 但位图刚被重建过」这一类,
// 见 lp_ass_render 的 force 参数。
static int g_painted;

static void lpa_free_locked(void) {
    if (g_track) { ass_free_track(g_track); g_track = NULL; }
    if (g_rend)  { ass_renderer_done(g_rend); g_rend = NULL; }
    // g_lib 留着不销毁:字体目录扫描是这一层最贵的一步(几十毫秒),
    // 换一集就重扫一次等于每次起播白等。库本身没有播放状态。
    g_painted = 0;
}

// lpa_init_locked 建库 + 渲染器。已经有了就直接用。
static int lpa_init_locked(const char *fontsDir) {
    if (!g_lib) {
        int ver = ass_library_version();
        if (ver < LPA_VER_MIN || ver > LPA_VER_MAX) {
            LPA_LOG("libass API 版本 0x%X 不在已知区间,拒绝渲染(ASS_Image 布局可能变了)", ver);
            return -2;
        }
        LPA_LOG("libass API 版本 0x%X", ver);
        g_lib = ass_library_init();
        if (!g_lib) return -1;
        // 附件字体:MKV 里带的字体。ExoPlayer 现在不把附件透出来,
        // 开着它至少让以后接上时不用再改这里,关着没有任何收益。
        ass_set_extract_fonts(g_lib, 1);
        if (fontsDir && fontsDir[0]) ass_set_fonts_dir(g_lib, fontsDir);
    }
    if (!g_rend) {
        g_rend = ass_renderer_init(g_lib);
        if (!g_rend) return -1;
        // 没有 fontconfig,第四个参数(config)给 NULL;update=1 让它当场扫目录。
        ass_set_fonts(g_rend, NULL, "sans-serif", LPA_FONTPROVIDER_AUTODETECT, NULL, 1);
        ass_set_pixel_aspect(g_rend, 1.0);
    }
    return 0;
}

JNIEXPORT jint JNICALL Java_xyz_linplayer_app_core_Native_assOpen(
        JNIEnv *e, jclass c, jbyteArray header, jstring fontsDir) {
    (void)c;
    const char *fd = fontsDir ? (*e)->GetStringUTFChars(e, fontsDir, 0) : NULL;
    pthread_mutex_lock(&g_mu);
    lpa_free_locked();
    int rc = lpa_init_locked(fd);
    if (rc == 0) {
        g_track = ass_new_track(g_lib);
        if (!g_track) rc = -1;
        else if (header) {
            jsize n = (*e)->GetArrayLength(e, header);
            jbyte *p = (*e)->GetByteArrayElements(e, header, 0);
            ass_process_codec_private(g_track, (const char *)p, (int)n);
            (*e)->ReleaseByteArrayElements(e, header, p, JNI_ABORT);
        }
    }
    pthread_mutex_unlock(&g_mu);
    if (fd) (*e)->ReleaseStringUTFChars(e, fontsDir, fd);
    return rc;
}

// 外挂字幕:整份 .ass 文件。ass_read_memory 自己建 track。
JNIEXPORT jint JNICALL Java_xyz_linplayer_app_core_Native_assOpenFile(
        JNIEnv *e, jclass c, jbyteArray file, jstring fontsDir) {
    (void)c;
    if (!file) return -1;
    const char *fd = fontsDir ? (*e)->GetStringUTFChars(e, fontsDir, 0) : NULL;
    pthread_mutex_lock(&g_mu);
    lpa_free_locked();
    int rc = lpa_init_locked(fd);
    if (rc == 0) {
        jsize n = (*e)->GetArrayLength(e, file);
        jbyte *p = (*e)->GetByteArrayElements(e, file, 0);
        // ass_read_memory 的第 4 个参数是编码名。给 NULL = 让 libass 自己按 BOM 判,
        // 写死 "UTF-8" 会把带 BOM 的 GBK 字幕解成乱码。
        g_track = ass_read_memory(g_lib, (char *)p, (size_t)n, NULL);
        (*e)->ReleaseByteArrayElements(e, file, p, JNI_ABORT);
        if (!g_track) rc = -1;
    }
    pthread_mutex_unlock(&g_mu);
    if (fd) (*e)->ReleaseStringUTFChars(e, fontsDir, fd);
    return rc;
}

// 一条事件。body 必须是 **Matroska 口径**:ReadOrder,Layer,Style,Name,
// MarginL,MarginR,MarginV,Effect,Text —— 不带 "Dialogue:",不带时间。
// 时间由 timecode / duration 两个参数给(毫秒)。这是 ass_process_chunk 的约定,
// 拼错的表现是「字幕出来了但样式全丢」或者干脆一条不出。
JNIEXPORT void JNICALL Java_xyz_linplayer_app_core_Native_assChunk(
        JNIEnv *e, jclass c, jbyteArray body, jlong startMs, jlong durMs) {
    (void)c;
    if (!body) return;
    jsize n = (*e)->GetArrayLength(e, body);
    jbyte *p = (*e)->GetByteArrayElements(e, body, 0);
    pthread_mutex_lock(&g_mu);
    if (g_track) ass_process_chunk(g_track, (const char *)p, (int)n,
                                   (long long)startMs, (long long)durMs);
    pthread_mutex_unlock(&g_mu);
    (*e)->ReleaseByteArrayElements(e, body, p, JNI_ABORT);
}

// frame = 位图尺寸(字幕画在多大的画布上);storage = 视频本身的分辨率。
// storage 不给的话,按 PlayResX/Y 定位的特效字幕会整体错位 —— mpv 也是分开设的。
JNIEXPORT void JNICALL Java_xyz_linplayer_app_core_Native_assSetSize(
        JNIEnv *e, jclass c, jint frameW, jint frameH, jint videoW, jint videoH) {
    (void)e; (void)c;
    pthread_mutex_lock(&g_mu);
    if (g_rend) {
        ass_set_frame_size(g_rend, frameW, frameH);
        if (videoW > 0 && videoH > 0) ass_set_storage_size(g_rend, videoW, videoH);
        g_painted = 0;   // 尺寸变了,上一帧的内容作废
    }
    pthread_mutex_unlock(&g_mu);
}

// 把一张 ASS_Image 叠进 ARGB_8888 位图。
//
// color 是 0xRRGGBBAA,而 **AA 是透明度不是不透明度**(255 = 全透)。
// 写进去的是**预乘**值:Android 的 ARGB_8888 默认 premultiplied,
// 写非预乘的表现是半透明处偏亮 —— 描边和阴影会糊成一团。
static void lpa_blend(unsigned char *dst, int dstStride, int dstW, int dstH, ASS_Image *img) {
    unsigned opacity = 255 - (img->color & 0xFF);
    unsigned r = (img->color >> 24) & 0xFF;
    unsigned g = (img->color >> 16) & 0xFF;
    unsigned b = (img->color >> 8) & 0xFF;
    if (opacity == 0 || img->w <= 0 || img->h <= 0) return;

    int x0 = img->dst_x, y0 = img->dst_y;
    int w = img->w, h = img->h;
    const unsigned char *src = img->bitmap;
    // 越界裁剪:libass 在某些 \pos 下会给出部分落在画布外的图,
    // 不裁就是往位图外面写 —— 堆破坏,而且往往过很久才崩。
    // 挪的是**本地指针**,不许改 img->bitmap:那块内存是 libass 的,它下一帧还要用。
    if (x0 < 0) { w += x0; src -= x0; x0 = 0; }
    if (y0 < 0) { h += y0; src -= (ptrdiff_t)y0 * img->stride; y0 = 0; }
    if (x0 + w > dstW) w = dstW - x0;
    if (y0 + h > dstH) h = dstH - y0;
    if (w <= 0 || h <= 0) return;

    unsigned char *row = dst + (ptrdiff_t)y0 * dstStride + (ptrdiff_t)x0 * 4;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            unsigned k = (unsigned)src[x] * opacity / 255;
            if (!k) continue;
            unsigned char *px = row + x * 4;
            unsigned inv = 255 - k;
            px[0] = (unsigned char)((k * r + inv * px[0]) / 255);
            px[1] = (unsigned char)((k * g + inv * px[1]) / 255);
            px[2] = (unsigned char)((k * b + inv * px[2]) / 255);
            px[3] = (unsigned char)((k * 255 + inv * px[3]) / 255);
        }
        src += img->stride;
        row += dstStride;
    }
}

// 返回:-1 出错 / 0 这一帧和上一帧一样(调用方可以不重绘)/ 1 位图已更新。
//
// detect_change 为 0 时**一个字节都不碰**位图 —— 对白字幕一秒才变几次,
// 每帧无脑清屏 + 重画是纯烧电。force 用于位图刚重建 / seek 之后。
JNIEXPORT jint JNICALL Java_xyz_linplayer_app_core_Native_assRender(
        JNIEnv *e, jclass c, jobject bitmap, jlong posMs, jboolean force) {
    (void)c;
    if (!bitmap) return -1;
    AndroidBitmapInfo info;
    if (AndroidBitmap_getInfo(e, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS) return -1;
    if (info.format != ANDROID_BITMAP_FORMAT_RGBA_8888) return -1;

    pthread_mutex_lock(&g_mu);
    if (!g_rend || !g_track) { pthread_mutex_unlock(&g_mu); return -1; }
    int changed = 0;
    ASS_Image *img = ass_render_frame(g_rend, g_track, (long long)posMs, &changed);
    if (!changed && !force && g_painted) { pthread_mutex_unlock(&g_mu); return 0; }
    if (!img && !g_painted && !force) { pthread_mutex_unlock(&g_mu); return 0; }

    void *pixels = NULL;
    if (AndroidBitmap_lockPixels(e, bitmap, &pixels) != ANDROID_BITMAP_RESULT_SUCCESS) {
        pthread_mutex_unlock(&g_mu);
        return -1;
    }
    memset(pixels, 0, (size_t)info.stride * info.height);
    int n = 0;
    for (ASS_Image *p = img; p; p = p->next) {
        lpa_blend((unsigned char *)pixels, (int)info.stride, (int)info.width, (int)info.height, p);
        n++;
    }
    AndroidBitmap_unlockPixels(e, bitmap);
    g_painted = (n > 0);
    pthread_mutex_unlock(&g_mu);
    return 1;
}

JNIEXPORT void JNICALL Java_xyz_linplayer_app_core_Native_assClose(JNIEnv *e, jclass c) {
    (void)e; (void)c;
    pthread_mutex_lock(&g_mu);
    lpa_free_locked();
    pthread_mutex_unlock(&g_mu);
}

// 这个构建里的 libass 能不能用。0 = 不可用。给 UI 决定要不要亮「特效字幕」这一项。
JNIEXPORT jint JNICALL Java_xyz_linplayer_app_core_Native_assVersion(JNIEnv *e, jclass c) {
    (void)e; (void)c;
    return (jint)ass_library_version();
}
*/
import "C"
