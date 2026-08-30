# -*- coding: utf-8 -*-
"""
隔离最后一个变量:render API 的 GL 后端用 ANGLE 还是原生 WGL,差多少。

前情:
  · mpv 自己的 gpu-context=win(WGL)+ d3d11va-copy -> 4K60 跟得上,CPU 19%
  · 我们的 render API + ANGLE  + d3d11va-copy -> 只渲出 18 fps,CPU 77%
  同样是 d3d11va-copy,差 4 倍。剩下的差异只有:ANGLE 翻译层 vs 原生 WGL。

本脚本用完全相同的循环、相同的纹理 FBO、相同的片子,只换 GL 后端。
"""
import ctypes as C, ctypes.wintypes as W, os, sys, time

DLL   = r"D:\LinPlayer\crates\mpv\libmpv\libmpv-2.dll"
ANGLE = r"C:\Program Files\Tabby"
CLIP  = os.path.join(os.path.dirname(os.path.abspath(__file__)), sys.argv[1] if len(sys.argv)>1 else "clip4k.mp4")
OW,OH = (int(sys.argv[2]),int(sys.argv[3])) if len(sys.argv)>3 else (1920,1080)
RUN_S = 12.0
def log(*a): print(*a, flush=True)

u32,g32,k32,ogl = C.windll.user32, C.windll.gdi32, C.windll.kernel32, C.windll.opengl32
WNDPROC=C.WINFUNCTYPE(C.c_longlong,C.c_void_p,C.c_uint,C.c_ulonglong,C.c_longlong)
u32.DefWindowProcW.argtypes=[C.c_void_p,C.c_uint,C.c_ulonglong,C.c_longlong]
u32.DefWindowProcW.restype=C.c_longlong
u32.GetDC.argtypes=[C.c_void_p]; u32.GetDC.restype=C.c_void_p
u32.CreateWindowExW.restype=C.c_void_p
u32.DestroyWindow.argtypes=[C.c_void_p]; u32.ShowWindow.argtypes=[C.c_void_p,C.c_int]
class WNDCLASS(C.Structure):
    _fields_=[("style",C.c_uint),("lpfnWndProc",WNDPROC),("cbClsExtra",C.c_int),
              ("cbWndExtra",C.c_int),("hInstance",W.HINSTANCE),("hIcon",W.HICON),
              ("hCursor",W.HANDLE),("hbrBackground",W.HBRUSH),
              ("lpszMenuName",W.LPCWSTR),("lpszClassName",W.LPCWSTR)]
class PFD(C.Structure):
    _fields_=[("nSize",C.c_ushort),("nVersion",C.c_ushort),("dwFlags",C.c_uint),
              ("iPixelType",C.c_ubyte),("cColorBits",C.c_ubyte),("cRedBits",C.c_ubyte),
              ("cRedShift",C.c_ubyte),("cGreenBits",C.c_ubyte),("cGreenShift",C.c_ubyte),
              ("cBlueBits",C.c_ubyte),("cBlueShift",C.c_ubyte),("cAlphaBits",C.c_ubyte),
              ("cAlphaShift",C.c_ubyte),("cAccumBits",C.c_ubyte),("cAccumRedBits",C.c_ubyte),
              ("cAccumGreenBits",C.c_ubyte),("cAccumBlueBits",C.c_ubyte),
              ("cAccumAlphaBits",C.c_ubyte),("cDepthBits",C.c_ubyte),("cStencilBits",C.c_ubyte),
              ("cAuxBuffers",C.c_ubyte),("iLayerType",C.c_ubyte),("bReserved",C.c_ubyte),
              ("dwLayerMask",C.c_uint),("dwVisibleMask",C.c_uint),("dwDamageMask",C.c_uint)]
class MSG(C.Structure):
    _fields_=[("hwnd",W.HWND),("message",C.c_uint),("wParam",C.c_ulonglong),
              ("lParam",C.c_longlong),("time",C.c_uint),("x",C.c_long),("y",C.c_long)]
