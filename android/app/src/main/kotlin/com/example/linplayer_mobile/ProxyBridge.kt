package com.example.linplayer_mobile

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * mihomo 代理内核桥接（仅 Android TV 使用）。
 *
 * 内核以 libmihomo.so 形式打包进 tv flavor 的 jniLibs，安装后位于
 * applicationInfo.nativeLibraryDir，可作为独立子进程执行（Android 10+ 限制）。
 *
 * zashboard 面板以 Android assets（src/tv/assets/zashboard）打包，首次启动时
 * 复制到内核 home 目录下的 ui/，由 mihomo 的 external-ui 提供。
 *
 * 配置 config.yaml 由 Dart 层生成并通过 start 传入，这里只负责落盘与起停进程。
 */
object ProxyBridge {
    private const val TAG = "ProxyBridge"
    private const val CORE_LIB = "libmihomo.so"
    private const val HOME_DIR = "mihomo"
    private const val UI_ASSET = "zashboard"

    private var process: Process? = null
    private var logThread: Thread? = null

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isCoreAvailable" -> result.success(coreFile(context).exists())
            "isRunning" -> result.success(isRunning())
            "start" -> {
                val configYaml = call.argument<String>("config") ?: ""
                try {
                    start(context, configYaml)
                    result.success(true)
                } catch (e: Exception) {
                    android.util.Log.e(TAG, "start failed", e)
                    result.error("START_FAILED", e.message, null)
                }
            }
            "stop" -> {
                stop()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun coreFile(context: Context): File =
        File(context.applicationInfo.nativeLibraryDir, CORE_LIB)

    private fun homeDir(context: Context): File =
        File(context.filesDir, HOME_DIR).apply { mkdirs() }

    private fun isRunning(): Boolean = process?.isAlive == true

    @Synchronized
    private fun start(context: Context, configYaml: String) {
        if (isRunning()) stop()

        val core = coreFile(context)
        if (!core.exists()) {
            throw IllegalStateException("mihomo 内核缺失（仅 TV 构建包含 $CORE_LIB）")
        }

        val home = homeDir(context)
        // 写入配置
        val configFile = File(home, "config.yaml")
        configFile.writeText(configYaml)

        // 解压 zashboard 面板到 home/ui（external-ui 相对 -d 解析）
        extractDashboard(context, File(home, "ui"))

        android.util.Log.i(TAG, "启动 mihomo: ${core.absolutePath} -d ${home.absolutePath}")
        val proc = ProcessBuilder(
            core.absolutePath,
            "-d", home.absolutePath,
            "-f", configFile.absolutePath
        ).redirectErrorStream(true).start()
        process = proc

        // 把内核日志转到 logcat，避免管道缓冲塞满阻塞进程
        logThread = Thread {
            try {
                proc.inputStream.bufferedReader().forEachLine { line ->
                    android.util.Log.i("mihomo", line)
                }
            } catch (_: Exception) {
            }
        }.apply { isDaemon = true; start() }
    }

    @Synchronized
    fun stop() {
        try {
            process?.destroy()
        } catch (_: Exception) {
        }
        process = null
        logThread = null
    }

    /** 把 assets/zashboard 递归复制到目标目录（已存在则先清空，保证版本一致）。 */
    private fun extractDashboard(context: Context, target: File) {
        try {
            val assets = context.assets
            // 资源不存在则跳过（面板可选）
            val top = assets.list(UI_ASSET) ?: return
            if (top.isEmpty()) return
            if (target.exists()) target.deleteRecursively()
            target.mkdirs()
            copyAssetDir(context, UI_ASSET, target)
            android.util.Log.i(TAG, "zashboard 已就位: ${target.absolutePath}")
        } catch (e: Exception) {
            android.util.Log.w(TAG, "解压 zashboard 失败: ${e.message}")
        }
    }

    private fun copyAssetDir(context: Context, assetPath: String, target: File) {
        val assets = context.assets
        val children = assets.list(assetPath) ?: return
        if (children.isEmpty()) {
            // 叶子（文件）
            target.parentFile?.mkdirs()
            assets.open(assetPath).use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
            return
        }
        target.mkdirs()
        for (child in children) {
            copyAssetDir(context, "$assetPath/$child", File(target, child))
        }
    }
}
