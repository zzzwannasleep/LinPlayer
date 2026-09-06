package xyz.linplayer.app.data

import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember

/**
 * 页面数据的**进程级**留存。
 *
 * ☠ 症状:从首页点进任何一页再返回,首页**整个重拉一遍** —— 骨架闪一次、
 * Hero 从第一张重来、滚动位置也白留了。
 *
 * 根因不是「没做缓存」,是**每一页的数据都放在 `remember { mutableStateOf() }` 里**。
 * `remember` 的寿命是 composition:底栏切 Tab 用了 `saveState`/`restoreState`,
 * 保住的只有 `rememberSaveable`(滚动位置那种),`remember` 里的数据一律丢。
 * 数据一丢,`LaunchedEffect` 就重跑,于是「切一次页面 = 全量重拉」。
 *
 * 六个页面都是这个写法,所以修在这里而不是修首页 —— 只修首页的话,
 * 媒体库、详情、聚合、收藏、下载还是老样子。
 *
 * ★ **不是 TTL 缓存,是「留住上一次的结果」。** 数据新鲜度靠既有的
 *   `app.invalidate` 广播来推翻(收藏/屏蔽/删服务器都会发),
 *   再叠一层时间过期 = 两套失效规则打架,而且没人说得清哪套赢。
 *
 * ★ 键要**带参数**:媒体库 A 和媒体库 B 是两页,共用一个键会串数据。
 */
object PageCache {
    private val slots = HashMap<String, Any?>()

    @Suppress("UNCHECKED_CAST")
    fun <T> get(key: String): T? = slots[key] as T?

    fun put(key: String, value: Any?) {
        slots[key] = value
    }

    /** 退登 / 换账号时整片清掉 —— 留着就是把上一个账号的内容画给下一个人看。 */
    fun clear() = slots.clear()
}

/**
 * 和 `remember { mutableStateOf(init) }` 用法一样,但**值活过页面销毁**。
 *
 * ```
 * var hero by keepState("home.hero") { Block.Loading as Block<List<Item>> }
 * ```
 *
 * 配套的 `LaunchedEffect` 要判「已经有值就别重拉」,否则留是留住了,
 * 回到页面还是照拉一遍 —— 那只是省了闪烁,没省请求。
 */
@Composable
fun <T> keepState(key: String, init: () -> T): MutableState<T> {
    val state = remember(key) {
        val kept = PageCache.get<T>(key)
        mutableStateOf(if (kept != null) kept else init())
    }
    // 每次重组把当前值写回:没有 DisposableEffect —— 页面被杀时
    // onDispose 有可能赶不上(进程被回收),而写回本身是一次哈希表赋值
    PageCache.put(key, state.value)
    return state
}
