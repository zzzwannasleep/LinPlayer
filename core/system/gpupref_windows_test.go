//go:build windows

package system

import "testing"

// 一次性的测试键。**不用真键** —— 测试不许改用户真实的显卡偏好。
const testGPUKey = `Software\LinPlayer\selftest-gpupref`

func cleanupTestKey(t *testing.T) {
	t.Helper()
	regDeleteKey(testGPUKey)
	regDeleteKey(`Software\LinPlayer`) // 空了才删得掉,非空会失败 —— 那也对
}

// 判断逻辑:没设过就写高性能;已经有值就一律不动。
func Test显卡偏好_判断(t *testing.T) {
	for _, c := range []struct {
		name   string
		cur    string
		exists bool
		want   string
		need   bool
	}{
		{"从没设过", "", false, gpuPrefHighPerf, true},
		{"值是空串也当没设过", "", true, gpuPrefHighPerf, true},
		{"用户自己选了省电,不许覆盖", "GpuPreference=1;", true, "", false},
		{"已经是高性能,不用重写", "GpuPreference=2;", true, "", false},
		{"系统决定,也是用户的选择", "GpuPreference=0;", true, "", false},
	} {
		got, need := decideGPUPref(c.cur, c.exists)
		if got != c.want || need != c.need {
			t.Errorf("%s: 得到 (%q,%v),要 (%q,%v)", c.name, got, need, c.want, c.need)
		}
	}
}

// ★★ 这条才是重点:**真的去读写注册表**。
//
// 只测 decideGPUPref 等于没测 —— 那半截纯函数怎么写都不会错,
// 会错的是下面那 4 个 syscall(标志位、字节数、UTF-16 转换)。
// 而它们错了**不报错**,只是继续跑核显。这正是本仓最讨厌的失败形态。
func Test显卡偏好_真读写注册表(t *testing.T) {
	cleanupTestKey(t)
	t.Cleanup(func() { cleanupTestKey(t) })

	const val = `D:\some\where\LinPlayer.exe`

	// 第一次:没设过 → 写进去
	act, err := applyGPUPref(testGPUKey, val)
	if err != nil {
		t.Fatalf("第一次写失败: %v", err)
	}
	if act != written {
		t.Fatalf("第一次应该是 %q,实得 %q", written, act)
	}

	// 回读:必须真的落进注册表,而且值的格式要对
	h, err := regCreateKey(testGPUKey)
	if err != nil {
		t.Fatalf("打不开测试键: %v", err)
	}
	got, exists, err := regQueryString(h, val)
	procRegCloseKey.Call(uintptr(h))
	if err != nil || !exists {
		t.Fatalf("回读失败 exists=%v err=%v —— 写进去了但读不回来,说明这条链是断的", exists, err)
	}
	if got != gpuPrefHighPerf {
		t.Fatalf("落盘的值是 %q,要 %q", got, gpuPrefHighPerf)
	}

	// 第二次:已经有值 → 不动
	if act, err = applyGPUPref(testGPUKey, val); err != nil || act != kept {
		t.Fatalf("第二次应该是 %q,实得 %q err=%v —— 幂等性破了,会反复覆盖用户的选择", kept, act, err)
	}
}

// 查不存在的值必须报「不存在」,不能报错、也不能装作查到了空串。
// decideGPUPref 完全靠这个 bool 分流,它错了整条逻辑就反了。
func Test显卡偏好_查不存在的值(t *testing.T) {
	cleanupTestKey(t)
	t.Cleanup(func() { cleanupTestKey(t) })

	h, err := regCreateKey(testGPUKey)
	if err != nil {
		t.Fatalf("建键失败: %v", err)
	}
	defer procRegCloseKey.Call(uintptr(h))

	if _, exists, err := regQueryString(h, `绝对不存在的值名`); err != nil || exists {
		t.Fatalf("不存在的值应当 exists=false err=nil,实得 exists=%v err=%v", exists, err)
	}
}

// 中文 / 长路径要能原样往返 —— 用户的安装路径带中文是常态。
func Test显卡偏好_UTF16往返(t *testing.T) {
	cleanupTestKey(t)
	t.Cleanup(func() { cleanupTestKey(t) })

	h, err := regCreateKey(testGPUKey)
	if err != nil {
		t.Fatalf("建键失败: %v", err)
	}
	defer procRegCloseKey.Call(uintptr(h))

	name := `D:\我的 播放器\LinPlayer.exe`
	if err := regSetString(h, name, gpuPrefHighPerf); err != nil {
		t.Fatalf("写中文值名失败: %v", err)
	}
	got, exists, err := regQueryString(h, name)
	if err != nil || !exists || got != gpuPrefHighPerf {
		t.Fatalf("中文值名往返失败: got=%q exists=%v err=%v", got, exists, err)
	}
}