g32.ChoosePixelFormat.argtypes=[C.c_void_p,C.POINTER(PFD)]; g32.ChoosePixelFormat.restype=C.c_int
g32.SetPixelFormat.argtypes=[C.c_void_p,C.c_int,C.POINTER(PFD)]
ogl.wglCreateContext.argtypes=[C.c_void_p]; ogl.wglCreateContext.restype=C.c_void_p
ogl.wglMakeCurrent.argtypes=[C.c_void_p,C.c_void_p]
ogl.wglGetProcAddress.argtypes=[C.c_char_p]; ogl.wglGetProcAddress.restype=C.c_void_p
ogl.glGetString.argtypes=[C.c_uint]; ogl.glGetString.restype=C.c_char_p
_keep=[]
def make_window(cls):
    hInst=k32.GetModuleHandleW(None)
    p=WNDPROC(lambda h,m,w,l:u32.DefWindowProcW(h,m,w,l)); _keep.append(p)
    wc=WNDCLASS(); wc.lpfnWndProc=p; wc.hInstance=hInst; wc.lpszClassName=cls; wc.style=0x0020
    u32.RegisterClassW(C.byref(wc))
    h=u32.CreateWindowExW(0,cls,"perf",0x00CF0000,-3000,100,640,360,None,None,hInst,None)
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
    return (((kt.hi<<32)|kt.lo)+((ut.hi<<32)|ut.lo))/1e7

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
    ("mpv_render_context_report_swap",[C.c_void_p],None),
    ("mpv_render_context_free",[C.c_void_p],None)]:
    f=getattr(m,fn); f.argtypes=at; f.restype=rt
GLPROC=C.CFUNCTYPE(C.c_void_p,C.c_void_p,C.c_char_p)
class RParam(C.Structure): _fields_=[("type",C.c_int),("data",C.c_void_p)]
class GLInit(C.Structure): _fields_=[("gpa",GLPROC),("ctx",C.c_void_p),("exts",C.c_char_p)]
class GLFbo(C.Structure): _fields_=[("fbo",C.c_int),("w",C.c_int),("h",C.c_int),("ifmt",C.c_int)]
def gp(h,n):
    p=m.mpv_get_property_string(h,n.encode())
    if not p: return None
    s=C.cast(p,C.c_char_p).value.decode(errors="replace"); m.mpv_free(p); return s
def cmd(h,*a):
    arr=(C.c_char_p*(len(a)+1))(*[x.encode() for x in a],None); return m.mpv_command(h,arr)

def setup_wgl(hwnd):
    hdc=u32.GetDC(hwnd)
    pfd=PFD(); pfd.nSize=C.sizeof(PFD); pfd.nVersion=1
    pfd.dwFlags=0x04|0x20|0x01; pfd.iPixelType=0; pfd.cColorBits=32; pfd.cAlphaBits=8; pfd.cDepthBits=24
    pf=g32.ChoosePixelFormat(hdc,C.byref(pfd)); g32.SetPixelFormat(hdc,pf,C.byref(pfd))
    ctx=ogl.wglCreateContext(hdc); ogl.wglMakeCurrent(hdc,ctx)
    lib=ogl
    def gpa(_c,name):
        p=ogl.wglGetProcAddress(name)
        if not p:
            k32.GetProcAddress.restype=C.c_void_p; k32.GetProcAddress.argtypes=[C.c_void_p,C.c_char_p]
            p=k32.GetProcAddress(C.c_void_p(ogl._handle),name)
        return p or 0
    return lib, gpa, ogl.glGetString(0x1F02).decode(errors="replace")

