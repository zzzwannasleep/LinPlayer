package source

// 源后端注册表。
//
// ★ 分派表按 Kind 查。用 map 而不是 switch:插件贡献的源是运行时才知道的键,
// switch 表达不了(这也是 Kind 从封闭枚举改成开放键的原因)。

import "sync"

var (
	regMu    sync.RWMutex
	backends = map[Kind]Backend{}
)

// Register 登记一个后端。重复登记会覆盖 —— 插件重载时要的就是覆盖。
func Register(b Backend) {
	regMu.Lock()
	defer regMu.Unlock()
	backends[b.Kind()] = b
}

// Unregister 摘掉一个后端(插件禁用 / 卸载)。
func Unregister(k Kind) {
	regMu.Lock()
	defer regMu.Unlock()
	delete(backends, k)
}

// Get 取一个后端。第二个返回值是「有没有」。
func Get(k Kind) (Backend, bool) {
	regMu.RLock()
	defer regMu.RUnlock()
	b, ok := backends[k]
	return b, ok
}

// Kinds 当前已登记的源类型。
func Kinds() []Kind {
	regMu.RLock()
	defer regMu.RUnlock()
	out := make([]Kind, 0, len(backends))
	for k := range backends {
		out = append(out, k)
	}
	return out
}
