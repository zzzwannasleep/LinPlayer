# 手机端阻塞与欠账清单

> 格式:每条一个 `B<编号>`。**「需要人做什么」这一栏不许空** ——
> 没有这一栏的条目等于把问题埋起来。

---

## B1 · `source.formSchema` 不存在,源表单只能写在 UI 里

- **撞到的时间 / 阶段**:2026-09-06,阶段 ③(写 `UI_MOBILE.md` §7.1)
- **现象与证据**:
  `SPEC.md:1136` 与 `UI_PC.md:809` 都写着「表单字段定义下沉核心层
  (`source.formSchema` 返回声明式描述),三端各写一个渲染器」。
  但 218 条命令里没有这一条:
  ```
  $ grep -c "formSchema" docs/go-migration/COMMANDS.md   → 0
  $ grep -rn "formSchema\|form_schema" core/ --include=*.go   → 无结果
  ```
  PC 端也没按那个契约做 —— 源类型表硬编在
  `apps/windows/LinPlayer.Desktop/Views/Pages.cs:150-155`(`var kinds = new[]{...}`)。
- **我试过的**:
  1. `grep` 命令表与 Go 注册表两处,确认命令确实不存在(不是名字写法不同)
  2. 读 PC 端 `AddServerPage`,确认它也是硬编 —— 所以不是「安卓漏接了一条命令」
  3. 考虑在核心层新增这条命令 —— **否决**:`PROMPT_MOBILE_UI.md` 的预置默认写着
     「需要改 `core/**` 就不改」,而且新增命令要同时改 `COMMANDS.md` 并过
     `check-bindings.sh` 第 4 关的双向比对,牵动三端绑定
- **我采取的默认决策**:照 PC 的做法,源类型表写在
  `apps/android/app/src/main/kotlin/.../ui/pages/AddServerPage.kt` 一处。
- **代价 / 后面要还的债**:新增一种源类型要改**两处**(PC 一处 + 安卓一处),
  漏掉的那处就是「某个入口加不了这种源」。TV 端做完会变成三处。
- **需要人做什么**:决定要不要真的做 `source.formSchema`。
  要做的话:核心层加一条命令返回字段声明(kind / label / placeholder / type /
  required / 分组),三端各写渲染器,PC 与安卓的硬编表同时删掉。
  不做的话:把 `SPEC.md` §8.1 与 `UI_PC.md` §7.6 里那段改成事实,别留一个假契约。

---

## B2 · 安卓的本机文件夹源:SAF 的 `content://` 交不给 mpv

- **撞到的时间 / 阶段**:2026-09-06,阶段 ③(`UI_MOBILE.md` §7.16)
- **现象与证据**:
  `local` 源要求一个**文件系统路径**(核心层把它交给 mpv 当裸路径)。
  安卓上选目录只有 SAF(`ActivityResultContracts.OpenDocumentTree`),
  它给的是 `content://com.android.externalstorage.documents/tree/...`,
  不是路径。`system.pickLocalFolder` 在安卓上会进 `capabilities.unsupported`。
- **我试过的**:
  1. 把 `content://` 直接交给 mpv —— mpv 的 stream 层不认这个 scheme
     (它认 file/http/smb 等,`protocol-list` 里没有 content)
  2. 用 `MANAGE_EXTERNAL_STORAGE`(全盘访问)拿真实路径 —— **否决**:
     Google Play 对这个权限有严格审核,而且对一个播放器是过重的要求
  3. 把 SAF 选中的整个目录复制进应用私有目录 —— 对媒体目录不现实(几十 GB)
- **我采取的默认决策**:**本轮不做安卓的本机目录源**。
  §7.1 的源芯片在安卓上只有 Emby 一条,按「只剩一种源类型时整条不画」的规矩,
  芯片条整个不出现。小文件(本地图标 / 本地弹幕 / 外挂字幕)走
  「SAF 选 → 复制进 `filesDir` → 把真实路径交核心层」这条路,可以做。
