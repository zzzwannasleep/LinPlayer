// Package paths 是**唯一**的数据路径出口(SPEC §10.1)。
//
// 任何包不许自己拼数据目录。理由不是洁癖:绿色包对用户的承诺是
// 「数据全在这个文件夹里」,而这条承诺只要有一个地方绕过去就破了 ——
// 而且破了不报错,要等到用户换机器拷贝时才发现少东西。
//
// ★ 核心层**不许**调 os.UserConfigDir / os.UserCacheDir / os.TempDir 决定落点。
// Android / Apple 的数据根由宿主通过 lp_init(config_json) 传入,核心层不猜。
package paths

import (
	"os"
	"path/filepath"
	"sync"
)

var (
	mu   sync.RWMutex
	root string
)

// SetRoot 由 lp_init 调用,之后不可变。空字符串会被忽略。
func SetRoot(dir string) {
	if dir == "" {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	root = dir
}

// Root 返回数据根。没设过就退回**当前可执行文件同级的 userdata/** ——
// 这是绿色包的形态(SPEC §10.1),不是用户目录。
func Root() string {
	mu.RLock()
	r := root
	mu.RUnlock()
	if r != "" {
		return r
	}
	exe, err := os.Executable()
	if err != nil {
		return "userdata"
	}
	return filepath.Join(filepath.Dir(exe), "userdata")
}

func sub(parts ...string) string {
	return filepath.Join(append([]string{Root()}, parts...)...)
}

// 下面这些就是 SPEC §10.1 那棵树。加新目录**只能加在这里**。

func ConfigFile() string    { return sub("config.json") }
func HistoryFile() string   { return sub("history.json") }
func LogsDir() string       { return sub("logs") }
func CacheDir() string      { return sub("cache") }
func ImageCache() string    { return sub("cache", "img") }
func PrefetchCache() string { return sub("cache", "prefetch") }
func ShadersDir() string    { return sub("shaders") }

// ShaderCacheDir 是 mpv 编译好的着色器**二进制**缓存。
//
// ★★ 目录名不能叫 shaders:`player.setShaderLevel` 已经在往 `cache/shaders`
// 落我们自带的 .glsl **源文件**了(编进二进制、首次用时落盘)。两者混住的话,
// mpv 的缓存淘汰和「清缓存」会互相误伤 —— 2026-09-02 第一版就是这么写的,
// 真机跑完一看目录里全是 .glsl 才发现。
//
// ★ libmpv 没有配置目录,**不显式给这个路径它就不缓存** ——
// 表现是每次起播重编整条 CNN 链,开着超分时第一秒明显卡一下。
func ShaderCacheDir() string { return sub("cache", "shader-bin") }

// ShaderSourceDir 是我们自带的 .glsl **源文件**落盘的地方。
//
// 它们编进了二进制,首次用到时才写出来 —— 丢了能重生成,所以归 cache/。
func ShaderSourceDir() string { return sub("cache", "shaders") }

// statDir 报告 p 是不是一个已存在的目录。给测试用。
func statDir(p string) (bool, error) {
	fi, err := os.Stat(p)
	if err != nil {
		return false, err
	}
	return fi.IsDir(), nil
}
func PluginsDir() string    { return sub("plugins", "installed") }
func PluginStorage() string { return sub("plugins", "storage") }
func ModelsDir() string     { return sub("models") } // Whisper 等按需下载的模型(Q6 已定:拆出来)

// PluginStateFile 插件启用态 / 已同意权限。
func PluginStateFile() string { return sub("plugins", "state.json") }

// TempDir 自家临时目录。
//
// ★ **不用系统 %TEMP%**:绿色包的口径是「数据全在 exe 同级 userdata/」,
// 往系统临时目录里丢东西会在用户机器上留下我们自己都找不到的垃圾。
func TempDir() string { return sub("temp") }

// EnsureDirs 建好数据根下的目录树。
func EnsureDirs() error {
	for _, d := range []string{
		LogsDir(), ImageCache(), PrefetchCache(), ShadersDir(),
		ShaderCacheDir(), ShaderSourceDir(),
		PluginsDir(), PluginStorage(), ModelsDir(),
	} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}
	return nil
}

// DownloadsDir 下载目录。**用户的资产**,清缓存不许碰。
func DownloadsDir() string { return sub("downloads") }

// CacheSize 缓存目录的总占用(字节)。
//
// ★ 只统计 cache/ —— 设置页那个「已用 xx MB」旁边就是「清除缓存」按钮,
// 两个数必须说的是同一件事。把 data/ 或 downloads/ 算进去的话,
// 用户点了清除发现数字没怎么变,那按钮就成了安慰剂。
func CacheSize() (int64, error) {
	var total int64
	err := filepath.Walk(CacheDir(), func(_ string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // 单个文件读不到不该让整次统计失败
		}
		if !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	if os.IsNotExist(err) {
		return 0, nil
	}
	return total, err
}

// ClearCache 清空缓存目录。
//
// ★★ **只动 cache/**,config / data / downloads **一根汗毛都不碰**。
// 观看记录、账号、已下载的片子都在后者里 —— 清缓存把它们带走的话,
// 用户是找不回来的。
func ClearCache() error {
	ents, err := os.ReadDir(CacheDir())
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, e := range ents {
		if err := os.RemoveAll(filepath.Join(CacheDir(), e.Name())); err != nil {
			return err
		}
	}
	// 目录树要留着 —— 删光之后下一次写入会因为父目录不存在而失败
	return EnsureDirs()
}
