// LinPlayer 核心层。各端共用,编译成 C ABI 库被 Kotlin/JNI、C#/P-Invoke、Swift 加载。
//
// **零第三方依赖是刻意的**(插件引擎那个 quickjs-go 除外,它单独一个模块)。
// 依赖越少,三端交叉编译时能出问题的地方就越少。
module linplayer/core

go 1.27