- **代价 / 后面要还的债**:安卓用户不能播本机视频。
  `AGENTS.md` §0 说「本机文件夹播放是播放器的基础能力」—— 这条能力在安卓上缺着。
- **需要人做什么**:选一条路:
  ① 核心层的 `local` 源支持从 `content://` 读(要在 Go 侧起一个本地 HTTP 桥,
     把 SAF 的 `ParcelFileDescriptor` 转成 Range 可寻址的 `http://127.0.0.1/...`
     —— 和已经删掉的 SMB 桥是同一个形状,`git show rust-final:` 里有参考);
  ② 只支持 `getExternalFilesDir()` 下的目录(应用私有,有真实路径,不需要权限),
     让用户把视频拷进去;
  ③ 接受安卓上没有本机播放。

---

## B3 · 插件的自定义 UI(`plugin.ui` 事件)在安卓上没有承载

- **撞到的时间 / 阶段**:2026-09-06,阶段 ③(`UI_MOBILE.md` §7.12)
- **现象与证据**:
  `SPEC.md` §9.3 规定插件自定义 UI 走**独立 origin 的 WebView**。
  PC 端用 WebView2。安卓上要么用系统 `WebView`,要么不做。
  `plugin.ui` 事件的载荷是 `{id, kind, descriptor}` —— `kind` 里既有声明式的
  (表单 / 列表 / 确认),也可能是「整页」形态。
- **我试过的**:
  1. 用 `androidx.webkit` + `WebView` 起一个隔离页 —— 可行,但要处理
     origin 隔离、`shouldInterceptRequest` 白名单、内存(WebView 进程 ~40MB)
  2. 只做声明式描述符,「整页」形态返回不支持 —— 本轮 16 页里没有任何一页依赖整页形态
  3. 查已装插件里有没有用整页形态的 —— 本机没有插件样本可查(`plugin.list` 是空的)
- **我采取的默认决策**:**本轮只实现声明式描述符**(表单 / 列表 / 确认三种),
  「整页」形态调 `plugin.uiRespond` 回一个「本平台不支持」,**不弹错**。
- **代价 / 后面要还的债**:用「整页」形态的插件在安卓上功能残缺。
- **需要人做什么**:确认有没有插件真的在用整页形态。有的话再决定是否引入 WebView。

---

## B4 · 六份 Compose 生态调研的版本号系统性过时

- **撞到的时间 / 阶段**:2026-09-06,阶段 ②出口抽查
- **现象与证据**:抽查七条,五条错。逐条见
  [`research/VERSIONS_VERIFIED.md`](research/VERSIONS_VERIFIED.md) 的抽查表。
  典型:Navigation Compose 说 2.8.6(实为 2.10.0)、media3 说 1.3.0(实为 1.11.0)、
  telephoto 说 0.13.0(实为 1.0.0-alpha02)、URL 域名写成 `developer.android.google.com`
  (不存在)。
- **我试过的**:
  1. 直接从 Google Maven / Maven Central 的 `maven-metadata.xml` 拉真值 —— 有效,已落表
  2. 让子 agent 重跑 —— 没做:根因是**离线知识给不出版本号**,重跑同样过时
  3. 只信「结构性结论」(API 是否存在、语义、坑),版本另查 —— 采纳
- **我采取的默认决策**:建 `research/VERSIONS_VERIFIED.md` 作为版本唯一权威,
  在六份调研文档顶部各加一条指向它的横幅。
- **代价 / 后面要还的债**:六份文档里的版本数字仍然是错的(只是被横幅标注了)。
  谁把横幅删了,谁就会照着错数字写 `build.gradle.kts`。
- **需要人做什么**:无需人工介入。**下次派调研 agent 时,版本号一律不许由 agent 给**
  —— 让它写「查 Maven」并给出查询命令,数字由主 agent 现拉。

---

