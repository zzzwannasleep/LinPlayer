package xyz.linplayer.app.ui.player

import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import xyz.linplayer.app.core.CoreClient

/**
 * 视频层(SPEC §7.2 通道 A)。
 *
 * **`SurfaceView` 不是 `TextureView`** —— SurfaceView 是独立合成层,
 * 系统天然把 View 树画在它上面:零 overdraw、零拷贝,Compose 内容画在其上是免费的。
 *
 * ☠ **解绑必须同步阻塞。** `surfaceDestroyed` 返回后 Surface 立即失效,
 * mpv 还在往里画就是 use-after-free。所以这里**直接**调
 * `core.setSurface(null, 0, 0)`(它一路阻塞到核心层把 vo 拆掉),
 * **不许**扔到协程或别的线程去做 —— 扔出去就等于没有屏障。
 * 这是 `SPEC.md` 点名的「安卓端最容易漏的一条」,旧栈就漏着(TODO N5)。
 */
@Composable
fun VideoSurface(core: CoreClient, m: Modifier = Modifier) {
    AndroidView(
        modifier = m,
        factory = { ctx ->
            SurfaceView(ctx).apply {
                holder.addCallback(object : SurfaceHolder.Callback {
                    override fun surfaceCreated(h: SurfaceHolder) {
                        // 这里不绑:尺寸要等 surfaceChanged 才有。
                        // 拿 0×0 去绑,mpv 会按 0 尺寸初始化 vo 然后再也不改
                    }

                    override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, ht: Int) {
                        core.setSurface(h.surface, w, ht)
                    }

                    override fun surfaceDestroyed(h: SurfaceHolder) {
                        core.setSurface(null, 0, 0)   // ★ 同步阻塞,别挪走
                    }
                })
            }
        },
    )
    // Activity 被杀时兜一次:surfaceDestroyed 在正常路径上一定会来,
    // 但「先 lp_set_surface(0) 再销毁」这条顺序不能只指望正常路径(U1.22 判据)
    DisposableEffect(Unit) { onDispose { core.setSurface(null, 0, 0) } }
}
