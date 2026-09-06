package xyz.linplayer.app.ui.pages

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavController
import androidx.navigation.toRoute
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import xyz.linplayer.app.data.Account
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.ToastKind
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.dbl
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.BtnKind
import xyz.linplayer.app.ui.components.Body
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.Hairline
import xyz.linplayer.app.ui.components.LpButton
import xyz.linplayer.app.ui.components.LpDialog
import xyz.linplayer.app.ui.components.LpField
import xyz.linplayer.app.ui.components.LpIconButton
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.Panel
import xyz.linplayer.app.ui.components.rememberScrolled
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp

/**
 * 服务器管理(U1.9b)· 底栏第三个 Tab。
 *
 * ★ **点 = 切到这台,长按 = 操作菜单**【用户定 2026-09-06】。原来两者都弹菜单 ——
 *   于是这一页最高频的动作(换一台看)要两步,而最低频的(删)只要一步。
 * ★ 状态点 = 连通健康,不是「选中」(选中看「当前」角标)。
 *   `down`(探过确实不通)与 `unknown`(还没探过)**同色不同义** ——
 *   手机没有悬停,所以**直接把文字写在卡片上**。
 * ★ 服务器图标走 `account.icon`:它自己会依次试用户头像和几条官方静态图标地址。
 */
@Composable
fun ServersPage(nav: NavController) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    val haptic = LocalHapticFeedback.current

    var accounts by remember { mutableStateOf<List<Account>>(emptyList()) }
    var status by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var menuFor by remember { mutableStateOf<Account?>(null) }
    var editFor by remember { mutableStateOf<Account?>(null) }
    var confirmDelete by remember { mutableStateOf<Account?>(null) }
    var reload by remember { mutableStateOf(0) }

    LaunchedEffect(reload) {
        accounts = Account.list(runCatching { app.call("account.listAccounts") }.getOrNull())
        // 连通状态**异步**探测:未探时是「未检测」不是「不通」
        launch {
            runCatching {
                app.call("account.probeAccounts", null, onPartial = { p ->
                    val o = p as? JsonObject
                    val id = o.str("server_id") ?: o.str("server")
                    if (id != null) status = status + (id to (o.str("state") ?: "unknown"))
                })
            }
        }
    }
    LaunchedEffect(Unit) { app.invalidate.collect { if (it == "accounts" || it == "all") reload++ } }

    val switchTo: (Account) -> Unit = { a ->
        scope.launch {
            runCatching { app.call("account.setActiveServer", args("server_id" to a.id)) }
                .onSuccess { app.refreshSession(); reload++; app.toast("已切到「${a.name}」", ToastKind.Ok) }
                .onFailure { app.report(it) }
        }
    }

    LpScaffold("服务器", scrolled = rememberScrolled(list), actions = {
        LpIconButton(LpIcons.plus, "添加服务器") { nav.navigate(Route.AddServer) }
        LpIconButton(LpIcons.settings, "设置") { nav.navigate(Route.Settings) }
    }) { pad ->
        if (accounts.isEmpty()) {
            EmptyState("还没有添加服务器", "添加一台 Emby 服务器就能开始看了。", LpIcons.server,
                "添加服务器", onAction = { nav.navigate(Route.AddServer) })
            return@LpScaffold
        }
        LazyColumn(Modifier.fillMaxSize(), list, contentPadding = pad) {
            items(accounts, key = { it.id }) { a ->
                Box {
                    ServerCard(
                        a, status[a.id], a.isActive,
                        onTap = { if (!a.isActive) switchTo(a) },
                        onLong = {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            menuFor = a
                        },
                    )
                    DropdownMenu(menuFor?.id == a.id, { menuFor = null },
                        modifier = Modifier.background(Lp.colors.s3)) {
                        if (!a.isActive) Item2("设为当前") { switchTo(a) }
                        Item2("编辑") { editFor = a }
                        Item2("服务器线路") { nav.navigate(Route.Lines(a.id, a.name)) }
                        Item2("删除", danger = true) { confirmDelete = a }
                    }
                }
            }
            item("hint") {
                Dim3("点一下切换服务器,长按弹出操作菜单。",
                    Modifier.padding(horizontal = Sp.x26, vertical = Sp.x12))
            }
            item("tail") { Spacer(Modifier.height(Sp.x26)) }
        }
    }

    editFor?.let { a -> EditDialog(a, { editFor = null }) { reload++ } }

    // 不可逆的删除是**需要二次确认的三类之一**(UI_MOBILE.md §6.2)
    confirmDelete?.let { a ->
        LpDialog({ confirmDelete = null }, "删除「${a.name}」?") {
            Body("这台服务器的账号、备注、图标和线路都会一起删掉。已下载的文件不受影响。")
            Spacer(Modifier.height(Sp.x16))
            Row(horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
                LpButton("取消", { confirmDelete = null }, Modifier.weight(1f), BtnKind.Secondary)
                LpButton("删除", {
                    scope.launch {
                        runCatching { app.call("account.removeAccount", args("server_id" to a.id)) }
                            .onSuccess { reload++; app.refreshSession() }
                            .onFailure { app.report(it) }
                        confirmDelete = null
                    }
                }, Modifier.weight(1f), BtnKind.Danger)
            }
        }
    }
}

