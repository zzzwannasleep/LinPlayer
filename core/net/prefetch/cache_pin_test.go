package prefetch

import (
	"testing"
)

// 文件头和文件尾**永远不许被环挤掉**。
//
// ☠☠ 挤掉的表现是完全静默的:环转一圈之后,任何要**重新打开**这条流的人
// 都打不开了 —— 进度条缩略图正是这样(它用第二个 mpv 从只读缓存端点开同一条流,
// 而 mp4 的 moov 常在文件末尾、mkv 的索引也在末尾)。
// 现象是「播了一会儿之后缩略图就没了」,而日志里只有一句「打不开」。
//
// ★ 断言必须**同时**验头和尾。只验头的话,把 slotOf 写成「只钉 chunk 0」
// 也能过 —— 而真正让 avformat 打不开的恰恰是缺了尾巴那一半。
func TestC27_头尾两段永远不被挤掉(t *testing.T) {
	// 40 段的文件,环只有 8 个槽 —— 装不下,必然要轮换
	const chunks = 40
	total := int64(chunks)*ChunkSize - 777 // 尾段故意不是整段
	d, err := newDiskCache(total, 10*ChunkSize, 2)
	if err != nil {
		t.Fatal(err)
	}
	defer d.close()

	last := int64(chunks - 1)
	seg := func(c int64) []byte {
		n := ChunkSize
		if c == last {
			n = total - c*ChunkSize
		}
		b := make([]byte, n)
		for i := range b {
			b[i] = byte(c)
		}
		return b
	}
	if !d.put(0, seg(0)) || !d.put(last, seg(last)) || !d.put(last-1, seg(last-1)) {
		t.Fatal("头尾写不进去")
	}
	/* 中间那些段来回冲刷:每一段都会挤掉另一段,但**不该碰到钉住的那三段**。
	   ★ 循环**必须停在 last-2**:写到 last-1 的话,最后一次写的正好就是它,
	     于是「它还在」是因为刚写完,不是因为钉住了 —— 假绿。 */
	for c := int64(1); c <= last-2; c++ {
		if !d.put(c, seg(c)) {
			t.Fatalf("第 %d 段写不进去", c)
		}
	}
	if !d.has(0) {
		t.Fatal("文件头被挤掉了 —— 重新打开这条流会直接失败(缩略图会静默消失)")
	}
	if !d.has(last) {
		t.Fatal("文件尾被挤掉了 —— mp4 的 moov / mkv 的索引常在末尾,少了它 avformat 开不了")
	}
	/* ★ 尾巴要钉**两段**。moov 的大小跟帧数走,两小时的片子常有 5~10MB,
	   一段(4MB)装不下 —— 而「moov 被腰斩」和「完全没钉」的症状一模一样:
	   都是 avformat_open_input 直接失败。 */
	if !d.has(last - 1) {
		t.Fatal("倒数第二段被挤掉了 —— 大于 4MB 的 moov 会被腰斩,照样打不开")
	}
	// 内容也要对得上:槽位算错的话 has() 可能仍然是 true,读回来的却是别人的字节
	if b := d.get(0, int(ChunkSize)); b == nil || b[0] != 0 {
		t.Fatalf("文件头读回来不是自己的字节:%v", b != nil)
	}
	tailLen := int(total - last*ChunkSize)
	if b := d.get(last, tailLen); b == nil || b[0] != byte(last) {
		t.Fatalf("文件尾读回来不是自己的字节:%v", b != nil)
	}
	if b := d.get(last-1, int(ChunkSize)); b == nil || b[0] != byte(last-1) {
		t.Fatalf("倒数第二段读回来不是自己的字节:%v", b != nil)
	}
}
