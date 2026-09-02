package paths

import "testing"

// 着色器的两个目录**必须分开**。
//
// ★ 这条测试是 2026-09-02 现场踩出来的:mpv 的 gpu-shader-cache-dir 第一版被指到了
// `cache/shaders`,而 `player.setShaderLevel` 早就在往那里落我们自带的 .glsl 源文件
// (编进二进制、首次用时落盘)。混住之后 mpv 的缓存淘汰和「清缓存」会互相误伤,
// 而且**不报错** —— 真机跑完 `ls` 了一眼才发现。
func Test着色器源文件和编译缓存不许同目录(t *testing.T) {
	SetRoot(t.TempDir())
	if ShaderCacheDir() == ShaderSourceDir() {
		t.Fatalf("mpv 的编译缓存和自带 .glsl 源文件挤在同一个目录 %s —— 会互相误伤", ShaderCacheDir())
	}
	if ShaderCacheDir() == ShadersDir() {
		t.Fatal("编译缓存不能和 ShadersDir 同目录")
	}
}

// EnsureDirs 建的目录里必须包含着色器编译缓存 —— mpv 不会替我们建,
// 目录不存在时它是**静默不缓存**,不报错。
func Test建目录_包含着色器编译缓存(t *testing.T) {
	SetRoot(t.TempDir())
	if err := EnsureDirs(); err != nil {
		t.Fatalf("EnsureDirs: %v", err)
	}
	for _, d := range []string{ShaderCacheDir(), ShaderSourceDir(), LogsDir(), ImageCache()} {
		if st, err := statDir(d); err != nil || !st {
			t.Errorf("%s 没建出来(err=%v)", d, err)
		}
	}
}
