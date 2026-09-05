//go:build android

// JNI 薄层。**只做类型转换,不做任何逻辑** —— 逻辑全在 lp_* 那 13 个导出里。
//
// ## 为什么 JNI 桥在这里而不是一个单独的 .so
//
// 单独一个 .so 意味着一个 CMake 工程 + 一次 dlopen + 一份要和 lp_* 对齐的声明。
// 而 Kotlin 侧 `System.loadLibrary("lpcore")` 之后,JNI 会在**同一个 .so** 里
// 按名字找 `Java_...`,所以把桥编进 lpcore 就少了整条链。
// 代价:这个文件里有 C 代码 —— 但它全是 GetStringUTFChars / NewStringUTF 这类转换,
// 没有一行业务。
package main

/*
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <android/native_window_jni.h>

// 本包自己的 cgo 导出(签名照 lpcore.h)。同一个 .so,链接期能找到。
extern int32_t lp_abi_version(void);
extern int32_t lp_init(char* configJSON);
extern int32_t lp_call(int64_t seq, char* cmd, char* argsJSON);
extern void    lp_cancel(int64_t seq);
extern char*   lp_next_event(int32_t timeoutMs);
extern void    lp_free(char* p);
extern void    lp_shutdown(void);
extern int32_t lp_set_surface(int32_t kind, int64_t handle, int32_t width, int32_t height);

// ffmpeg 的 JNI 挂载点(libmpv.so 导出)。声明在这里而不是引头文件:
// 仓库里只有 mpv 的 client.h,没有 ffmpeg 的头。
extern int av_jni_set_java_vm(void *vm, void *log_ctx);

// ☠ 没有它,起播必失败,而失败信息只在 mpv 的 error 日志里:
//     "No Java virtual machine has been registered"
//     "Could not attach java VM."
//     "Failed initializing any suitable GPU context!"
//   界面上看到的只有「一直黑屏」—— surface 明明绑上了、命令全部返回成功。
//
//   mpv 的 android GPU 上下文要经 JNI 问 Surface 的尺寸与格式,ffmpeg 的
//   mediacodec 也要 JavaVM。两者都从 av_jni_get_java_vm() 拿,而那个全局
//   只能由宿主在 JNI_OnLoad 里注册一次。
//
// ★ 这段是 cgo 的 C 前导,它本身就住在一个块注释里 —— 里面**不能再出现块注释的
//   结束符**,连中文说明里、连行内注释里都不行。出现了就提前把前导关掉,
//   报一串看不懂的 Go 语法错(unexpected > / string not terminated)。
//   这条同一天踩了三次:第一次在正文注释,第二次在中文说明,第三次在
//   `EGL_CONTEXT_FLAGS_KHR` 那个行内注释里。
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    (void)reserved;
    av_jni_set_java_vm((void*)vm, 0);
    return JNI_VERSION_1_6;
}

JNIEXPORT jint JNICALL Java_xyz_linplayer_app_core_Native_abiVersion(JNIEnv* e, jclass c) {
    (void)e; (void)c;
    return (jint)lp_abi_version();
}

JNIEXPORT jint JNICALL Java_xyz_linplayer_app_core_Native_init(JNIEnv* e, jclass c, jstring cfg) {
    (void)c;
    const char* s = (*e)->GetStringUTFChars(e, cfg, 0);
    int32_t rc = lp_init((char*)s);
    (*e)->ReleaseStringUTFChars(e, cfg, s);
    return (jint)rc;
}

JNIEXPORT jint JNICALL Java_xyz_linplayer_app_core_Native_call(
        JNIEnv* e, jclass c, jlong seq, jstring cmd, jstring args) {
    (void)c;
    const char* a = (*e)->GetStringUTFChars(e, cmd, 0);
    const char* b = (*e)->GetStringUTFChars(e, args, 0);
    int32_t rc = lp_call((int64_t)seq, (char*)a, (char*)b);
    (*e)->ReleaseStringUTFChars(e, cmd, a);
    (*e)->ReleaseStringUTFChars(e, args, b);
    return (jint)rc;
}

JNIEXPORT void JNICALL Java_xyz_linplayer_app_core_Native_cancel(JNIEnv* e, jclass c, jlong seq) {
    (void)e; (void)c;
    lp_cancel((int64_t)seq);
}

// ★ lp_free 在这里调掉,不暴露给 Kotlin。
//   把释放交给调用方 = 早晚漏一次,而漏一次就是稳定增长的内存泄漏(SPEC §5.3)。
JNIEXPORT jstring JNICALL Java_xyz_linplayer_app_core_Native_nextEvent(
        JNIEnv* e, jclass c, jint timeoutMs) {
    (void)c;
    char* p = lp_next_event((int32_t)timeoutMs);
    if (!p) return NULL;              // 超时
    jstring s = (*e)->NewStringUTF(e, p);
    lp_free(p);
    return s;
}

JNIEXPORT void JNICALL Java_xyz_linplayer_app_core_Native_shutdown(JNIEnv* e, jclass c) {
    (void)e; (void)c;
    lp_shutdown();
}

// 视频通道 A(SPEC §7.2)。surface == NULL 就是解绑。
//
// ☠☠ **mpv 的 --wid 在安卓上要的是 `android.view.Surface` 的 jobject,
//     不是 ANativeWindow*。** 传 ANativeWindow* 进去,libmpv 会在**自己的线程上**
//     再对它调一次 ANativeWindow_fromSurface,当场:
//       JNI DETECTED ERROR IN APPLICATION: jobject is an invalid JNI transition
//       frame reference ... in call to GetObjectField  → SIGABRT
//     栈顶是 libandroid.so 的 ANativeWindow_fromSurface,看起来像我们这边的错,
//     其实是**交给 mpv 的东西类型不对**。
//
// ★ 所以这里持有一个 **global ref**,并且:
//   · 同一个 Surface 只是尺寸变了 → 把**同一个**引用再交一次,核心层据此走
//     「只改尺寸」那条路,不重建 vo(重建会黑一帧);
//   · 换了 Surface 或解绑 → 先 lp_set_surface(0) 阻塞到 mpv 不再画,**再**
//     DeleteGlobalRef。顺序反过来就是 use-after-free。
static jobject g_surface = NULL;

static void lp_drop_surface(JNIEnv* e) {
    if (!g_surface) return;
    lp_set_surface(0, 0, 0, 0);            // 阻塞:返回后 mpv 已经不画了
    (*e)->DeleteGlobalRef(e, g_surface);
    g_surface = NULL;
}

JNIEXPORT jint JNICALL Java_xyz_linplayer_app_core_Native_setSurface(
        JNIEnv* e, jclass c, jobject surface, jint w, jint h) {
    (void)c;
    if (surface == NULL) { lp_drop_surface(e); return 0; }

    if (g_surface && (*e)->IsSameObject(e, g_surface, surface)) {
        // 同一个 Surface,只是尺寸变了
        return (jint)lp_set_surface(1, (int64_t)(intptr_t)g_surface, (int32_t)w, (int32_t)h);
    }
    lp_drop_surface(e);
    g_surface = (*e)->NewGlobalRef(e, surface);
    if (!g_surface) return -1;
    return (jint)lp_set_surface(1, (int64_t)(intptr_t)g_surface, (int32_t)w, (int32_t)h);
}
*/
import "C"
