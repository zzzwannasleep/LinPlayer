package config

// 测试辅助:把容器 JSON 拆开再装回去(用来造「混着坏条目」的载荷)。

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"io"
	"testing"
)

func gunzipForTest(t *testing.T, b []byte) []byte {
	t.Helper()
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	defer zr.Close()
	out, err := io.ReadAll(zr)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func reencodeForTest(t *testing.T, c map[string]any) string {
	t.Helper()
	raw, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	_, _ = gz.Write(raw)
	_ = gz.Close()
	return transferPrefix + base64.URLEncoding.EncodeToString(buf.Bytes())
}
