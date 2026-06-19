package com.example.linplayer_mobile

/**
 * Bridge to register the JavaVM with ffmpeg for mpv Android EGL support.
 *
 * System.loadLibrary("mpv_init_jni") triggers JNI_OnLoad which caches
 * the JavaVM. Then nativeRegisterJavaVm() calls av_jni_set_java_vm()
 * via dlsym (after libavcodec.so is loaded as a dependency of libmpv.so).
 */
object MpvInitBridge {
    init {
        // 必须捕获：loadLibrary 失败抛 UnsatisfiedLinkError(Error)，若不捕获会让本 object 的
        // 首次访问抛 ExceptionInInitializerError，绕过调用处的 catch(Exception) 直接崩溃 App。
        // 捕获后即便 mpv_init_jni 缺失也只是 JavaVM 未注册(硬解回退软解)，绝不致崩。
        try {
            System.loadLibrary("mpv_init_jni")
        } catch (e: Throwable) {
            android.util.Log.e("MpvInitBridge", "load mpv_init_jni failed: ${e.message}")
        }
    }

    @JvmStatic
    external fun nativeRegisterJavaVm()

    /**
     * Call after libmpv.so is loaded to register the JavaVM with ffmpeg.
     */
    fun ensureJavaVmRegistered() {
        try {
            nativeRegisterJavaVm()
        } catch (e: Throwable) {
            // mediacodec 硬解所需的 JavaVM 注册失败：不致命，mpv 会自动回退软件解码。
            android.util.Log.e("MpvInitBridge", "nativeRegisterJavaVm failed: ${e.message}")
        }
    }
}
