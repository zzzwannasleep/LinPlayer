# -*- coding: utf-8 -*-
"""
SPIKE-1a 复现脚本 —— libmpv 的 GL render API 会不会合成 PGS/SUP 图形字幕。
结论与完整数据见同目录 SPIKE-1a-PGS-render-api.md。

用法(两步):
    python spike-1a-mkclip.py            # 先造一个真 H.264 片(clip.mp4),否则测不到硬解
    python spike-1a-pgs.py <某个.sup文件> <该sup里某条字幕的中点秒数> [libmpv-2.dll路径]

字幕中点秒数怎么来:同目录 spike-1a-pgs-parse.py 会列出 .sup 里所有字幕的起止,
挑一条**足够长**的取中点。别随便填 —— 填到没字幕的时间点上,测出来的"没显示"是假阴性。

实验设计要点(照抄时别删):
  · 正对照:断言 track-list 里真有 codec=hdmv_pgs_subtitle 且 selected=yes 的轨
  · 负对照:同一设置连渲两次求差 = 噪声基线 N。只有信号 S >> N 才算数
  · dither=no + temporal-dither=no,否则噪声基线降不到 0
  · 视频静态 + pause=yes,差分里才只剩字幕
  · 用 sub-delay 把字幕挪到视频第 0 秒,**不要再叠 seek**(叠了外挂字幕流跟不上,S 会假 0)
  · mpv 事件号是 START_FILE=6 / END_FILE=7 / FILE_LOADED=8,别搞错
"""
import sys
_ARGV = sys.argv[1:]
if len(_ARGV) < 2:
    raise SystemExit(__doc__)
import ctypes as C, ctypes.wintypes as W, os, time, struct, zlib

DLL = _ARGV[2] if len(_ARGV) > 2 else os.path.join("crates","mpv","libmpv","libmpv-2.dll")
SUP = _ARGV[0]
SUB_T = float(_ARGV[1])
WIDTH, HEIGHT = 1280, 720
OUT = os.path.dirname(os.path.abspath(__file__))

def log(*a): print(*a, flush=True)

u32, g32, k32, ogl = C.windll.user32, C.windll.gdi32, C.windll.kernel32, C.windll.opengl32
WNDPROC = C.WINFUNCTYPE(C.c_longlong, C.c_void_p, C.c_uint, C.c_ulonglong, C.c_longlong)
u32.DefWindowProcW.argtypes = [C.c_void_p, C.c_uint, C.c_ulonglong, C.c_longlong]
u32.DefWindowProcW.restype  = C.c_longlong
u32.GetDC.argtypes = [C.c_void_p]; u32.GetDC.restype = C.c_void_p
u32.DestroyWindow.argtypes = [C.c_void_p]
u32.ShowWindow.argtypes = [C.c_void_p, C.c_int]
u32.CreateWindowExW.restype = C.c_void_p

class WNDCLASS(C.Structure):
    _fields_ = [("style",C.c_uint),("lpfnWndProc",WNDPROC),("cbClsExtra",C.c_int),
                ("cbWndExtra",C.c_int),("hInstance",W.HINSTANCE),("hIcon",W.HICON),
                ("hCursor",W.HANDLE),("hbrBackground",W.HBRUSH),
                ("lpszMenuName",W.LPCWSTR),("lpszClassName",W.LPCWSTR)]
class PFD(C.Structure):
    _fields_ = [("nSize",C.c_ushort),("nVersion",C.c_ushort),("dwFlags",C.c_uint),
                ("iPixelType",C.c_ubyte),("cColorBits",C.c_ubyte),("cRedBits",C.c_ubyte),
                ("cRedShift",C.c_ubyte),("cGreenBits",C.c_ubyte),("cGreenShift",C.c_ubyte),
                ("cBlueBits",C.c_ubyte),("cBlueShift",C.c_ubyte),("cAlphaBits",C.c_ubyte),
                ("cAlphaShift",C.c_ubyte),("cAccumBits",C.c_ubyte),("cAccumRedBits",C.c_ubyte),
                ("cAccumGreenBits",C.c_ubyte),("cAccumBlueBits",C.c_ubyte),
                ("cAccumAlphaBits",C.c_ubyte),("cDepthBits",C.c_ubyte),("cStencilBits",C.c_ubyte),
                ("cAuxBuffers",C.c_ubyte),("iLayerType",C.c_ubyte),("bReserved",C.c_ubyte),
                ("dwLayerMask",C.c_uint),("dwVisibleMask",C.c_uint),("dwDamageMask",C.c_uint)]
