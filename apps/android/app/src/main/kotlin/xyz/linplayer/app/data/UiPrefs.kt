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

    /** `system` / `dark` / `light`。 */
    val theme = mutableStateOf("system")

    fun load(ctx: Context) {
        theme.value = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .getString(K_THEME, "system") ?: "system"
    }

    fun setTheme(ctx: Context, v: String) {
        theme.value = v
        ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit().putString(K_THEME, v).apply()
    }
}
