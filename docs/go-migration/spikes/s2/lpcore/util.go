package main

import (
	"encoding/json"
	"errors"
	"fmt"
)

func jsonRaw(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		return json.RawMessage(`{}`)
	}
	return b
}

func errStr(s string) error { return errors.New(s) }

// fmtSscan 包一层只是为了让 glchan.go 不用直接 import fmt(那份文件的 cgo 序言已经很长了)
func fmtSscan(s string, out *float64) (int, error) { return fmt.Sscan(s, out) }
