# -*- coding: utf-8 -*-
"""判别器:同一个 lpcore.dll,换成 Python 宿主跑同一条命令。
Python 不装 CoreCLR 那套向量化异常处理 —— 如果这里 recover 得住,
那问题就锁定在宿主的异常处理上,不是 Go 的 recover 本身。"""
import ctypes as C, os, sys, threading, json, time
os.environ["LP_DEBUG_CMDS"] = "1"
cmd = sys.argv[1] if len(sys.argv) > 1 else "debug.panic"
m = C.CDLL(os.path.abspath("out/lpcore.dll"))
m.lp_abi_version.restype = C.c_int32
m.lp_init.argtypes = [C.c_char_p]; m.lp_init.restype = C.c_int32
m.lp_call.argtypes = [C.c_int64, C.c_char_p, C.c_char_p]; m.lp_call.restype = C.c_int32
m.lp_next_event.argtypes = [C.c_int32]; m.lp_next_event.restype = C.c_void_p
m.lp_free.argtypes = [C.c_void_p]
got = {}
def pump():
    while True:
        p = m.lp_next_event(-1)
        if not p: continue
        s = C.cast(p, C.c_char_p).value.decode("utf-8", "replace"); m.lp_free(p)
        e = json.loads(s)
        if e["t"] == "eof": return
        if e["t"] == "result" and e["seq"] == 1:
            got["err"] = (e.get("err") or {}).get("code"); got["ok"] = e.get("ok")
print("ABI =", m.lp_abi_version(), " init =", m.lp_init(b"{}"))
threading.Thread(target=pump, daemon=True).start()
print("发命令", cmd)
m.lp_call(1, cmd.encode(), b"{}")
t0 = time.time()
while time.time() - t0 < 3 and "err" not in got: time.sleep(0.05)
print("进程还活着;收到 result =", bool(got), got)
