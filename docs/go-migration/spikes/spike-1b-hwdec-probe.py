# -*- coding: utf-8 -*-
"""判别器:同一个 libmpv、同一个片子,路径 A(mpv 自己拥有窗口)能不能拿到 d3d11va 零拷贝。
   A 拿得到而 B 拿不到 -> 是互操作没配对;A 也拿不到 -> 是构建或硬件的事。"""
import ctypes as C, os, sys, time
DLL=os.environ.get("LP_MPV_DLL", os.path.join("crates","mpv","libmpv","libmpv-2.dll"))
CLIP=os.path.join(os.path.dirname(os.path.abspath(__file__)),"clip.mp4")
os.add_dll_directory(os.path.dirname(DLL)); m=C.CDLL(DLL)
for fn,at,rt in [("mpv_create",[],C.c_void_p),("mpv_initialize",[C.c_void_p],C.c_int),
    ("mpv_set_option_string",[C.c_void_p,C.c_char_p,C.c_char_p],C.c_int),
    ("mpv_command",[C.c_void_p,C.POINTER(C.c_char_p)],C.c_int),
    ("mpv_get_property_string",[C.c_void_p,C.c_char_p],C.c_void_p),
    ("mpv_free",[C.c_void_p],None),("mpv_wait_event",[C.c_void_p,C.c_double],C.c_void_p),
    ("mpv_error_string",[C.c_int],C.c_char_p),("mpv_terminate_destroy",[C.c_void_p],None)]:
    f=getattr(m,fn); f.argtypes=at; f.restype=rt
def gp(h,n):
    p=m.mpv_get_property_string(h,n.encode())
    if not p: return None
    s=C.cast(p,C.c_char_p).value.decode(errors="replace"); m.mpv_free(p); return s

# ① 这个构建里 hwdec 有哪些合法取值
h=C.c_void_p(m.mpv_create()); m.mpv_set_option_string(h,b"terminal",b"no"); m.mpv_initialize(h)
ch=gp(h,"option-info/hwdec/choices")
print("hwdec 合法取值:", ch)
print("  d3d11va 在不在:", "d3d11va" in (ch or ""))
m.mpv_terminate_destroy(h)

# ② 路径 A:mpv 自己开窗(vo=gpu),看能不能拿到零拷贝
for want in ("d3d11va","auto"):
    h=C.c_void_p(m.mpv_create())
    for k,v in {"vo":"gpu","gpu-api":"d3d11","hwdec":want,"terminal":"no",
                "force-window":"yes","keep-open":"yes","pause":"yes",
                "geometry":"640x360+-2000+100"}.items():
        m.mpv_set_option_string(h,k.encode(),v.encode())
    if m.mpv_initialize(h)<0: print("init 失败"); continue
    a=(C.c_char_p*3)(b"loadfile",CLIP.encode(),None); m.mpv_command(h,a)
    t0=time.time(); ok=False
    while time.time()-t0<20:
        ev=m.mpv_wait_event(h,0.05)
        if ev and C.cast(ev,C.POINTER(C.c_int)).contents.value==8: ok=True; break
    time.sleep(1.5)
    print("路径A vo=gpu gpu-api=d3d11  请求 hwdec=%-8s -> hwdec-current=%s  (loaded=%s)"
          %(want, gp(h,"hwdec-current"), ok))
    m.mpv_terminate_destroy(h)
