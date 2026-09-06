package xyz.linplayer.app.data

import android.content.Context
import androidx.compose.runtime.mutableStateOf

/**
 * **纯呈现的、只属于这一台设备的**偏好。
 *
 * 规矩是「一切持久化归核心层」(`SPEC.md` §8.5),这里是一个有边界的例外:
 * 深浅色覆盖既没有核心层命令能存(`prefs.setPrefs` 只认
 * `audio_lang` / `sub_lang` / `sub_enabled`),也**不该**跨设备同步 ——
 * 手机上想强制深色不代表电视上也要。它和「我在哪一页、滚到哪」是同一类东西。
 *
 * ☠ **这里只放这一类。** 任何有核心层消费点的东西都不许进来:
 * 放进来的那一刻,它就变成一个「设了但核心层不知道」的开关 ——
 * 而那正是本仓库最难查的一类 bug。
 */
object UiPrefs {
    private const val FILE = "lp_ui"
    private const val K_THEME = "theme"
    private const val K_ENGINE = "engine"

    /** `system` / `dark` / `light`。 */
    val theme = mutableStateOf("system")

    /**
     * 播放内核:`mpv` / `exo`。
     *
     * ★ 它进这里是因为**「哪个内核能在这台机器上出画面」是设备属性,不是账号属性**
     *   —— 手机上 mpv 出「有声音没画面」不代表电视上也会。跨设备同步它反而害人。
     * ★ 值只是**发给 `player.play` 的一个参数**,核心层不存它,所以不违反
     *   「一切持久化归核心层」:这里没有第二个真相。
     */
    val engine = mutableStateOf("mpv")

    fun load(ctx: Context) {
        val sp = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        theme.value = sp.getString(K_THEME, "system") ?: "system"
        engine.value = sp.getString(K_ENGINE, "mpv") ?: "mpv"
    }

    fun setTheme(ctx: Context, v: String) {
        theme.value = v
        ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit().putString(K_THEME, v).apply()
    }

    fun setEngine(ctx: Context, v: String) {
        engine.value = v
        ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit().putString(K_ENGINE, v).apply()
    }
}