/**
 * 服务器图标。
 *
 * ★ `account.icon` 回的是 **data URI**,不是可以直接丢给 Coil 的 http 地址 ——
 *   所以这里自己 base64 解一次再解码成位图。
 * ★ 取不到是**常态**(没头像、没 touchicon、离线),回落成那颗琥珀图标,一个字都不报。
 * ★ 结果按 serverId 缓存在 composition 之外:这一页每次重组都发一次请求的话,
 *   探测和列表刷新会把它打成一串重复网络请求。
 */
private val iconCache = HashMap<String, ImageBitmap?>()

@Composable
private fun rememberServerIcon(serverId: String): ImageBitmap? {
    val app = LocalApp.current
    var img by remember(serverId) { mutableStateOf(iconCache[serverId]) }
    LaunchedEffect(serverId) {
        if (iconCache.containsKey(serverId)) return@LaunchedEffect
        val uri = runCatching { app.call("account.icon", args("server_id" to serverId)) }
            .getOrNull().obj().str("data_uri")
        val bmp = uri?.substringAfter("base64,", "")?.takeIf { it.isNotEmpty() }?.let { b64 ->
            runCatching {
                val bytes = android.util.Base64.decode(b64, android.util.Base64.DEFAULT)
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
            }.getOrNull()
        }
        iconCache[serverId] = bmp
        img = bmp
    }
    return img
}

@Composable
private fun ServerCard(
    a: Account,
    state: String?,
    active: Boolean,
    onTap: () -> Unit,
    onLong: () -> Unit,
) {
    val c = Lp.colors
    val icon = rememberServerIcon(a.id)
    // ★ 服务器卡**不要太透**【用户定 2026-09-06】—— 玻璃调实一点,别让底下的东西透上来
    Panel(Modifier.padding(horizontal = Sp.x16, vertical = Sp.x6), solid = 1.4f) {
        Row(
            Modifier.fillMaxWidth().combinedClickable(onClick = onTap, onLongClick = onLong)
                .padding(Sp.x16),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(36.dp).clip(RoundedCornerShape(R.sm)).background(c.accDim),
                contentAlignment = Alignment.Center,
            ) {
                if (icon != null) Image(icon, null, Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop)
                else Icon(LpIcons.server, null, Modifier.size(20.dp), tint = c.acc)
            }
            Spacer(Modifier.padding(horizontal = Sp.x6))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Body(a.name, maxLines = 1)
                    if (active) {
                        Spacer(Modifier.padding(horizontal = Sp.x4))
                        Text("当前", Modifier.clip(RoundedCornerShape(R.sm))
                            .background(c.accDim).padding(horizontal = 6.dp, vertical = 1.dp),
                            color = c.acc, fontSize = 10.sp)
                    }
                }
                // ★ 状态**写成文字**:down 和 unknown 同色不同义,手机没有悬停可以区分
                Dim3(when (state) {
                    "up" -> "已连接" + (a.userName?.let { " · $it" } ?: "")
                    "down" -> "连不上"
                    else -> "未检测" + (a.userName?.let { " · $it" } ?: "")
                }, Modifier.padding(top = Sp.x2))
                a.remark?.takeIf { it.isNotBlank() }?.let { Dim3(it, Modifier.padding(top = Sp.x2)) }
            }
            Box(Modifier.size(8.dp).clip(RoundedCornerShape(R.pill)).background(
                when (state) { "up" -> c.ok; "down" -> c.bad; else -> c.line2 }
            ))
        }
    }
}

/**
 * 编辑弹窗。字段顺序【用户定】:服务器名称 / 账号 / 密码 / 备注。
 *
 * ☠ **没有地址行** —— 「服务器地址是『服务器线路』里面填写的」。
 * ☠ **改账号 / 密码必须走 `emby.relogin`(真登一次换 token),不是 `emby.login`。**
 * 后者是 Upsert 语义;只改字段不重登 = token 还是旧用户的,
 * 表现为「显示新账号、媒体库还是旧账号的」,而且不报错。
 */