def setup_angle(hwnd):
    os.add_dll_directory(ANGLE)
    egl=C.CDLL(os.path.join(ANGLE,"libEGL.dll")); gles=C.CDLL(os.path.join(ANGLE,"libGLESv2.dll"))
    for f,at,rt in [("eglGetDisplay",[C.c_void_p],C.c_void_p),
        ("eglInitialize",[C.c_void_p,C.POINTER(C.c_int),C.POINTER(C.c_int)],C.c_uint),
        ("eglBindAPI",[C.c_uint],C.c_uint),
        ("eglChooseConfig",[C.c_void_p,C.POINTER(C.c_int),C.POINTER(C.c_void_p),C.c_int,C.POINTER(C.c_int)],C.c_uint),
        ("eglCreateWindowSurface",[C.c_void_p,C.c_void_p,C.c_void_p,C.POINTER(C.c_int)],C.c_void_p),
        ("eglCreateContext",[C.c_void_p,C.c_void_p,C.c_void_p,C.POINTER(C.c_int)],C.c_void_p),
        ("eglMakeCurrent",[C.c_void_p]*4,C.c_uint),("eglGetProcAddress",[C.c_char_p],C.c_void_p)]:
        fn=getattr(egl,f); fn.argtypes=at; fn.restype=rt
    gles.glGetString.argtypes=[C.c_uint]; gles.glGetString.restype=C.c_char_p
    dpy=egl.eglGetDisplay(C.c_void_p(0)); a,b=C.c_int(),C.c_int()
    egl.eglInitialize(dpy,C.byref(a),C.byref(b)); egl.eglBindAPI(0x30A0)
    attrs=(C.c_int*13)(0x3033,0x0004,0x3040,0x0040,0x3024,8,0x3023,8,0x3022,8,0x3021,8,0x3038)
    cfg=C.c_void_p(); n=C.c_int(); egl.eglChooseConfig(dpy,attrs,C.byref(cfg),1,C.byref(n))
    surf=egl.eglCreateWindowSurface(dpy,cfg,C.c_void_p(hwnd),None)
    ca=(C.c_int*3)(0x3098,3,0x3038); ctx=egl.eglCreateContext(dpy,cfg,None,ca)
    egl.eglMakeCurrent(dpy,surf,surf,ctx)
    def gpa(_c,name):
        p=egl.eglGetProcAddress(name)
        if not p:
            k32.GetProcAddress.restype=C.c_void_p; k32.GetProcAddress.argtypes=[C.c_void_p,C.c_char_p]
            p=k32.GetProcAddress(C.c_void_p(gles._handle),name)
        return p or 0
    return gles, gpa, gles.glGetString(0x1F02).decode(errors="replace")