## B5 · 模拟器的 EGL 谎报支持,导致 mpv 建不出 GL 上下文(真机不受影响)

- **撞到的时间 / 阶段**:2026-09-06,阶段 ⑦(播放链路真机验证)
- **现象与证据**:
  surface 绑定成功、命令全部返回成功、mpv 也真的读到了流,
  但界面上一直黑屏。核心层日志(本次一并补上的 mpv error 转发)给出:
  ```
  [核心层:info] surface 已绑定 1080x2400
  [核心层:info] PLAY item=ep-1 resume=0.0 psid=… method=DirectStream
  [核心层:warn] mpv: Initializing GPU context 'android'
  [核心层:warn] mpv: EGL_VERSION=1.4 Android META-EGL
  [核心层:warn] mpv: Trying to create GLES 2.x + context.
  [核心层:warn] mpv: Chosen EGLConfig: EGL_CONFORMANT=0x45 …
  [核心层:warn] mpv: Could not create EGL context for GLES 2.x +!
  [核心层:warn] mpv: AVIOContext: Statistics: 1362407 bytes read, 1 seeks
  ```
  最后一行是关键旁证:**取流那条链是通的**(会话参数 → `player.play` →
  DirectStream → mpv 的 HTTP 读了 1.36 MB),坏的只有 GL 上下文这一步。

  自己写探针在**同一个进程**里走一遍 EGL(临时加在 JNI 层,已撤):
  ```
  init=1 1.4 err=0x3000                          eglInitialize 成功
  choose=1 n=1 err=0x3000                        eglChooseConfig 成功
  bindAPI=1 err=0x3000                           eglBindAPI 成功
  createContext=0x7d8e9d947130 err=0x3000        ← 不带 FLAGS_KHR:成功
  createContext(FLAGS_KHR,v3)=0x0 err=0x3004     ← 带 FLAGS_KHR:EGL_BAD_ATTRIBUTE
  createContext(FLAGS_KHR,v2)=0x0 err=0x3004
  has_create_context=1                           ← 扩展字符串里**声称**支持
  ```
  **模拟器的 EGL 转换层在 `EGL_EXTENSIONS` 里声称支持 `EGL_KHR_create_context`,
  却对 `EGL_CONTEXT_FLAGS_KHR` 回 `EGL_BAD_ATTRIBUTE`。**
  mpv 只要看到那个扩展就会带上这个属性,于是两次尝试(GLES 3 / GLES 2)全失败。
- **我试过的**:
  1. 换 GPU 后端:`-gpu swiftshader_indirect` → `-gpu host`(RTX 5060 直通),
     现象一字不变 —— 排除「软件渲染太弱」
  2. 提高 mpv 日志级别到 `v` / `debug`,拿到 EGL 版本、厂商、选中的 EGLConfig
     全表 —— 确认 config 是 conformant 的(`EGL_CONFORMANT=0x45`,ES2+ES3 都在)
  3. 在同进程里自写 EGL 探针做 A/B(带 / 不带 `EGL_CONTEXT_FLAGS_KHR`)——
     这一步才定的性:**不是我们的进程不能建 GL 上下文,是那一个属性被拒**
- **我采取的默认决策**:**不为它加绕过。** 这是模拟器 EGL 转换层的缺陷,
  真机上 `EGL_KHR_create_context` 是真的(mpv-android / media_kit 常年在用这条路)。
  为一个只在模拟器上出现的问题去改 mpv 的上下文创建路径,是拿真机的正确性换自检的绿。
  改的是**别的**:起播失败不再静默退回上一页,而是当场说「这一片没能播起来」
  并指向诊断信息 —— 那个静默退回才是真正会伤到用户的行为。
- **代价 / 后面要还的债**:**「有画面」这一条判据在模拟器上验不了**,
  只验到了「surface 绑上了 + 取流通了 + mpv 走到 EGL 这一步」。
