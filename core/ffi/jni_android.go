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
// ☠ ANativeWindow_fromSurface 加一次引用,**由核心层 release**(surface_android.go 里)。
//   在这里 release 的话,mpv 还拿着一个已经归零的窗口 —— 那是 use-after-free。
JNIEXPORT jint JNICALL Java_xyz_linplayer_app_core_Native_setSurface(
        JNIEnv* e, jclass c, jobject surface, jint w, jint h) {
    (void)c;
    if (surface == NULL) return (jint)lp_set_surface(0, 0, 0, 0);
    ANativeWindow* win = ANativeWindow_fromSurface(e, surface);
    if (!win) return -1;
    return (jint)lp_set_surface(1, (int64_t)(intptr_t)win, (int32_t)w, (int32_t)h);
}
*/
import "C"