def run(backend, hwdec):
    log(""); log("-"*70); log("后端 %-6s  hwdec=%s"%(backend,hwdec))
    hwnd=make_window("perf_%s_%s"%(backend,hwdec.replace("-","")))
    lib,gpa_fn,ver = (setup_wgl if backend=="wgl" else setup_angle)(hwnd)
    log("  GL = %s"%ver)
    GET=GLPROC(gpa_fn); _keep.append(GET)
    def glfn(nm,argt,rest=None):
        p=gpa_fn(None,nm.encode())
        if not p: raise OSError("缺 "+nm)
        return C.CFUNCTYPE(rest or None,*argt)(p)
    lib.glGenTextures.argtypes=[C.c_int,C.c_void_p]; lib.glBindTexture.argtypes=[C.c_uint,C.c_uint]
    lib.glTexImage2D.argtypes=[C.c_uint,C.c_int,C.c_int,C.c_int,C.c_int,C.c_int,C.c_uint,C.c_uint,C.c_void_p]
    lib.glTexParameteri.argtypes=[C.c_uint,C.c_uint,C.c_int]
    genFB=glfn("glGenFramebuffers",[C.c_int,C.c_void_p]); bindFB=glfn("glBindFramebuffer",[C.c_uint,C.c_uint])
    fbTex=glfn("glFramebufferTexture2D",[C.c_uint,C.c_uint,C.c_uint,C.c_uint,C.c_int])
    chkFB=glfn("glCheckFramebufferStatus",[C.c_uint],C.c_uint)
    tex=C.c_uint(); lib.glGenTextures(1,C.byref(tex)); lib.glBindTexture(0x0DE1,tex.value)
    lib.glTexImage2D(0x0DE1,0,0x8058,OW,OH,0,0x1908,0x1401,None)
    for pp in (0x2801,0x2800): lib.glTexParameteri(0x0DE1,pp,0x2601)
    fb=C.c_uint(); genFB(1,C.byref(fb)); bindFB(0x8D40,fb.value)
    fbTex(0x8D40,0x8CE0,0x0DE1,tex.value,0)
    if chkFB(0x8D40)!=0x8CD5: log("  !! FBO 不完整"); return
    h=C.c_void_p(m.mpv_create())
    for k,v in {"vo":"libmpv","hwdec":hwdec,"terminal":"no","keep-open":"yes","audio":"no"}.items():
        m.mpv_set_option_string(h,k.encode(),v.encode())
    m.mpv_initialize(h)
    api=C.c_char_p(b"opengl"); gi=GLInit(GET,None,None); adv=C.c_int(1)
    ps=(RParam*4)(RParam(1,C.cast(api,C.c_void_p)),RParam(2,C.cast(C.byref(gi),C.c_void_p)),
                  RParam(10,C.cast(C.byref(adv),C.c_void_p)),RParam(0,None))
    rctx=C.c_void_p()
    if m.mpv_render_context_create(C.byref(rctx),h,ps)<0: log("  !! render ctx 失败"); return
    cmd(h,"loadfile",CLIP)
    t0=time.time(); ok=False
    while time.time()-t0<25:
        pump(); ev=m.mpv_wait_event(h,0.05)
        if ev and C.cast(ev,C.POINTER(C.c_int)).contents.value==8: ok=True; break
    if not ok: log("  !! 没加载"); return
    time.sleep(1.0)
    fbo=GLFbo(fb.value,OW,OH,0x8058); flip=C.c_int(1)
    rps=(RParam*3)(RParam(3,C.cast(C.byref(fbo),C.c_void_p)),
                   RParam(4,C.cast(C.byref(flip),C.c_void_p)),RParam(0,None))
    log("  hwdec-current=%s  video=%sx%s"%(gp(h,"hwdec-current"),gp(h,"width"),gp(h,"height")))
    c0=cpu_secs(); t0=time.time(); tp0=float(gp(h,"time-pos") or 0); frames=0
    while time.time()-t0<RUN_S:
        pump()
        if m.mpv_render_context_update(rctx)&1:
            bindFB(0x8D40,fb.value); m.mpv_render_context_render(rctx,rps)
            # ★ 开了 ADVANCED_CONTROL 就**必须**报告呈现时刻,否则 mpv 的帧率控制是瞎的
            #   (漏了它:4K60 只渲得出 18fps,看起来像"路径 B 性能不行")
            m.mpv_render_context_report_swap(rctx); frames+=1
        else: time.sleep(0.001)
    wall=time.time()-t0; tp1=float(gp(h,"time-pos") or 0); cc=cpu_secs()-c0
    r=(tp1-tp0)/wall
    log("  播放推进 %.3f  %s | 渲染 %.1f fps | CPU %.0f%% 单核 | 丢帧 %s"%(
        r,"跟得上" if r>=0.98 else "!!跟不上",frames/wall,cc/wall*100,gp(h,"frame-drop-count")))
    m.mpv_render_context_free(rctx); m.mpv_terminate_destroy(h); u32.DestroyWindow(hwnd)

# ★ 一次只跑一个后端/一个 hwdec:同一进程里连开多个 GL 上下文 + 多个 mpv render context
#   会卡死(实测 400s 不返回)。由外层脚本分进程调用。
BE = os.environ.get("LP_BACKEND","wgl")
HW = os.environ.get("LP_HWDEC","auto")
log("片源 %s -> 输出 %dx%d  (Intel 核显)"%(os.path.basename(CLIP),OW,OH))
run(BE,HW)
