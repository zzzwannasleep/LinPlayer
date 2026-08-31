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
func PluginsDir() string    { return sub("plugins", "installed") }
func PluginStorage() string { return sub("plugins", "storage") }
func ModelsDir() string     { return sub("models") } // Whisper 等按需下载的模型(Q6 已定:拆出来)

// EnsureDirs 建好数据根下的目录树。
func EnsureDirs() error {
	for _, d := range []string{
		LogsDir(), ImageCache(), PrefetchCache(), ShadersDir(),
		PluginsDir(), PluginStorage(), ModelsDir(),
	} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}
	return nil
}