@Composable
private fun EditDialog(a: Account, onClose: () -> Unit, onSaved: () -> Unit) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(a.name) }
    var user by remember { mutableStateOf(a.userName.orEmpty()) }
    var pass by remember { mutableStateOf("") }
    var remark by remember { mutableStateOf(a.remark.orEmpty()) }
    var busy by remember { mutableStateOf(false) }

    LpDialog(onClose, "编辑服务器") {
        LpField(name, { name = it }, "服务器名称", label = "服务器名称")
        Spacer(Modifier.height(Sp.x10))
        LpField(user, { user = it }, "账号", label = "账号")
        Spacer(Modifier.height(Sp.x10))
        LpField(pass, { pass = it }, "留空则不改", password = true, label = "密码")
        Spacer(Modifier.height(Sp.x10))
        LpField(remark, { remark = it }, "给自己看的备注", label = "备注")
        Spacer(Modifier.height(Sp.x16))
        Row(horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
            LpButton("取消", onClose, Modifier.weight(1f), BtnKind.Secondary)
            LpButton("保存", {
                busy = true
                scope.launch {
                    runCatching {
                        app.call("account.updateAccount",
                            args("server_id" to a.id, "name" to name, "remark" to remark))
                        // 账号 / 密码变了才 relogin,而且必须**在 updateAccount 之后**
                        if (pass.isNotBlank() || user != a.userName.orEmpty()) {
                            app.call("emby.relogin",
                                args("server_id" to a.id, "username" to user, "password" to pass))
                        }
                    }.onSuccess { onSaved(); app.refreshSession(); onClose() }
                        .onFailure { app.report(it) }
                    busy = false
                }
            }, Modifier.weight(1f), loading = busy)
        }
    }
}

/** 一条线路。`synthetic` = 账号根本没有线路表,这一行是补出来的主线,不能改名。 */
private data class Line(
    val index: Int, val url: String, val name: String,
    val active: Boolean, val synthetic: Boolean = false,
)

/**
 * 服务器线路(U1.9b)。
 *
 * ★ **要显示具体地址**【用户 2026-09-06 改口:之前定的是「任何地方不展示线路地址」】。
 *   只写「线路一 / 线路二 / 生效中」的时候,用户根本认不出哪条是哪条 ——
 *   两条名字一样的线路在界面上是同一行。
 * ★ **长按改名** —— 核心层只有整表替换(`account.setLines`),所以改一条名字
 *   要把整张表原样送回去。★ 它按 **url** 找回生效线路,所以改名不会把当前线路切走。
 * ★ 「同步线路」和「测延迟」是**两个按钮两回事**。
 * ★ 服主没部署同步服务是常态,**404 不能当错误弹**。
 */
