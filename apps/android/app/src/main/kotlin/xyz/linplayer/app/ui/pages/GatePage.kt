package xyz.linplayer.app.ui.pages

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import xyz.linplayer.app.core.CoreException
import xyz.linplayer.app.data.LocalApp
import xyz.linplayer.app.data.obj
import xyz.linplayer.app.data.str
import xyz.linplayer.app.ui.components.BtnKind
import xyz.linplayer.app.ui.components.Dim2
import xyz.linplayer.app.ui.components.H1
import xyz.linplayer.app.ui.components.LpButton
import xyz.linplayer.app.ui.components.LpField
import xyz.linplayer.app.ui.components.LpScaffold
import xyz.linplayer.app.ui.components.Panel
import xyz.linplayer.app.ui.theme.Sp

/**
 * 首登闸口 / 添加服务器(U1.2)。
 *
 * **同一页的两种版式**:首登 = 全屏居中卡片(无返回);添加 = 从服务器页推入(有返回)。
 * 两套的话新增一种源就要改两处,漏掉的那处就是「某个入口加不了这种源」。
 *
 * ⚠️ `source.formSchema` 不存在(见 MOBILE_BLOCKERS.md B1),PC 端也是硬编的。
 * 本轮照 PC 的做法把源类型表写在这一处。
 */
@Composable
fun GatePage(onDone: suspend () -> Unit, embedded: Boolean = false) {
    val app = LocalApp.current
    val scope = rememberCoroutineScope()
    val keyboard = LocalSoftwareKeyboardController.current

    var server by remember { mutableStateOf("") }
    var user by remember { mutableStateOf("") }
    var pass by remember { mutableStateOf("") }
    var hint by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var selfCheckLogin by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }

    // 打开就把光标放进第一个要填的框:这一屏只有一件事可做,
    // 还要用户先点一下输入框,那一下点击是白让人做的
    LaunchedEffect(Unit) { focus.requestFocus() }

    // 真机自检:`am start ... -e lp_login "<地址>|<用户>|<密码>"` 直接填好并点登录
    LaunchedEffect(Unit) {
        val sc = xyz.linplayer.app.MainActivity.SelfCheck.login ?: return@LaunchedEffect
        xyz.linplayer.app.MainActivity.SelfCheck.login = null
        val parts = sc.split("|")
        server = parts.getOrElse(0) { "" }
        user = parts.getOrElse(1) { "" }
        pass = parts.getOrElse(2) { "" }
        selfCheckLogin = true
    }

    fun run(block: suspend () -> Unit) {
        busy = true
        scope.launch {
            try { block() } catch (e: CoreException) {
                // 登录失败**原样显示核心层的 msg**,不要换成「网络不通」
                hint = e.advice
            } catch (e: Throwable) {
                hint = e.message
            } finally { busy = false }
        }
    }

    // 自检填完就点登录。分两个 effect 是因为要等 server/user/pass 真的写进 state
    LaunchedEffect(selfCheckLogin) {
        if (!selfCheckLogin) return@LaunchedEffect
        selfCheckLogin = false
        busy = true
        try {
            app.call("emby.login", JsonObject(mapOf(
                "server" to JsonPrimitive(withScheme(server)),
                "username" to JsonPrimitive(user),
                "password" to JsonPrimitive(pass),
                "device_id" to JsonPrimitive(app.deviceId()),
            )))
            onDone()
        } catch (e: Throwable) {
            hint = (e as? CoreException)?.advice ?: e.message
        } finally { busy = false }
    }

    val body = @Composable {
        Column(Modifier.fillMaxWidth().imePadding()) {
            H1("连接到你的媒体服务器")
            Spacer(Modifier.height(Sp.x6))
            Dim2("填服务器地址和账号即可。先点「测试连接」可以确认地址对不对。")
            Spacer(Modifier.height(Sp.x20))

            LpField(server, { server = it }, "你的服务器地址", Modifier.focusRequester(focus),
                label = "服务器地址")
            Spacer(Modifier.height(Sp.x12))
            LpField(user, { user = it }, "用户名", label = "用户名")
            Spacer(Modifier.height(Sp.x12))
            LpField(pass, { pass = it }, "密码", password = true, label = "密码")
            Spacer(Modifier.height(Sp.x20))

            Row(horizontalArrangement = Arrangement.spacedBy(Sp.x10)) {
                LpButton("登录", {
                    keyboard?.hide()
                    run {
                        app.call("emby.login", JsonObject(mapOf(
                            "server" to JsonPrimitive(withScheme(server)),
                            "username" to JsonPrimitive(user),
                            "password" to JsonPrimitive(pass),
                            // 设备 id 必须**持久**:每次换一个会把服务器的设备列表刷满,
                            // 续播会话也对不上
                            "device_id" to JsonPrimitive(app.deviceId()),
                        )))
                        onDone()
                    }
                }, Modifier.weight(1f), loading = busy)
                LpButton("测试连接", {
                    run {
                        val info = app.call("account.testConnection", JsonObject(mapOf(
                            "server" to JsonPrimitive(withScheme(server)),
                        )))
                        hint = "连上了:${info.obj().str("name").orEmpty()} · 版本 ${info.obj().str("version").orEmpty()}"
                    }
                }, kind = BtnKind.Secondary, loading = busy)
            }
            hint?.let {
                Spacer(Modifier.height(Sp.x12))
                Dim2(it)
            }
        }
    }

    if (embedded) {
        LpScaffold(title = "添加服务器", onBack = { scope.launch { onDone() } }) { pad ->
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(pad).padding(Sp.x16)) { body() }
        }
    } else {
        LpScaffold { pad ->
            Box(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(pad),
                contentAlignment = Alignment.Center) {
                Panel(Modifier.padding(Sp.x16)) {
                    Column(Modifier.padding(Sp.x20)) { body() }
                }
            }
        }
    }
}

/**
 * 地址补全:用户没写 `http://` 时补一个。
 *
 * 不补的表现是 Go 的 URL 解析报「first path segment in URL cannot contain colon」——
 * 一句纯英文技术话。补在 UI 侧不动核心层的 NormServer(那是从黄金实现逐字移植的,
 * 动了会破坏差分对账基准)。
 * ★ **默认补 http 不是 https**:补错协议只会连不上,而补 https 到一台只有 http 的
 * 服务器上,报的是看不懂的 TLS 错。
 */
internal fun withScheme(raw: String): String {
    val t = raw.trim()
    if (t.isEmpty()) return t
    return if (t.startsWith("http://", true) || t.startsWith("https://", true)) t else "http://$t"
}
