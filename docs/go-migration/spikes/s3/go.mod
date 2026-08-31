// SPIKE-3 · quickjs-go 能不能跑现有插件。
//
// 这是全项目**唯一**一个引入第三方 Go 依赖的地方(核心层是零依赖的)。
// quickjs-go 内嵌 QuickJS 的 C 源码,所以它同时也是「cgo + zig cc 能不能编第三方 C」的验证。
module lpplugin

go 1.27

require github.com/buke/quickjs-go v0.7.7
