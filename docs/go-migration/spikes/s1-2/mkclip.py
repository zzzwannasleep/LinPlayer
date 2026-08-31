# -*- coding: utf-8 -*-
"""用 libmpv 自己的 encode 模式造真 H.264 语料,给 S1.2 的探针用。

为什么不能直接拿 lavfi 喂播放器:lavfi 出的是 wrapped_avframe 裸帧,没有可硬解的东西,
hwdec-current 恒为 no —— 拿它测硬解等于没测(SPIKE-1a 的结论,照抄)。

用法:
    python mkclip.py <输出文件> <宽> <高> <帧率> <秒数>
    python mkclip.py clip4k60.mp4 3840 2160 60 15
"""
import ctypes as C, os, sys, time

DLL = os.environ.get("LP_MPV_DLL",
                     os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  "..", "..", "..", "..", "crates", "mpv", "libmpv", "libmpv-2.dll"))
OUT, W, H, FPS, SECS = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), OUT)

os.add_dll_directory(os.path.dirname(os.path.abspath(DLL)))
m = C.CDLL(os.path.abspath(DLL))
m.mpv_create.restype = C.c_void_p
for fn, at, rt in [("mpv_initialize", [C.c_void_p], C.c_int),
                   ("mpv_set_option_string", [C.c_void_p, C.c_char_p, C.c_char_p], C.c_int),
                   ("mpv_command", [C.c_void_p, C.POINTER(C.c_char_p)], C.c_int),
                   ("mpv_wait_event", [C.c_void_p, C.c_double], C.c_void_p),
                   ("mpv_error_string", [C.c_int], C.c_char_p),
                   ("mpv_terminate_destroy", [C.c_void_p], None)]:
    f = getattr(m, fn); f.argtypes = at; f.restype = rt

h = C.c_void_p(m.mpv_create())
for k, v in {"o": OUT, "of": "mp4", "ovc": "libx264",
             "ovcopts": "preset=ultrafast,crf=28,g=60",
             "oac": "aac", "end": SECS, "terminal": "no"}.items():
    r = m.mpv_set_option_string(h, k.encode(), v.encode())
    if r < 0:
        print("选项 %s 被拒: %s" % (k, m.mpv_error_string(r).decode()), flush=True)
if m.mpv_initialize(h) < 0:
    raise SystemExit("init 失败")

src = "av://lavfi:testsrc2=size=%sx%s:rate=%s" % (W, H, FPS)
a = (C.c_char_p * 3)(b"loadfile", src.encode(), None)
m.mpv_command(h, a)
t0 = time.time()
while time.time() - t0 < 900:
    ev = m.mpv_wait_event(h, 0.2)
    if not ev:
        continue
    if C.cast(ev, C.POINTER(C.c_int)).contents.value in (1, 7):   # SHUTDOWN / END_FILE
        break
m.mpv_terminate_destroy(h)
print("%s 存在=%s 大小=%.1f MB 用时=%.0fs" % (
    os.path.basename(OUT), os.path.exists(OUT),
    (os.path.getsize(OUT) / 1e6) if os.path.exists(OUT) else 0, time.time() - t0), flush=True)
