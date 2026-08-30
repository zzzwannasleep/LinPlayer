# -*- coding: utf-8 -*-
"""
路径 A vs 路径 B 的同片对账:4K60 能不能跑住。

A = vo=gpu + gpu-api=d3d11,mpv 自己拥有窗口 -> 实测能拿 d3d11va 零拷贝
B = render API(ANGLE/GLES)-> 实测最好只到 d3d11va-copy

量三件事:实际播放速率(time-pos 推进 / 墙钟)、mpv 自己的丢帧计数、进程 CPU 时间。
判据:B 的 time-pos 推进比 < 0.98 或丢帧显著 = 4K60 跑不住,B 有真实取舍。
"""
import ctypes as C, ctypes.wintypes as W, os, sys, time, struct

ANGLE = os.environ.get("LP_ANGLE_DIR", r"C:\Program Files\Tabby")  # 任何自带 ANGLE 的 Electron/CEF 应用目录都行
DLL   = os.environ.get("LP_MPV_DLL", os.path.join("crates","mpv","libmpv","libmpv-2.dll"))
CLIP  = os.path.join(os.path.dirname(os.path.abspath(__file__)), sys.argv[1] if len(sys.argv)>1 else "clip4k.mp4")
OW, OH = (int(sys.argv[2]),int(sys.argv[3])) if len(sys.argv)>3 else (1920,1080)          # 输出分辨率(4K 片子放到 1080p 窗口,最常见的场景)
RUN_S  = 12.0
def log(*a): print(*a, flush=True)

u32,k32 = C.windll.user32, C.windll.kernel32
WNDPROC=C.WINFUNCTYPE(C.c_longlong,C.c_void_p,C.c_uint,C.c_ulonglong,C.c_longlong)
u32.DefWindowProcW.argtypes=[C.c_void_p,C.c_uint,C.c_ulonglong,C.c_longlong]
u32.DefWindowProcW.restype=C.c_longlong
u32.CreateWindowExW.restype=C.c_void_p
u32.DestroyWindow.argtypes=[C.c_void_p]; u32.ShowWindow.argtypes=[C.c_void_p,C.c_int]
class WNDCLASS(C.Structure):
    _fields_=[("style",C.c_uint),("lpfnWndProc",WNDPROC),("cbClsExtra",C.c_int),
              ("cbWndExtra",C.c_int),("hInstance",W.HINSTANCE),("hIcon",W.HICON),
              ("hCursor",W.HANDLE),("hbrBackground",W.HBRUSH),
              ("lpszMenuName",W.LPCWSTR),("lpszClassName",W.LPCWSTR)]
class MSG(C.Structure):
    _fields_=[("hwnd",W.HWND),("message",C.c_uint),("wParam",C.c_ulonglong),
              ("lParam",C.c_longlong),("time",C.c_uint),("x",C.c_long),("y",C.c_long)]
_keep=[]
def make_window(cls):
    hInst=k32.GetModuleHandleW(None)
    p=WNDPROC(lambda h,m,w,l:u32.DefWindowProcW(h,m,w,l)); _keep.append(p)
    wc=WNDCLASS(); wc.lpfnWndProc=p; wc.hInstance=hInst; wc.lpszClassName=cls; wc.style=0x0020
    u32.RegisterClassW(C.byref(wc))
    h=u32.CreateWindowExW(0,cls,"perf",0x00CF0000,-3000,100,OW,OH,None,None,hInst,None)
    u32.ShowWindow(h,5); return h
def pump():
    m_=MSG()
    while u32.PeekMessageW(C.byref(m_),None,0,0,1):
        u32.TranslateMessage(C.byref(m_)); u32.DispatchMessageW(C.byref(m_))

class FT(C.Structure): _fields_=[("lo",C.c_uint),("hi",C.c_uint)]
k32.GetProcessTimes.argtypes=[C.c_void_p,C.POINTER(FT),C.POINTER(FT),C.POINTER(FT),C.POINTER(FT)]
k32.GetCurrentProcess.restype=C.c_void_p
def cpu_secs():
    a,b,kt,ut=FT(),FT(),FT(),FT()
    k32.GetProcessTimes(k32.GetCurrentProcess(),C.byref(a),C.byref(b),C.byref(kt),C.byref(ut))
    tot=((kt.hi<<32)|kt.lo)+((ut.hi<<32)|ut.lo)
    return tot/1e7