g32.ChoosePixelFormat.argtypes=[C.c_void_p,C.POINTER(PFD)]; g32.ChoosePixelFormat.restype=C.c_int
g32.SetPixelFormat.argtypes=[C.c_void_p,C.c_int,C.POINTER(PFD)]
g32.SwapBuffers.argtypes=[C.c_void_p]
ogl.wglCreateContext.argtypes=[C.c_void_p]; ogl.wglCreateContext.restype=C.c_void_p
ogl.wglMakeCurrent.argtypes=[C.c_void_p,C.c_void_p]
ogl.wglGetProcAddress.argtypes=[C.c_char_p]; ogl.wglGetProcAddress.restype=C.c_void_p
ogl.glGetString.argtypes=[C.c_uint]; ogl.glGetString.restype=C.c_char_p
ogl.glReadPixels.argtypes=[C.c_int,C.c_int,C.c_int,C.c_int,C.c_uint,C.c_uint,C.c_void_p]

_keep=[]
def make_gl_window():
    hInst = k32.GetModuleHandleW(None)
    proc = WNDPROC(lambda h,m,w,l: u32.DefWindowProcW(h,m,w,l)); _keep.append(proc)
    wc = WNDCLASS(); wc.lpfnWndProc=proc; wc.hInstance=hInst
    wc.lpszClassName="LPGLTest2"; wc.style=0x0020|0x0002|0x0001
    u32.RegisterClassW(C.byref(wc))
    hwnd = u32.CreateWindowExW(0,"LPGLTest2","libmpv PGS test",0x00CF0000,
                               -2000,100,WIDTH,HEIGHT,None,None,hInst,None)
    if not hwnd: raise OSError("CreateWindow 失败 %d"%k32.GetLastError())
    u32.ShowWindow(hwnd,5)
    hdc = u32.GetDC(hwnd)
    pfd = PFD(); pfd.nSize=C.sizeof(PFD); pfd.nVersion=1
    pfd.dwFlags=0x04|0x20|0x01; pfd.iPixelType=0
    pfd.cColorBits=32; pfd.cAlphaBits=8; pfd.cDepthBits=24
    pf = g32.ChoosePixelFormat(hdc, C.byref(pfd)); g32.SetPixelFormat(hdc, pf, C.byref(pfd))
    hglrc = ogl.wglCreateContext(hdc); ogl.wglMakeCurrent(hdc, hglrc)
    log("  GL_VERSION  =", ogl.glGetString(0x1F02).decode(errors="replace"))
    log("  GL_RENDERER =", ogl.glGetString(0x1F01).decode(errors="replace"))
    return hwnd, hdc, hglrc

class MSG(C.Structure):
    _fields_=[("hwnd",W.HWND),("message",C.c_uint),("wParam",C.c_ulonglong),
              ("lParam",C.c_longlong),("time",C.c_uint),("x",C.c_long),("y",C.c_long)]
def pump():
    m_=MSG()
    while u32.PeekMessageW(C.byref(m_),None,0,0,1):
        u32.TranslateMessage(C.byref(m_)); u32.DispatchMessageW(C.byref(m_))

GLPROC = C.CFUNCTYPE(C.c_void_p, C.c_void_p, C.c_char_p)
def _gp(ctx, name):
    p = ogl.wglGetProcAddress(name)
    if not p:
        k32.GetProcAddress.restype=C.c_void_p
        k32.GetProcAddress.argtypes=[C.c_void_p,C.c_char_p]
        p = k32.GetProcAddress(C.c_void_p(ogl._handle), name)
    return p or 0
