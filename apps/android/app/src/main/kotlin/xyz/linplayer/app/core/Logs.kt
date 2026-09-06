package xyz.linplayer.app.core

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 落盘日志。
 *
 * ☠ 安卓上 `logcat` 用户拿不到,而 release 构建里 `Log.d` 连 logcat 都不进 ——
 * 于是「起播黑屏」「字幕不出来」这类只在真机上现形的问题**一点线索都留不下**,
 * 只能靠猜。用户为此明说过一次:「我都不知道怎么让你更好的修问题了」。
 *
 * 目录取 [Context.getExternalFilesDir]:那就是 `Android/data/<包名>/files`,
 * 用户能用文件管理器 / USB 直接拿走。取不到(没有外置存储)才回落到私有目录 ——
 * 回落之后文件管理器进不去,所以导出那条路([dump] + SAF)是必须有的,不是备选。
 */
object Logs {

    /** 单个文件的上限。到了就轮转成 `.1`,总占用最多两倍。 */
    private const val MAX_BYTES = 512 * 1024

    private val stamp = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)
    private val lock = Any()

    @Volatile private var dir: File? = null

    /** 日志目录的绝对路径。还没初始化就是空串。 */
    val dirPath: String get() = dir?.absolutePath ?: ""

    private val cur: File? get() = dir?.let { File(it, "app.log") }
    private val prev: File? get() = dir?.let { File(it, "app.1.log") }

    /**
     * 建目录 + 接管未捕获异常。
     *
     * ★ `getExternalFilesDir` 这一次调用本身就是**目录被创建出来的时机** ——
     *   不调的话 `Android/data/<包名>` 根本不存在,用户翻遍文件管理器也找不到。
     */
    fun init(ctx: Context) {
        val root = runCatching { ctx.getExternalFilesDir(null) }.getOrNull() ?: ctx.filesDir
        val d = File(root, "logs")
        runCatching { d.mkdirs() }
        dir = d
        write("I", "app", "—— 启动 ${ctx.packageName} ——  日志目录 ${d.absolutePath}")

        val prevHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            runCatching { write("E", "crash", "线程 ${t.name} 未捕获异常\n" + Log.getStackTraceString(e)) }
            prevHandler?.uncaughtException(t, e)
        }
    }

    fun d(tag: String, msg: String) { Log.d(tag, msg); write("D", tag, msg) }
    fun w(tag: String, msg: String) { Log.w(tag, msg); write("W", tag, msg) }
    fun e(tag: String, msg: String) { Log.e(tag, msg); write("E", tag, msg) }

    private fun write(level: String, tag: String, msg: String) {
        val f = cur ?: return
        synchronized(lock) {
            runCatching {
                if (f.length() > MAX_BYTES) {
                    prev?.let { p -> p.delete(); f.renameTo(p) }
                }
                f.appendText("${stamp.format(Date())} $level/$tag: $msg\n")
            }
        }
    }

    /**
     * 一份可以直接发出去的完整日志。
     *
     * 三段拼在一起:轮转掉的上一份、当前这份、以及 `logcat -d`。
     * ★ 带 logcat 的理由是**原生那半边只往 logcat 写** ——
     *   libass(`lp-libass`)、mpv、MediaCodec、native 崩溃栈都在那里,
     *   只导我们自己写的这份等于把最关键的一半漏掉。
     *   进程读自己的 logcat 不需要任何权限。
     */
    fun dump(): String = buildString {
        append("== 日志目录 ==\n").append(dirPath).append("\n\n")
        synchronized(lock) {
            prev?.takeIf { it.exists() }?.let { append("== app.1.log ==\n").append(it.readText()).append('\n') }
            cur?.takeIf { it.exists() }?.let { append("== app.log ==\n").append(it.readText()).append('\n') }
        }
        append("\n== logcat ==\n").append(logcat())
    }

    private fun logcat(): String = runCatching {
        val p = Runtime.getRuntime().exec(arrayOf("logcat", "-d", "-v", "time", "-t", "3000"))
        val out = p.inputStream.bufferedReader().readText()
        p.destroy()
        out
    }.getOrElse { "取不到 logcat: $it" }
}
