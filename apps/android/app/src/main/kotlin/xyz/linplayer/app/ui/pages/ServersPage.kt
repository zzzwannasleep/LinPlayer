package xyz.linplayer.app.ui.pages

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
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavController
import androidx.navigation.toRoute
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import xyz.linplayer.app.data.Account
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.ToastKind
import xyz.linplayer.app.data.arr
import xyz.linplayer.app.data.bool
import xyz.linplayer.app.data.dbl
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.ui.Route
import xyz.linplayer.app.ui.components.BtnKind
import xyz.linplayer.app.ui.components.Body
import xyz.linplayer.app.ui.components.Dim3
import xyz.linplayer.app.ui.components.EmptyState
import xyz.linplayer.app.ui.components.Hairline
import xyz.linplayer.app.ui.components.LpButton
import xyz.linplayer.app.ui.components.LpCell
import xyz.linplayer.app.ui.components.LpDialog
import xyz.linplayer.app.ui.components.LpField
import xyz.linplayer.app.ui.components.LpIconButton
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.Panel
import xyz.linplayer.app.ui.components.pressable
import xyz.linplayer.app.ui.components.rememberScrolled
import xyz.linplayer.app.ui.theme.LpIcons
import xyz.linplayer.app.ui.theme.Lp
import xyz.linplayer.app.ui.theme.R
import xyz.linplayer.app.ui.theme.Sp

/**
 * 服务器管理(U1.9b)· 底栏第三个 Tab。
 *
 * ★ **状态点 = 连通健康,不是「选中」**(选中看「当前」角标)。
 *   `down`(探过确实不通)与 `unknown`(还没探过)**同色不同义** ——
 *   手机没有悬停,所以**直接把文字写在卡片上**。这是「不用颜色作为唯一信息载体」的落法。
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
                    ServerCard(a, status[a.id], a.isActive) {
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        menuFor = a
                    }
                    DropdownMenu(menuFor?.id == a.id, { menuFor = null },
                        modifier = Modifier.background(Lp.colors.s3)) {
                        Item2("设为当前") {
                            scope.launch {
                                runCatching { app.call("account.setActiveServer", args("server_id" to a.id)) }
                                    .onSuccess { app.refreshSession(); reload++ }
                                    .onFailure { app.report(it) }
                            }
                        }
                        Item2("编辑") { editFor = a }
                        Item2("服务器线路") { nav.navigate(Route.Lines(a.id, a.name)) }
                        Item2("删除", danger = true) { confirmDelete = a }
                    }
                }
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

@Composable
private fun ServerCard(a: Account, state: String?, active: Boolean, onLong: () -> Unit) {
    val c = Lp.colors
    Panel(Modifier.padding(horizontal = Sp.x16, vertical = Sp.x6)) {
        Row(
            Modifier.fillMaxWidth().combinedClickable(onClick = onLong, onLongClick = onLong)
                .padding(Sp.x16),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(LpIcons.server, null, Modifier.size(22.dp), tint = c.acc)
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

/**
 * 服务器线路(U1.9b)。
 *
 * ★ 「同步线路」和「测延迟」是**两个按钮两回事**。
 * ★ **任何地方不展示线路地址**【用户定】—— 只写名称 + 延迟,没起名的回落「线路 N」。
 * ★ 服主没部署同步服务是常态,**404 不能当错误弹**。
 */
@Composable
fun LinesPage(nav: NavController, entry: NavBackStackEntry) {
    val route = entry.toRoute<Route.Lines>()
    val app = LocalApp.current
    val scope = rememberCoroutineScope()

    // ★ 线路靠**下标**指名道姓,不是靠 URL:核心层的 setActiveLine / probeLine
    //   读的是 index。而且【用户定】任何地方不展示线路地址 —— URL 只是内部键
    data class Line(val index: Int, val url: String, val name: String, val active: Boolean)
    var lines by remember { mutableStateOf<List<Line>>(emptyList()) }
    var latency by remember { mutableStateOf<Map<String, Long?>>(emptyMap()) }
    var reload by remember { mutableStateOf(0) }

    LaunchedEffect(reload) {
        val r = runCatching { app.call("account.probeLines", args("server_id" to route.serverId)) }
        lines = r.getOrNull().arr().mapIndexedNotNull { i, e ->
            val o = e.obj() ?: return@mapIndexedNotNull null
            val url = o.str("url") ?: return@mapIndexedNotNull null
            Line(i, url, o.str("name")?.takeIf { it.isNotBlank() } ?: "线路 ${i + 1}", o.bool("active"))
        }
        // 线路表为空 = 单线路形态,要补出一行可见主线
        if (lines.isEmpty()) lines = listOf(Line(0, "", "主线路", true))
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
                lines.forEachIndexed { i, l ->
                    if (i > 0) Hairline()
                    LpCell(
                        l.name,
                        // 三态:未探(—)/ 探过不通(显示「—」,**不装成 0 ms**)/ 毫秒数
                        value = latency[l.url]?.let { "$it ms" } ?: if (l.url in latency) "—" else "",
                        arrow = false,
                        onClick = {
                            scope.launch {
                                runCatching {
                                    app.call("account.setActiveLine",
                                        args("server_id" to route.serverId, "index" to l.index))
                                }.onSuccess { reload++; app.refreshSession() }.onFailure { app.report(it) }
                            }
                        },
                        sub = if (l.active) "生效中" else null,
                    )
                }
            }
        }
    }
}

@Composable
private fun Item2(label: String, danger: Boolean = false, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(label, color = if (danger) Lp.colors.bad else Lp.colors.fg, fontSize = 14.sp) },
        onClick = onClick,
    )
}
