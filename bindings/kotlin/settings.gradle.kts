// 独立的一丁点儿工程,只为让「生成的 Kotlin 能编译」这条判据有个真编译得起来的地方。
// 不参与 App 的构建 —— Android 侧直接把 Commands.g.kt 拉进自己的 sourceSet。
rootProject.name = "linplayer-bindings"
