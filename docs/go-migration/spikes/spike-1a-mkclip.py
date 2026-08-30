# -*- coding: utf-8 -*-
"""用 libmpv 自己的 encode 模式造一个真 H.264 片子(12s),给 spike-1a-pgs.py 测 hwdec + 纹理用。

为什么需要它:lavfi 出的是 wrapped_avframe 裸帧,没有可硬解的东西,hwdec-current 恒为 no ——
拿 lavfi 测硬解等于没测。产物 clip.mp4 落在本脚本同级目录。

用法: python spike-1a-mkclip.py [libmpv-2.dll路径]
"""
import ctypes as C, os, sys, time
DLL = sys.argv[1] if len(sys.argv) > 1 else os.path.join("crates","mpv","libmpv","libmpv-2.dll")
OUT=os.path.join(os.path.dirname(os.path.abspath(__file__)),"clip.mp4")
os.add_dll_directory(os.path.dirname(DLL)); m=C.CDLL(DLL)
m.mpv_create.restype=C.c_void_p
for fn,at,rt in [("mpv_initialize",[C.c_void_p],C.c_int),
                 ("mpv_set_option_string",[C.c_void_p,C.c_char_p,C.c_char_p],C.c_int),
                 ("mpv_command",[C.c_void_p,C.POINTER(C.c_char_p)],C.c_int),
                 ("mpv_wait_event",[C.c_void_p,C.c_double],C.c_void_p),
                 ("mpv_error_string",[C.c_int],C.c_char_p),
                 ("mpv_terminate_destroy",[C.c_void_p],None)]:
    f=getattr(m,fn); f.argtypes=at; f.restype=rt
h=C.c_void_p(m.mpv_create())
for k,v in {"o":OUT,"of":"mp4","ovc":"libx264","ovcopts":"preset=ultrafast,crf=30",
            "oac":"aac","end":"12","terminal":"no","msg-level":"all=v"}.items():
    r=m.mpv_set_option_string(h,k.encode(),v.encode())
    if r<0: print("选项 %s 被拒: %s"%(k,m.mpv_error_string(r).decode()),flush=True)
if m.mpv_initialize(h)<0: raise SystemExit("init 失败")
a=(C.c_char_p*3)(b"loadfile",b"av://lavfi:testsrc2=size=1920x1080:rate=24",None)
m.mpv_command(h,a)
t0=time.time()
while time.time()-t0<120:
    ev=m.mpv_wait_event(h,0.2)
    if not ev: continue
    eid=C.cast(ev,C.POINTER(C.c_int)).contents.value
    if eid in (1,7):  # SHUTDOWN / END_FILE
        break
m.mpv_terminate_destroy(h)
print("产物存在=%s 大小=%s"%(os.path.exists(OUT), os.path.getsize(OUT) if os.path.exists(OUT) else 0))