GET_PROC = GLPROC(_gp)

os.add_dll_directory(os.path.dirname(DLL))
m = C.CDLL(DLL)
for fn, at, rt in [
    ("mpv_create",[],C.c_void_p),("mpv_initialize",[C.c_void_p],C.c_int),
    ("mpv_set_option_string",[C.c_void_p,C.c_char_p,C.c_char_p],C.c_int),
    ("mpv_command",[C.c_void_p,C.POINTER(C.c_char_p)],C.c_int),
    ("mpv_get_property_string",[C.c_void_p,C.c_char_p],C.c_void_p),
    ("mpv_free",[C.c_void_p],None),
    ("mpv_wait_event",[C.c_void_p,C.c_double],C.c_void_p),
    ("mpv_error_string",[C.c_int],C.c_char_p),
    ("mpv_terminate_destroy",[C.c_void_p],None),
    ("mpv_render_context_create",[C.c_void_p,C.c_void_p,C.c_void_p],C.c_int),
    ("mpv_render_context_render",[C.c_void_p,C.c_void_p],C.c_int),
    ("mpv_render_context_update",[C.c_void_p],C.c_ulonglong),
    ("mpv_render_context_free",[C.c_void_p],None)]:
    f=getattr(m,fn); f.argtypes=at; f.restype=rt

class RParam(C.Structure): _fields_=[("type",C.c_int),("data",C.c_void_p)]
class GLInit(C.Structure): _fields_=[("gpa",GLPROC),("ctx",C.c_void_p),("exts",C.c_char_p)]
class GLFbo(C.Structure): _fields_=[("fbo",C.c_int),("w",C.c_int),("h",C.c_int),("ifmt",C.c_int)]

def getprop(h,n):
    p=m.mpv_get_property_string(h,n.encode())
    if not p: return None
    s=C.cast(p,C.c_char_p).value.decode(errors="replace"); m.mpv_free(p); return s
def cmd(h,*a):
    arr=(C.c_char_p*(len(a)+1))(*[x.encode() for x in a],None); return m.mpv_command(h,arr)
def readpix():
    b=(C.c_ubyte*(WIDTH*HEIGHT*4))(); ogl.glReadPixels(0,0,WIDTH,HEIGHT,0x1908,0x1401,b); return bytes(b)
def save_png(path,rgba):
    rows=bytearray()
    for y in range(HEIGHT-1,-1,-1):
        rows.append(0); rows+=rgba[y*WIDTH*4:(y+1)*WIDTH*4]
    def ck(t,d):
        c=t+d; return struct.pack(">I",len(d))+c+struct.pack(">I",zlib.crc32(c)&0xffffffff)
    open(path,"wb").write(b"\x89PNG\r\n\x1a\n"
        +ck(b"IHDR",struct.pack(">IIBBBBB",WIDTH,HEIGHT,8,6,0,0,0))
        +ck(b"IDAT",zlib.compress(bytes(rows),6))+ck(b"IEND",b""))

