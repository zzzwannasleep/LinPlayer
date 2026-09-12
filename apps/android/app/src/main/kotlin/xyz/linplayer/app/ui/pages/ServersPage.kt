package xyz.linplayer.app.ui.pages

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
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
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavController
import androidx.navigation.toRoute
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.Account
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.ToastKind
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.dbl
import xyz.linplayer.app.data.long
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.LongShotTarget
import xyz.linplayer.app.ui.components.BtnKind
import xyz.linplayer.app.ui.components.Body
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.Hairline
import xyz.linplayer.app.ui.components.LpButton
import xyz.linplayer.app.ui.components.LpDialog
import xyz.linplayer.app.ui.components.LpField
import xyz.linplayer.app.ui.components.LpIconButton
import xyz.linplayer.app.ui.components.LpMenu
import xyz.linplayer.app.ui.components.LpMenuItem
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.Panel
import xyz.linplayer.app.ui.components.rememberScrolled
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp
import xyz.linplayer.app.ui.components.Dim2
import xyz.linplayer.app.data.strList
import coil3.compose.AsyncImage
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.clickable
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.rememberLauncherForActivityResult

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
    // 截长屏认的就是这个滚动容器(设置里开了才画按钮,见 LongShot)
    LongShotTarget(list)

    val haptic = LocalHapticFeedback.current

    var accounts by remember { mutableStateOf<List<Account>>(emptyList()) }
    var status by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var menuFor by remember { mutableStateOf<Account?>(null) }
    var editFor by remember { mutableStateOf<Account?>(null) }
    var iconFor by remember { mutableStateOf<Account?>(null) }
    var confirmDelete by remember { mutableStateOf<Account?>(null) }
    var reload by remember { mutableStateOf(0) }

    LaunchedEffect(reload) {
        accounts = Account.list(runCatching { app.call("account.listAccounts") }.getOrNull())
        /* 连通状态**异步**探测:未探时是「未检测」不是「不通」。
           ☠ 这里原来挂的是 `onPartial`,而**整个核心层只有一处在发 partial**
           (core/system),这条命令一次都不发 —— 回调永远不触发,那几个状态点
           从上线起就是空的。而且它读的 `server_id` / `state` 也不存在:
           真实字段是 server / ok / ms / error。同一类错(聚合页、搜索页)已经栽过两次。 */
        launch {
            val probed = runCatching { app.call("account.probeAccounts") }.getOrNull().arr()
            status = status + probed.mapNotNull { e ->
                val o = e.obj() ?: return@mapNotNull null
                val id = o.str("server") ?: return@mapNotNull null
                id to if (o.bool("ok")) "ok" else "down"
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
                    var at by remember(a.id) { mutableStateOf(IntOffset.Zero) }
                    val inset = with(LocalDensity.current) {
                        IntOffset(Sp.x16.roundToPx(), Sp.x6.roundToPx())
                    }
                    ServerCard(
                        a, status[a.id], a.isActive,
                        onTap = { if (!a.isActive) switchTo(a) },
                        onLong = { p ->
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            at = IntOffset(p.x.toInt() + inset.x, p.y.toInt() + inset.y)
                            menuFor = a
                        },
                    )
                    /* ☠ 这里原来是 M3 的 `DropdownMenu` —— 方盘、平淡的 fade、
                       和这一套玻璃面完全两回事(用户 2026-09-07 原话「太丑了」)。
                       换成全站共用的 [LpMenu]:同一块玻璃,**从手指落点**长出来。 */
                    LpMenu(menuFor?.id == a.id, { menuFor = null }, Alignment.TopStart, at) {
                        if (!a.isActive) LpMenuItem("设为当前", { menuFor = null; switchTo(a) })
                        LpMenuItem("编辑", { menuFor = null; editFor = a })
                        LpMenuItem("编辑图标", { menuFor = null; iconFor = a })
                        LpMenuItem("服务器线路",
                            { menuFor = null; nav.navigate(Route.Lines(a.id, a.name)) })
                        LpMenuItem("删除", { menuFor = null; confirmDelete = a }, danger = true)
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
    iconFor?.let { a -> IconDialog(a, { iconFor = null }) { iconCache.remove(a.id); reload++ } }

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
internal fun rememberServerIcon(serverId: String): ImageBitmap? {
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
    /** 长按。参数是**手指落点**(卡片自己的坐标系,像素),菜单要从那里长出来。 */
    onLong: (androidx.compose.ui.geometry.Offset) -> Unit,
) {
    val c = Lp.colors
    val icon = rememberServerIcon(a.id)
    // ★ 服务器卡**不要太透**【用户定 2026-09-06】—— 玻璃调实一点,别让底下的东西透上来
    Panel(Modifier.padding(horizontal = Sp.x16, vertical = Sp.x6), solid = 1.4f) {
        Row(
            /* ☠ 手势挂在**这一层**而不是外面那个 Box:坐标要和卡片对齐,
               菜单才会从手指底下长出来(用户 2026-09-07:「不是我手指点哪里
               就从哪里出现的」)。这一层比外层 Box 少了 Panel 的那圈外边距,
               所以调用方要把它补回去 —— 补偿量在 [CardInset]。 */
            Modifier.fillMaxWidth()
                .pointerInput(Unit) {
                    detectTapGestures(onTap = { onTap() }, onLongPress = { onLong(it) })
                }
                .padding(Sp.x16),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            /* ☠ **图标底下不许垫底色**【用户定 2026-09-07】。服务器图标基本都是
               带透明通道的 PNG,垫一块琥珀色进去等于给每台服务器套一个不是它的方框;
               而且 `Crop` 会把非方形的图标切掉两边。透明底 + `Fit`,原样显示。 */
            Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
                if (icon != null) Image(icon, null, Modifier.fillMaxSize(),
                    contentScale = ContentScale.Fit)
                else Icon(LpIcons.server, null, Modifier.size(22.dp), tint = c.acc)
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
                /* ★ 副行只写**备注**【用户定 2026-09-07】。原来这里写的是连通状态,
                   而「未检测」是探测还没回来的中间态 —— 它说的是我们自己的进度,
                   不是用户想知道的事。状态由右边那颗点表示,够了。 */
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

/**
 * 编辑服务器图标
 * 【用户定 2026-09-12:「服务器编辑的弹窗增加编辑图标功能,支持本地添加、网络源添加,
 * 同时允许用户自己添加网络源」】。安卓端此前**一个图标入口都没有**。
 *
 * ★ 内置源的地址**不显示** —— 它走编译期注入,摆到界面上等于把它抄进用户的截图里。
 *   只报条数,和「这个构建没配源」分得开就够了。
 */
@Composable
private fun IconDialog(a: Account, onClose: () -> Unit, onChanged: () -> Unit) {
    val app = LocalApp.current
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var lib by remember { mutableStateOf<JsonObject?>(null) }
    var q by remember { mutableStateOf("") }
    var newSrc by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }

    suspend fun load(force: Boolean) {
        lib = runCatching { app.call("prefs.iconLibrary", args("force" to force)) }.getOrNull().obj()
    }
    LaunchedEffect(Unit) { load(false) }

    /* 本地图片走 SAF。**类型过滤放到最宽**:实测各家文件管理器给图片的 MIME
       五花八门,只收图片类型的表现是「选择器里一张图都看不见」——
       一个打不开的入口。是不是真图片由核心层那一步判。
       ★ 注释里别写「斜杠星」那个通配:Kotlin 的块注释**会嵌套**,
         它会当场再开一层,把后面整个文件吞掉(本轮实测踩过)。 */
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        val path = copyToCache(ctx, uri)
        if (path == null) { app.toast("这张图读不出来", ToastKind.Error); return@rememberLauncherForActivityResult }
        scope.launch {
            runCatching {
                app.call("account.setAccountIconFile", args("server_id" to a.id, "file_path" to path))
            }.onSuccess { onChanged(); app.toast("图标已换", ToastKind.Ok); onClose() }
                .onFailure { app.report(it) }
        }
    }

    suspend fun use(url: String) {
        runCatching {
            // 先清缓存再写地址:不清的话旧图标还在缓存里,选了新的也不换 ——
            // 表现是「点了没反应」,而配置其实已经改了
            app.call("account.clearAccountIcon", args("server_id" to a.id))
            app.call("account.updateAccount", args("server_id" to a.id, "icon_url" to url))
        }.onSuccess { onChanged(); app.toast("图标已换", ToastKind.Ok); onClose() }
            .onFailure { app.report(it) }
    }

    val items = lib?.get("items").arr().mapNotNull { it.obj() }
        .filter { q.isBlank() || (it.str("name") ?: "").contains(q, ignoreCase = true) }
    val sources = lib.strList("sources")
    val builtin = lib.long("builtin") ?: 0L

    LpDialog(onClose, "编辑图标") {
        Row(horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
            LpButton("本地图片", { pick.launch(arrayOf("*/*")) }, Modifier.weight(1f), BtnKind.Secondary)
            LpButton("恢复默认", {
                scope.launch {
                    runCatching {
                        app.call("account.clearAccountIcon", args("server_id" to a.id))
                        app.call("account.updateAccount", args("server_id" to a.id, "icon_url" to ""))
                    }.onSuccess { onChanged(); onClose() }.onFailure { app.report(it) }
                }
            }, Modifier.weight(1f), BtnKind.Secondary)
        }
        Spacer(Modifier.height(Sp.x10))
        LpField(q, { q = it }, "搜图标名…", label = "图标库")
        Spacer(Modifier.height(Sp.x10))
        when {
            lib == null -> Dim2("正在取图标库…")
            // 「这个构建没配源」和「拉取失败」要分开说:前者点一百次刷新也没用
            items.isEmpty() && builtin == 0L && sources.isEmpty() ->
                Dim2("还没有任何图标源。可以在下面加一个,或者直接选本地图片。")
            items.isEmpty() -> Dim2("没有匹配的图标。")
            else -> LazyVerticalGrid(
                GridCells.Adaptive(72.dp), Modifier.heightIn(max = 260.dp),
                horizontalArrangement = Arrangement.spacedBy(Sp.x8),
                verticalArrangement = Arrangement.spacedBy(Sp.x8),
            ) {
                items(items.size) { i ->
                    val e = items[i]
                    val url = e.str("url").orEmpty()
                    AsyncImage(
                        model = url, contentDescription = e.str("name"),
                        modifier = Modifier.size(64.dp).clickable { scope.launch { use(url) } },
                        contentScale = ContentScale.Fit,
                    )
                }
            }
        }
        Spacer(Modifier.height(Sp.x12))
        Dim3(if (builtin > 0) "内置图标源 $builtin 个(地址随构建走,不在这儿显示)"
             else "这个构建没有内置图标源。")
        sources.forEach { u ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Dim3(u, Modifier.weight(1f))
                LpButton("移除", {
                    scope.launch { saveSources(app, sources - u); load(true) }
                }, kind = BtnKind.Secondary)
            }
        }
        Spacer(Modifier.height(Sp.x8))
        LpField(newSrc, { newSrc = it }, "粘一个图标源的 JSON 地址", label = "添加网络源")
        Spacer(Modifier.height(Sp.x10))
        Row(horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
            LpButton("关闭", onClose, Modifier.weight(1f), BtnKind.Secondary)
            LpButton("添加源", {
                val u = newSrc.trim()
                if (!u.startsWith("http")) {
                    // 本地路径填进来的话核心层那趟 GET 只会报「不支持的协议」,
                    // 在这儿说清楚比让人去翻日志强
                    app.toast("网络源要以 http:// 或 https:// 开头", ToastKind.Error)
                } else {
                    busy = true
                    scope.launch {
                        saveSources(app, sources + u)
                        newSrc = ""
                        load(true)
                        busy = false
                    }
                }
            }, Modifier.weight(1f), loading = busy)
        }
    }
}

/** 整表送回去。核心层会顺手把缓存清掉,所以调用方紧跟着要重拉一次。 */
private suspend fun saveSources(app: xyz.linplayer.app.data.AppState, list: List<String>) {
    runCatching {
        app.call("prefs.setIconSources", args("sources" to jsonArrayOf(list)))
    }.onFailure { app.report(it) }
}

/**
 * SAF 给的是 `content://`,而核心层要的是一条**真路径**。复制到私有目录再交过去。
 *
 * 旧的不留:每换一次留一份的话,私有目录里会攒一堆图。
 */
private fun copyToCache(ctx: android.content.Context, uri: android.net.Uri): String? = runCatching {
    ctx.cacheDir.listFiles { f -> f.name.startsWith("srv-icon-") }?.forEach { it.delete() }
    val dst = java.io.File(ctx.cacheDir, "srv-icon-" + System.currentTimeMillis())
    ctx.contentResolver.openInputStream(uri)!!.use { i -> dst.outputStream().use { o -> i.copyTo(o) } }
    if (dst.length() == 0L) { dst.delete(); return null }
    dst.absolutePath
}.getOrNull()
