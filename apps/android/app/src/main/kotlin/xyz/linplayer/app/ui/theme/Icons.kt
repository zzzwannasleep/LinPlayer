package xyz.linplayer.app.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.dp

/*
 * 图标:**单一线性族,strokeWidth 1.9,24×24 网格,圆头圆角**(UI_MOBILE.md §1.4)。
 *
 * ★ 不引 material-icons-extended:那个 artifact 几 MB、1000+ 个图标,
 *   而我们用到的不到 40 个;而且它是 Material 填充风,和线性族混一起一眼能看出两套。
 * ★ path 逐字取自 docs/mobile-drafts/icons.js —— 那套是评审过的。
 *   `PathParser` 直接吃 SVG 的 d 属性,所以不需要转换,抄错的机会为零。
 */

private fun icon(name: String, vararg parts: Pair<String, Boolean>): ImageVector {
    val b = ImageVector.Builder(
        name = name, defaultWidth = 24.dp, defaultHeight = 24.dp,
        viewportWidth = 24f, viewportHeight = 24f,
    )
    for ((d, filled) in parts) {
        val nodes = PathParser().parsePathString(d).toNodes()
        if (filled) {
            b.addPath(nodes, fill = SolidColor(Color.Black))
        } else {
            b.addPath(
                nodes, fill = null, stroke = SolidColor(Color.Black), strokeLineWidth = 1.9f,
                strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
            )
        }
    }
    return b.build()
}

private fun stroke(name: String, d: String) = icon(name, d to false)
private fun fill(name: String, d: String) = icon(name, d to true)