- **需要人做什么才能真正解决**:
  拿一台**真机**跑一次(`LP_SELFCHECK_HOST=<同网段主机地址> bash scripts/selfcheck-android.sh`,
  然后 `am start ... -e lp_page 'player:<条目id>:x'`),确认出画面。
  判据不是截图 —— `screencap` 抓不到 SurfaceView;用
  `adb shell dumpsys SurfaceFlinger` 看图层有没有在刷新,加上 `player.status` 的
  position 是否在往前走。

---

## B6 · 弹幕开关没有对应的核心层命令

- **撞到的时间 / 阶段**:2026-09-06,阶段 ⑦(`check-android-args.py` 首次运行)
- **现象与证据**:
  播放器面板的「弹幕开 / 关」原来发的是
  `danmaku.setDanmakuConfig("enabled" to true)`。而那条命令读的是 `sources`
  —— 一张**弹幕源清单**,和开关毫无关系:
  ```
  core/danmaku/commands.go:66:  raw, ok := a["sources"]
  ```
  传 `enabled` 核心层直接报「缺少 sources」,或者(传了 sources 时)把开关
  当成未知键忽略。两种都不是「开关生效了」。
- **我试过的**:
  1. 在 218 条命令里找弹幕开关 —— `danmaku.*` 一共 14 条,
     `load / autoLoad / filter / getDanmakuConfig / setDanmakuConfig / …`,
     **没有一条是「开 / 关」**
  2. 看 `player.*` 有没有 —— 也没有;弹幕渲染在核心层的 `osd-overlay`(SPEC §7.5),
     开关应当是「加载 / 不加载弹幕」而不是一个显隐位
  3. 用 `danmaku.load` / 不 load 来表达开关 —— 可行,但「关」之后要能再「开」,
     需要一条「卸载当前弹幕」的命令,同样没有
- **我采取的默认决策**:面板里那一项**先不接线**(`"danmaku" -> Unit`),
  不发一条注定不生效的命令。**不写「待接」注释** —— 记在这里。
- **代价 / 后面要还的债**:播放器面板的弹幕入口点了没有效果。
  比原来好的地方是:它不再**假装**生效(原来会静默失败)。
- **需要人做什么**:确认弹幕开关的契约。要么核心层加一条
  `danmaku.setEnabled`(PC 端也需要),要么定成「`danmaku.load` 之后就一直开,
  关只影响样式」并把 UI 那一项去掉。

---

## B7 · 深浅色覆盖在核心层没有落点

- **撞到的时间 / 阶段**:2026-09-06,同上
- **现象与证据**:设置页的「主题:跟随系统 / 深色 / 浅色」原来发
  `prefs.setPrefs("theme" to …)`,而那条命令只认三个键:
  ```
  core/prefs/prefs.go:39-43  audio_lang / sub_lang / sub_enabled
  ```
  多出来的 `theme` 被当作未知键忽略,**核心层照常返回成功** ——
  一个永远不生效的开关,而且不报错。
- **我试过的**:
  1. 在 `prefs.*` 25 条里找主题项 —— 没有
  2. 在 `config` 里找 —— 也没有
  3. 加一条核心层命令 —— 否决(本轮不改 `core/**`,见预置默认)
- **我采取的默认决策**:主题存进**本机 SharedPreferences**
  (`data/UiPrefs.kt`),并在那个文件里写清边界:**只放纯呈现的、
  只属于这一台设备的东西**,任何有核心层消费点的都不许进去。
  理由:深浅色本来就不该跨设备同步 —— 手机上强制深色不代表电视上也要,
  它和「我在哪一页、滚到哪」是同一类。
- **代价 / 后面要还的债**:换设备 / 重装后主题回到「跟随系统」。
- **需要人做什么**:如果希望主题跟着账号走,核心层加一个 `theme` 偏好,
  三端一起改;不希望的话把 `SPEC.md` §8.5 那句「一切持久化归核心层」
  补一条「纯呈现的设备本地偏好除外」。