os.add_dll_directory(ANGLE)
egl=C.CDLL(os.path.join(ANGLE,"libEGL.dll")); gles=C.CDLL(os.path.join(ANGLE,"libGLESv2.dll"))
for f,at,rt in [("eglGetDisplay",[C.c_void_p],C.c_void_p),
    ("eglInitialize",[C.c_void_p,C.POINTER(C.c_int),C.POINTER(C.c_int)],C.c_uint),
    ("eglBindAPI",[C.c_uint],C.c_uint),
    ("eglChooseConfig",[C.c_void_p,C.POINTER(C.c_int),C.POINTER(C.c_void_p),C.c_int,C.POINTER(C.c_int)],C.c_uint),
    ("eglCreateWindowSurface",[C.c_void_p,C.c_void_p,C.c_void_p,C.POINTER(C.c_int)],C.c_void_p),
    ("eglCreateContext",[C.c_void_p,C.c_void_p,C.c_void_p,C.POINTER(C.c_int)],C.c_void_p),
    ("eglMakeCurrent",[C.c_void_p]*4,C.c_uint),("eglSwapBuffers",[C.c_void_p,C.c_void_p],C.c_uint),
    ("eglSwapInterval",[C.c_void_p,C.c_int],C.c_uint),
    ("eglGetProcAddress",[C.c_char_p],C.c_void_p)]:
    fn=getattr(egl,f); fn.argtypes=at; fn.restype=rt
gles.glGetString.argtypes=[C.c_uint]; gles.glGetString.restype=C.c_char_p
GLPROC=C.CFUNCTYPE(C.c_void_p,C.c_void_p,C.c_char_p)
def _gp(_c,name):
    p=egl.eglGetProcAddress(name)
    if not p:
        k32.GetProcAddress.restype=C.c_void_p; k32.GetProcAddress.argtypes=[C.c_void_p,C.c_char_p]
        p=k32.GetProcAddress(C.c_void_p(gles._handle),name)
    return p or 0
GET_PROC=GLPROC(_gp)

os.add_dll_directory(os.path.dirname(DLL)); m=C.CDLL(DLL)
for fn,at,rt in [("mpv_create",[],C.c_void_p),("mpv_initialize",[C.c_void_p],C.c_int),
    ("mpv_set_option_string",[C.c_void_p,C.c_char_p,C.c_char_p],C.c_int),
    ("mpv_command",[C.c_void_p,C.POINTER(C.c_char_p)],C.c_int),
    ("mpv_get_property_string",[C.c_void_p,C.c_char_p],C.c_void_p),
    ("mpv_free",[C.c_void_p],None),("mpv_wait_event",[C.c_void_p,C.c_double],C.c_void_p),
    ("mpv_terminate_destroy",[C.c_void_p],None),
    ("mpv_render_context_create",[C.c_void_p,C.c_void_p,C.c_void_p],C.c_int),
    ("mpv_render_context_render",[C.c_void_p,C.c_void_p],C.c_int),
    ("mpv_render_context_update",[C.c_void_p],C.c_ulonglong),
    ("mpv_render_context_free",[C.c_void_p],None)]:
    f=getattr(m,fn); f.argtypes=at; f.restype=rt
class RParam(C.Structure): _fields_=[("type",C.c_int),("data",C.c_void_p)]
class GLInit(C.Structure): _fields_=[("gpa",GLPROC),("ctx",C.c_void_p),("exts",C.c_char_p)]
class GLFbo(C.Structure): _fields_=[("fbo",C.c_int),("w",C.c_int),("h",C.c_int),("ifmt",C.c_int)]
def gp(h,n):
    p=m.mpv_get_property_string(h,n.encode())
    if not p: return None
    s=C.cast(p,C.c_char_p).value.decode(errors="replace"); m.mpv_free(p); return s
def cmd(h,*a):
    arr=(C.c_char_p*(len(a)+1))(*[x.encode() for x in a],None); return m.mpv_command(h,arr)
def f(h,n):
    v=gp(h,n)
    try: return float(v)
    except: return None

def wait_loaded(h,timeout=30):
    t0=time.time()
    while time.time()-t0<timeout:
        pump(); ev=m.mpv_wait_event(h,0.05)
        if ev and C.cast(ev,C.POINTER(C.c_int)).contents.value==8: return True
    return False

def report(tag,h,wall,tp0,tp1,cpu,frames):
    adv=(tp1-tp0) if (tp0 is not None and tp1 is not None) else 0
    ratio=adv/wall if wall else 0
    log("  播放推进 %.2fs / 墙钟 %.2fs = **%.3f**   %s"%(adv,wall,ratio,
        "跟得上" if ratio>=0.98 else "!! 跟不上"))
    log("  丢帧: frame-drop=%s  decoder-frame-drop=%s  vo-delayed=%s"%(
        gp(h,"frame-drop-count"),gp(h,"decoder-frame-drop-count"),gp(h,"vo-delayed-frame-count")))
    log("  进程 CPU %.2fs  (= %.0f%% of one core)"%(cpu,cpu/wall*100))
    if frames is not None: log("  我们自己渲了 %d 帧 = %.1f fps"%(frames,frames/wall))

