package xyz.linplayer.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import xyz.linplayer.app.ui.theme.Lp

/** 手机形态的根。启动时序(SPEC §8.0)的第 4~6 步在这里。 */
@Composable
fun PhoneRoot() {
    val c = Lp.colors
    Box(Modifier.fillMaxSize().background(c.bg), contentAlignment = Alignment.Center) {
        Text("LinPlayer", color = c.fg)
    }
}
