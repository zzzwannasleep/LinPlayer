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