def path_a():
    log(""); log("="*72); log("路径 A:vo=gpu + gpu-api=d3d11(mpv 自己拥有窗口,零拷贝)")
    h=C.c_void_p(m.mpv_create())
    for k,v in {"vo":"gpu","gpu-api":"d3d11","hwdec":"d3d11va","terminal":"no",
                "force-window":"yes","keep-open":"yes","video-sync":"audio",
                "geometry":"%dx%d+-3000+100"%(OW,OH),"audio":"no"}.items():
        m.mpv_set_option_string(h,k.encode(),v.encode())
    m.mpv_initialize(h)
    cmd(h,"loadfile",CLIP); wait_loaded(h); time.sleep(1.0)
    log("  hwdec-current=%s  video=%sx%s @%s"%(gp(h,"hwdec-current"),
        gp(h,"width"),gp(h,"height"),gp(h,"container-fps")))
    c0=cpu_secs(); t0=time.time(); tp0=f(h,"time-pos")
    while time.time()-t0<RUN_S: pump(); time.sleep(0.05)
    wall=time.time()-t0; tp1=f(h,"time-pos"); cpu=cpu_secs()-c0
    report("A",h,wall,tp0,tp1,cpu,None)
    m.mpv_terminate_destroy(h)

def path_b():
    log(""); log("="*72); log("路径 B:render API(ANGLE/GLES3)-> 只能 d3d11va-copy")
    hwnd=make_window("perfB")
    dpy=egl.eglGetDisplay(C.c_void_p(0)); ma,mi=C.c_int(),C.c_int()
    egl.eglInitialize(dpy,C.byref(ma),C.byref(mi)); egl.eglBindAPI(0x30A0)
    attrs=(C.c_int*13)(0x3033,0x0004,0x3040,0x0040,0x3024,8,0x3023,8,0x3022,8,0x3021,8,0x3038)
    cfg=C.c_void_p(); n=C.c_int(); egl.eglChooseConfig(dpy,attrs,C.byref(cfg),1,C.byref(n))
    surf=egl.eglCreateWindowSurface(dpy,cfg,C.c_void_p(hwnd),None)
    ca=(C.c_int*3)(0x3098,3,0x3038); ctx=egl.eglCreateContext(dpy,cfg,None,ca)
    egl.eglMakeCurrent(dpy,surf,surf,ctx)
    egl.eglSwapInterval(dpy,0)          # 关垂直同步,别让 swap 变成限速器
    log("  GL = %s"%gles.glGetString(0x1F02).decode(errors="replace"))
    h=C.c_void_p(m.mpv_create())
    for k,v in {"vo":"libmpv","hwdec":"auto","terminal":"no","keep-open":"yes",
                "audio":"no"}.items():
        m.mpv_set_option_string(h,k.encode(),v.encode())
    m.mpv_initialize(h)
    api=C.c_char_p(b"opengl"); gi=GLInit(GET_PROC,None,None); adv=C.c_int(1)
    ps=(RParam*4)(RParam(1,C.cast(api,C.c_void_p)),RParam(2,C.cast(C.byref(gi),C.c_void_p)),
                  RParam(10,C.cast(C.byref(adv),C.c_void_p)),RParam(0,None))
    rctx=C.c_void_p(); m.mpv_render_context_create(C.byref(rctx),h,ps)
    cmd(h,"loadfile",CLIP); wait_loaded(h); time.sleep(1.0)
    log("  hwdec-current=%s  video=%sx%s @%s"%(gp(h,"hwdec-current"),
        gp(h,"width"),gp(h,"height"),gp(h,"container-fps")))
    fbo=GLFbo(0,OW,OH,0); flip=C.c_int(1)
    rps=(RParam*3)(RParam(3,C.cast(C.byref(fbo),C.c_void_p)),
                   RParam(4,C.cast(C.byref(flip),C.c_void_p)),RParam(0,None))
    c0=cpu_secs(); t0=time.time(); tp0=f(h,"time-pos"); frames=0
    while time.time()-t0<RUN_S:
        pump()
        if m.mpv_render_context_update(rctx) & 1:
            m.mpv_render_context_render(rctx,rps); egl.eglSwapBuffers(dpy,surf); frames+=1
        else:
            time.sleep(0.001)
    wall=time.time()-t0; tp1=f(h,"time-pos"); cpu=cpu_secs()-c0
    report("B",h,wall,tp0,tp1,cpu,frames)
    m.mpv_render_context_free(rctx); m.mpv_terminate_destroy(h); u32.DestroyWindow(hwnd)

if not os.path.exists(CLIP): raise SystemExit("缺 clip4k.mp4")
log("片源:%s  %.0f MB"%(os.path.basename(CLIP),os.path.getsize(CLIP)/1048576))
log("输出分辨率:%dx%d   跑 %.0f 秒"%(OW,OH,RUN_S))
path_a(); path_b()
log(""); log("="*72)