def diff_stats(A,B,tol=6):
    """返回 (差异像素数, 包围盒, 差异掩膜 PNG 数据)。tol 容忍轻微抖动。"""
    n=0; x0,y0,x1,y1 = WIDTH,HEIGHT,-1,-1
    mask=bytearray(WIDTH*HEIGHT*4)
    for i in range(0,len(A),4):
        if (abs(A[i]-B[i])>tol or abs(A[i+1]-B[i+1])>tol or abs(A[i+2]-B[i+2])>tol):
            n+=1; px=(i//4)%WIDTH; py=(i//4)//WIDTH
            if px<x0:x0=px
            if px>x1:x1=px
            if py<y0:y0=py
            if py>y1:y1=py
            mask[i]=255; mask[i+1]=0; mask[i+2]=255; mask[i+3]=255
        else:
            mask[i+3]=255
    return n, (x0,y0,x1,y1), bytes(mask)


# ---- GL 3.0 FBO 函数(core 1.1 的直接从 opengl32 拿,3.0 的走 wglGetProcAddress)----
def glfn(name, argt, rest=None):
    p = _gp(None, name.encode())
    if not p: raise OSError("拿不到 GL 函数 " + name)
    return C.CFUNCTYPE(rest or None, *argt)(p)

ogl.glGenTextures.argtypes=[C.c_int,C.c_void_p]
ogl.glBindTexture.argtypes=[C.c_uint,C.c_uint]
ogl.glTexImage2D.argtypes=[C.c_uint,C.c_int,C.c_int,C.c_int,C.c_int,C.c_int,C.c_uint,C.c_uint,C.c_void_p]
ogl.glTexParameteri.argtypes=[C.c_uint,C.c_uint,C.c_int]

def make_texture_fbo():
    glGenFramebuffers      = glfn("glGenFramebuffers",[C.c_int,C.c_void_p])
    glBindFramebuffer      = glfn("glBindFramebuffer",[C.c_uint,C.c_uint])
    glFramebufferTexture2D = glfn("glFramebufferTexture2D",[C.c_uint,C.c_uint,C.c_uint,C.c_uint,C.c_int])
    glCheckFramebufferStatus = glfn("glCheckFramebufferStatus",[C.c_uint],C.c_uint)
    tex=C.c_uint(); ogl.glGenTextures(1,C.byref(tex))
    ogl.glBindTexture(0x0DE1,tex.value)                      # GL_TEXTURE_2D
    ogl.glTexImage2D(0x0DE1,0,0x8058,WIDTH,HEIGHT,0,0x1908,0x1401,None)  # GL_RGBA8
    for p_ in (0x2801,0x2800): ogl.glTexParameteri(0x0DE1,p_,0x2601)     # LINEAR
    for p_ in (0x2802,0x2803): ogl.glTexParameteri(0x0DE1,p_,0x812F)     # CLAMP_TO_EDGE
    fb=C.c_uint(); glGenFramebuffers(1,C.byref(fb))
    glBindFramebuffer(0x8D40,fb.value)                       # GL_FRAMEBUFFER
    glFramebufferTexture2D(0x8D40,0x8CE0,0x0DE1,tex.value,0) # COLOR_ATTACHMENT0
    st=glCheckFramebufferStatus(0x8D40)
    if st!=0x8CD5: raise OSError("FBO 不完整: 0x%X"%st)
    glBindFramebuffer(0x8D40,0)
    return fb.value, tex.value, glBindFramebuffer


CLIP = os.path.join(OUT,"clip.mp4")
SEEK = 0.0   # 不 seek:大幅负 sub-delay + seek 会让外挂字幕流跟不上(v4 第一版栽在这)

def run_case(name, hwdec, hdc, tex_fbo, bindfb):
    log(""); log("-"*70)
    log("用例:%s  (自建纹理 FBO,真 H.264 文件,hwdec=%s)"%(name,hwdec))
    h=C.c_void_p(m.mpv_create())
    for k,v in {"vo":"libmpv","hwdec":hwdec,"keep-open":"yes","pause":"yes",
                "sub-files":SUP.replace("\\","/"),"sub-delay":"%.3f"%(SEEK-SUB_T),
                "terminal":"no","gpu-api":"opengl","dither":"no","temporal-dither":"no"}.items():
        m.mpv_set_option_string(h,k.encode(),v.encode())
    if m.mpv_initialize(h)<0: log("   初始化失败"); return None
    api=C.c_char_p(b"opengl"); gi=GLInit(GET_PROC,None,None); adv=C.c_int(1)
    ps=(RParam*4)(RParam(1,C.cast(api,C.c_void_p)),RParam(2,C.cast(C.byref(gi),C.c_void_p)),
                  RParam(10,C.cast(C.byref(adv),C.c_void_p)),RParam(0,None))
    rctx=C.c_void_p()
    r=m.mpv_render_context_create(C.byref(rctx),h,ps)
    if r<0: log("   render_context_create 失败"); return None
    cmd(h,"loadfile",CLIP.replace("\\","/"))
    t0=time.time(); ok=False
    while time.time()-t0<25:
        pump(); ev=m.mpv_wait_event(h,0.05)
        if ev and C.cast(ev,C.POINTER(C.c_int)).contents.value==8: ok=True; break
    if not ok: log("   FILE_LOADED 没等到"); return None
    for _ in range(60): pump(); m.mpv_render_context_update(rctx); time.sleep(0.02)
    n=int(getprop(h,"track-list/count") or 0); pgs=False
    for i in range(n):
        if getprop(h,"track-list/%d/type"%i)=="sub":
            co=(getprop(h,"track-list/%d/codec"%i) or "").lower()
            if "pgs" in co and getprop(h,"track-list/%d/selected"%i)=="yes": pgs=True
    hwc=getprop(h,"hwdec-current")
    log("   video=%s  hwdec-current=%s  time-pos=%s  PGS已选=%s  sub=%s~%s"%(
        getprop(h,"video-codec"),hwc,getprop(h,"time-pos"),pgs,
        getprop(h,"sub-start"),getprop(h,"sub-end")))
    fbo=GLFbo(tex_fbo,WIDTH,HEIGHT,0x8058); flip=C.c_int(1)
    rps=(RParam*3)(RParam(3,C.cast(C.byref(fbo),C.c_void_p)),
                   RParam(4,C.cast(C.byref(flip),C.c_void_p)),RParam(0,None))
    def render():
        for _ in range(6):
            pump(); bindfb(0x8D40,tex_fbo); m.mpv_render_context_render(rctx,rps)
            ogl.glFinish(); time.sleep(0.04)
        bindfb(0x8D40,tex_fbo); px=readpix(); bindfb(0x8D40,0); return px
    cmd(h,"set","sub-visibility","yes"); time.sleep(0.5)
    A1=render(); A2=render(); Nn,_,_=diff_stats(A1,A2)
    cmd(h,"set","sub-visibility","no"); time.sleep(0.5)
    B=render(); S,(x0,y0,x1,y1),_=diff_stats(A2,B)
    nb=sum(1 for i in range(0,len(A2),4) if A2[i] or A2[i+1] or A2[i+2])
    save_png(os.path.join(OUT,"v4_%s.png"%name),A2)
    log("   视频非黑=%.1f%%  噪声N=%d  字幕S=%d  包围盒 x%d..%d y%d..%d"%(
        nb*100.0/(WIDTH*HEIGHT),Nn,S,x0,x1,y0,y1))
    m.mpv_render_context_free(rctx); m.mpv_terminate_destroy(h)
    return dict(name=name,hwc=hwc,pgs=pgs,nb=nb,N=Nn,S=S)

def main():
    log("="*70); log("v4:真 H.264 文件 + 自建纹理 FBO + 真硬解"); log("="*70)
    if not os.path.exists(CLIP): raise SystemExit("缺 clip.mp4")
    hwnd,hdc,hglrc=make_gl_window()
    fb,tex,bindfb=make_texture_fbo()
    log("  纹理 FBO id=%d tex=%d"%(fb,tex))
    res=[]
    for nm,hw in [("swdec","no"),("hwdec_auto","auto"),("hwdec_d3d11va","d3d11va")]:
        try: res.append(run_case(nm,hw,hdc,fb,bindfb))
        except Exception as e: log("   异常 %r"%e); res.append(None)
    log(""); log("="*70); log("汇总(全部渲进自建纹理 FBO)")
    log("%-16s %-14s %-7s %-9s %-7s %-7s"%("用例","hwdec-current","PGS轨","视频非黑","噪声N","字幕S"))
    for r in res:
        if not r: log("  (失败)"); continue
        log("%-16s %-14s %-7s %-8.1f%% %-7d %-7d"%(r["name"],r["hwc"],r["pgs"],
            r["nb"]*100.0/(WIDTH*HEIGHT),r["N"],r["S"]))
    good=[r for r in res if r and r["pgs"] and r["S"]>500 and r["N"]<200]
    log("="*70)
    log("合成了 PGS 的用例:%d / %d"%(len(good),len([r for r in res if r])))
    ogl.wglMakeCurrent(hdc,None); u32.DestroyWindow(hwnd)

main()