@Composable
fun LinesPage(nav: NavController, entry: NavBackStackEntry) {
    val route = entry.toRoute<Route.Lines>()
    val app = LocalApp.current
    val scope = rememberCoroutineScope()

    var lines by remember { mutableStateOf<List<Line>>(emptyList()) }
    var latency by remember { mutableStateOf<Map<String, Long?>>(emptyMap()) }
    var renaming by remember { mutableStateOf<Line?>(null) }
    var reload by remember { mutableStateOf(0) }

    /* ☠ 线路表**从账号里读,不从 probeLines 读**:`LineProbe` 只发 index / ms / url,
       没有 name 也没有 active。照那两个不存在的字段取值 = 线路名恒「线路 N」、
       当前线路永远标不出来 —— 上一版就是这样。探测那条命令只负责延迟。 */
    LaunchedEffect(reload) {
        val acc = runCatching { app.call("account.listAccounts") }.getOrNull()
            .arr().firstOrNull { it.obj().str("server") == route.serverId }.obj()
        val activeIndex = acc.long("active_line")?.toInt() ?: 0
        lines = acc?.get("lines").arr().mapIndexedNotNull { i, e ->
            val o = e.obj() ?: return@mapIndexedNotNull null
            val url = o.str("url") ?: return@mapIndexedNotNull null
            Line(i, url, o.str("name")?.takeIf { it.isNotBlank() } ?: "线路 ${i + 1}",
                i == activeIndex)
        }
        // 线路表为空 = 单线路形态,补出一行可见主线(它不在表里,所以不能改名)
        if (lines.isEmpty()) {
            lines = listOf(Line(0, route.serverId, "主线路", true, synthetic = true))
        }
    }

    suspend fun saveNames(updated: List<Line>) {
        val payload = JsonObject(mapOf(
            "server_id" to JsonPrimitive(route.serverId),
            "lines" to JsonArray(updated.map {
                JsonObject(mapOf(
                    "name" to JsonPrimitive(it.name),
                    "url" to JsonPrimitive(it.url),
                ))
            }),
        ))
        app.call("account.setLines", payload)
    }

    LpScaffold(route.name, subtitle = "服务器线路", onBack = { nav.popBackStack() }, scrolled = true) { pad ->
        Column(Modifier.fillMaxSize().padding(pad)) {
            Row(Modifier.padding(Sp.x16), horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
                LpButton("同步线路", {
                    scope.launch {
                        runCatching { app.call("account.syncLines", args("server_id" to route.serverId)) }
                            .onSuccess { reload++; app.toast("线路已同步", ToastKind.Ok) }
                            // 404 是常态:服主没部署同步服务。不当错误弹
                            .onFailure { e ->
                                val code = (e as? xyz.linplayer.app.core.CoreException)?.code
                                if (code == "E_NOTFOUND") app.toast("这台服务器没有提供线路同步")
                                else app.report(e)
                            }
                    }
                }, kind = BtnKind.Secondary)
                LpButton("测延迟", {
                    scope.launch {
                        lines.forEach { l ->
                            latency = latency + (l.url to null)
                            val r = runCatching {
                                app.call("account.probeLine",
                                    args("server_id" to route.serverId, "index" to l.index))
                            }.getOrNull()
                            latency = latency + (l.url to (r.obj().dbl("ms")?.toLong()))
                        }
                    }
                }, kind = BtnKind.Secondary)
            }
            Panel(Modifier.padding(horizontal = Sp.x16)) {
                lines.forEach { l ->
                    if (l.index > 0) Hairline()
                    LineRow(
                        l,
                        // 三态:未探(空)/ 探过不通(「—」,**不装成 0 ms**)/ 毫秒数
                        ms = latency[l.url]?.let { "$it ms" } ?: if (l.url in latency) "—" else "",
                        onTap = {
                            scope.launch {
                                runCatching {
                                    app.call("account.setActiveLine",
                                        args("server_id" to route.serverId, "index" to l.index))
                                }.onSuccess { reload++; app.refreshSession() }
                                    .onFailure { app.report(it) }
                            }
                        },
                        onLong = { if (!l.synthetic) renaming = l },
                    )
                }
            }
            Dim3("点一下切到这条线路,长按改名。",
                Modifier.padding(horizontal = Sp.x26, vertical = Sp.x12))
        }
    }

    renaming?.let { l ->
        var name by remember(l.index) { mutableStateOf(l.name) }
        LpDialog({ renaming = null }, "线路改名") {
            LpField(name, { name = it }, "给这条线路起个名字", label = "名称")
            Spacer(Modifier.height(Sp.x16))
            Row(horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
                LpButton("取消", { renaming = null }, Modifier.weight(1f), BtnKind.Secondary)
                LpButton("保存", {
                    scope.launch {
                        runCatching {
                            saveNames(lines.map { if (it.index == l.index) it.copy(name = name) else it })
                        }.onSuccess { renaming = null; reload++ }.onFailure { app.report(it) }
                    }
                }, Modifier.weight(1f))
            }
        }
    }
}

/** 线路一行:名字 + **真实地址** + 延迟。地址用等宽小字,一行放不下就掐中间。 */
@Composable
private fun LineRow(l: Line, ms: String, onTap: () -> Unit, onLong: () -> Unit) {
    val c = Lp.colors
    Row(
        Modifier.fillMaxWidth().combinedClickable(onClick = onTap, onLongClick = onLong)
            .padding(horizontal = Sp.x16, vertical = Sp.x12),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Body(l.name, maxLines = 1)
                if (l.active) {
                    Spacer(Modifier.padding(horizontal = Sp.x4))
                    Text("生效中", Modifier.clip(RoundedCornerShape(R.sm))
                        .background(c.accDim).padding(horizontal = 6.dp, vertical = 1.dp),
                        color = c.acc, fontSize = 10.sp)
                }
            }
            Text(
                l.url, color = c.fg3, fontSize = 11.5.sp, maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                modifier = Modifier.padding(top = Sp.x2),
            )
        }
        if (ms.isNotEmpty()) Dim3(ms, Modifier.padding(start = Sp.x8))
    }
}

@Composable
private fun Item2(label: String, danger: Boolean = false, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(label, color = if (danger) Lp.colors.bad else Lp.colors.fg, fontSize = 14.sp) },
        onClick = onClick,
    )
}