object LpIcons {
    val home = stroke("home", "M3 10.5 12 3l9 7.5M5.5 9.5V20a1 1 0 0 0 1 1H10v-6h4v6h3.5a1 1 0 0 0 1-1V9.5")
    val homeOn = fill("homeOn", "M3 10.5 12 3l9 7.5v9.5a1 1 0 0 1-1 1h-5v-6h-4v6H4a1 1 0 0 1-1-1z")
    val search = stroke("search", "M18 11a7 7 0 1 1-14 0 7 7 0 0 1 14 0M20 20l-3.5-3.5")
    val settings = stroke("settings", "M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1A1.7 1.7 0 0 0 8.9 19a1.7 1.7 0 0 0-1.9.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.9 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1A1.7 1.7 0 0 0 5 8.9a1.7 1.7 0 0 0-.3-1.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.9.3h.1a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.9-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.9v.1a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z")
    val back = stroke("back", "m15 5-7 7 7 7")
    val play = fill("play", "M7 4.5 19.5 12 7 19.5z")
    val pause = fill("pause", "M6.5 4.5h4v15h-4zM13.5 4.5h4v15h-4z")
    val heart = stroke("heart", "M12 20s-7.5-4.6-7.5-9.6A4.4 4.4 0 0 1 12 7.6a4.4 4.4 0 0 1 7.5 2.8C19.5 15.4 12 20 12 20z")
    val heartOn = fill("heartOn", "M12 20s-7.5-4.6-7.5-9.6A4.4 4.4 0 0 1 12 7.6a4.4 4.4 0 0 1 7.5 2.8C19.5 15.4 12 20 12 20z")
    val check = stroke("check", "m5 12.5 4.5 4.5L19 7")
    val download = stroke("download", "M12 3v12m-5-4 5 5 5-5M4 20h16")
    val more = fill("more", "M13.6 5a1.6 1.6 0 1 1-3.2 0 1.6 1.6 0 0 1 3.2 0M13.6 12a1.6 1.6 0 1 1-3.2 0 1.6 1.6 0 0 1 3.2 0M13.6 19a1.6 1.6 0 1 1-3.2 0 1.6 1.6 0 0 1 3.2 0")
    val chevR = stroke("chevR", "m9 5 7 7-7 7")
    val chevD = stroke("chevD", "m5 9 7 7 7-7")
    val close = stroke("close", "M6 6l12 12M18 6 6 18")
    val list = stroke("list", "M8 6h13M8 12h13M8 18h13M3.6 5.4v1.2M3.6 11.4v1.2M3.6 17.4v1.2")
    val grid = stroke("grid", "M3.5 5.1a1.6 1.6 0 0 1 1.6-1.6h3.8a1.6 1.6 0 0 1 1.6 1.6v3.8a1.6 1.6 0 0 1-1.6 1.6H5.1a1.6 1.6 0 0 1-1.6-1.6zM13.5 5.1a1.6 1.6 0 0 1 1.6-1.6h3.8a1.6 1.6 0 0 1 1.6 1.6v3.8a1.6 1.6 0 0 1-1.6 1.6h-3.8a1.6 1.6 0 0 1-1.6-1.6zM3.5 15.1a1.6 1.6 0 0 1 1.6-1.6h3.8a1.6 1.6 0 0 1 1.6 1.6v3.8a1.6 1.6 0 0 1-1.6 1.6H5.1a1.6 1.6 0 0 1-1.6-1.6zM13.5 15.1a1.6 1.6 0 0 1 1.6-1.6h3.8a1.6 1.6 0 0 1 1.6 1.6v3.8a1.6 1.6 0 0 1-1.6 1.6h-3.8a1.6 1.6 0 0 1-1.6-1.6z")
    val filter = stroke("filter", "M3 6h18M6.5 12h11M10 18h4")
    val sort = stroke("sort", "M7 4v16M7 20l-3.2-3.2M7 20l3.2-3.2M17 20V4M17 4l-3.2 3.2M17 4l3.2 3.2")
    val rewind = fill("rewind", "M11 6 4 12l7 6zM20 6l-7 6 7 6z")
    val forward = fill("forward", "m13 6 7 6-7 6zM4 6l7 6-7 6z")
    val sub = stroke("sub", "M2.5 7.6a2.6 2.6 0 0 1 2.6-2.6h13.8a2.6 2.6 0 0 1 2.6 2.6v8.8a2.6 2.6 0 0 1-2.6 2.6H5.1a2.6 2.6 0 0 1-2.6-2.6zM6.5 14.5h4M13.5 14.5h4M6.5 10.5h11")
    val audio = stroke("audio", "M4 9.5v5h3.5l4.5 4V5.5l-4.5 4zM15.5 9.2a4 4 0 0 1 0 5.6M18.4 6.6a8 8 0 0 1 0 10.8")
    val version = stroke("version", "M3 6.2A2.2 2.2 0 0 1 5.2 4h13.6A2.2 2.2 0 0 1 21 6.2v7.6a2.2 2.2 0 0 1-2.2 2.2H5.2A2.2 2.2 0 0 1 3 13.8zM8 20h8M12 16v4")
    val line = stroke("line", "M12 20v-5M4.5 9a10 10 0 0 1 15 0M7.5 12.5a6 6 0 0 1 9 0M14 17.5a2 2 0 1 1-4 0 2 2 0 0 1 4 0")
    val sparkle = stroke("sparkle", "M12 3.5 13.8 9l5.5 1.8-5.5 1.8L12 18l-1.8-5.4L4.7 10.8 10.2 9zM18.5 3v3M20 4.5h-3")
    val danmaku = stroke("danmaku", "M2.5 7.1a2.6 2.6 0 0 1 2.6-2.6h13.8a2.6 2.6 0 0 1 2.6 2.6v9.8a2.6 2.6 0 0 1-2.6 2.6H5.1a2.6 2.6 0 0 1-2.6-2.6zM6 9h7M6 12.5h4M14 12.5h4M6 16h9")
    val lock = stroke("lock", "M4.5 12.9a2.4 2.4 0 0 1 2.4-2.4h10.2a2.4 2.4 0 0 1 2.4 2.4v5.2a2.4 2.4 0 0 1-2.4 2.4H6.9a2.4 2.4 0 0 1-2.4-2.4zM8 10.5V7.6a4 4 0 0 1 8 0v2.9")
    val unlock = stroke("unlock", "M4.5 12.9a2.4 2.4 0 0 1 2.4-2.4h10.2a2.4 2.4 0 0 1 2.4 2.4v5.2a2.4 2.4 0 0 1-2.4 2.4H6.9a2.4 2.4 0 0 1-2.4-2.4zM8 10.5V7.6a4 4 0 0 1 7.6-1.8")
    val server = stroke("server", "M3 6a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2zM3 15a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2zM8.1 7.5a1.1 1.1 0 1 1-2.2 0 1.1 1.1 0 0 1 2.2 0M8.1 16.5a1.1 1.1 0 1 1-2.2 0 1.1 1.1 0 0 1 2.2 0")
    val cloud = stroke("cloud", "M7 18h10a4 4 0 0 0 .6-7.96A6 6 0 0 0 6.1 11 3.5 3.5 0 0 0 7 18z")
    val plugin = stroke("plugin", "M9 3v4M15 3v4M5.5 7h13v6a6.5 6.5 0 0 1-13 0zM12 19.5V21")
    val calendar = stroke("calendar", "M3.5 7.4A2.4 2.4 0 0 1 5.9 5h12.2a2.4 2.4 0 0 1 2.4 2.4v11.2a2.4 2.4 0 0 1-2.4 2.4H5.9a2.4 2.4 0 0 1-2.4-2.4zM3.5 10h17M8 3v4M16 3v4")
    val trophy = stroke("trophy", "M7 4h10v5a5 5 0 0 1-10 0zM7 6H4.5v1.5A3.5 3.5 0 0 0 8 11M17 6h2.5v1.5A3.5 3.5 0 0 1 16 11M12 14v3M8.5 20h7")
    val folder = stroke("folder", "M3.5 7.5A2 2 0 0 1 5.5 5.5h3.6l2 2.4h7.4a2 2 0 0 1 2 2v8.6a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z")
    val file = stroke("file", "M13.5 3.5H7a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9zM13.5 3.5V9H19")
    val trash = stroke("trash", "M4 6.5h16M9.5 6.5V4.5h5v2M6.5 6.5l1 13.5h9l1-13.5")
    val plus = stroke("plus", "M12 5v14M5 12h14")
    val minus = stroke("minus", "M5 12h14")
    val refresh = stroke("refresh", "M20 11a8 8 0 1 0-.6 4M20 5v6h-6")
    val inbox = stroke("inbox", "M3.5 13.5h4l1.5 3h6l1.5-3h4M5.6 4.8 3.5 13.5v4a2 2 0 0 0 2 2h13a2 2 0 0 0 2-2v-4L18.4 4.8a2 2 0 0 0-1.9-1.3h-9a2 2 0 0 0-1.9 1.3z")
    val star = stroke("star", "m12 4 2.4 5 5.6.8-4 3.9 1 5.5-5-2.6-5 2.6 1-5.5-4-3.9 5.6-.8z")
    val info = stroke("info", "M20.5 12a8.5 8.5 0 1 1-17 0 8.5 8.5 0 0 1 17 0M12 11v5.5M12 7.4v1")
    val grip = stroke("grip", "M8 5.9v.2M8 11.9v.2M8 17.9v.2M16 5.9v.2M16 11.9v.2M16 17.9v.2")
    val pencil = stroke("pencil", "M4 20h4L19.5 8.5a2.1 2.1 0 0 0-3-3L5 17zM14.5 6.5l3 3")
    val image = stroke("image", "M3.5 6.9A2.4 2.4 0 0 1 5.9 4.5h12.2a2.4 2.4 0 0 1 2.4 2.4v10.2a2.4 2.4 0 0 1-2.4 2.4H5.9a2.4 2.4 0 0 1-2.4-2.4zM10.8 10a1.8 1.8 0 1 1-3.6 0 1.8 1.8 0 0 1 3.6 0m-6.3 7 4.2-4.2 3.3 3.3 3-3 4.5 4.4")
    val globe = stroke("globe", "M20.5 12a8.5 8.5 0 1 1-17 0 8.5 8.5 0 0 1 17 0M3.5 12h17M12 3.5a13 13 0 0 1 0 17 13 13 0 0 1 0-17z")
    val sync = stroke("sync", "M4 10a8 8 0 0 1 13.7-4.4L20 8M20 4v4h-4M20 14a8 8 0 0 1-13.7 4.4L4 16M4 20v-4h4")
    val camera = stroke("camera", "M3.5 8.5a2 2 0 0 1 2-2h1.9l1.3-2h6.6l1.3 2h1.9a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2zM15.4 12.5a3.4 3.4 0 1 1-6.8 0 3.4 3.4 0 0 1 6.8 0")
    val aspect = stroke("aspect", "M3.5 6.5h17v11h-17zM7 10v4M17 10v4")
}
