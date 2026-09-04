// LinPlayer 核心层。各端共用,编译成 C ABI 库被 Kotlin/JNI、C#/P-Invoke、Swift 加载。
//
// **零第三方依赖是刻意的**(插件引擎那个 goja 除外)。
// 依赖越少,三端交叉编译时能出问题的地方就越少。
module linplayer/core

go 1.27

require (
	github.com/dlclark/regexp2/v2 v2.5.2 // indirect
	github.com/dop251/goja v0.0.0-20260901132549-43234fa61381 // indirect
	github.com/go-sourcemap/sourcemap v2.1.3+incompatible // indirect
	github.com/google/pprof v0.0.0-20230207041349-798e818bf904 // indirect
	golang.org/x/text v0.3.8 // indirect
)
