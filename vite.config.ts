import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { sentryVitePlugin } from "@sentry/vite-plugin";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// @ts-expect-error process is a nodejs global
const host = process.env.TAURI_DEV_HOST;
// @ts-expect-error process is a nodejs global
const sentryToken = process.env.SENTRY_AUTH_TOKEN;

/* 版本的唯一权威是 tauri.conf.json —— pack-portable.ps1 拿它给 zip 命名,
   src-tauri/build.rs 拿它注入 LP_VERSION 给 Rust 侧的 Sentry release。
   这里读同一个字段,是为了让前端的 release 名和 Rust 的**逐字一致**:
   sourcemap 按 release 挂,对不上就等于没传。 */
const version = JSON.parse(readFileSync("./apps/desktop/tauri.conf.json", "utf-8")).version;

// https://vite.dev/config/
export default defineConfig(async () => ({
  plugins: [
    react(),
    /* sourcemap 上传。没有 token 就整个不挂 —— 本地 `npm run build` / 别人 clone 下来
       构建都不该因为少个密钥而红。CI 和 npm run pack 会带上它。
       ★ 上传完删本地 .map:sourcemap 等于把整份前端源码塞进发行 zip,不能进用户手里。 */
    sentryToken &&
      sentryVitePlugin({
        org: "linplayer",
        /* ★ 必须是 DSN 所指的那个项目。名字叫 "flutter" 是历史包袱(移动端先建的),
           但 DSN 末段的项目 id 4511717262032896 就是它 —— 事件落在这个项目里,
           sourcemap 却传到别的项目 = 传了等于没传,而且**两边都不会报错**。
           哪天真给 PC 单开一个项目,要同时换三处:这里、pack-portable.ps1、
           以及 src/telemetry.ts 和 src-tauri/src/telemetry.rs 里的 DSN。 */
        project: "flutter",
        authToken: sentryToken,
        release: { name: `linplayer-pc@${version}` },
        sourcemaps: { filesToDeleteAfterUpload: ["./dist/**/*.map"] },
        telemetry: false, // 不给 Sentry 上报我们自己的构建行为
        /* ★ 没有这行,上传失败(token 过期/网络不通)时插件只打一行红字,
           `vite build` 照样 exit 0 —— CI 全绿,而线上堆栈永远是 index-a1b2c3.js:1:48291,
           等真崩了才发现半年没传过 sourcemap。实测过:默认行为确实 exit=0。
           给了 token 就是明确要求上传,传不上去就该红。 */
        errorHandler: (err) => {
          throw err;
        },
      }),
  ],

  define: { __APP_VERSION__: JSON.stringify(version) },

  /* 只在**要上传**时才生成 sourcemap。没 token 还生成的话,那些 .map 会被 tauri 一起
     打进 exe 的内嵌资源(frontendDist 整个塞进二进制)= 把整份前端源码发给用户。
     删除动作挂在插件的 filesToDeleteAfterUpload 上,而插件在没 token 时压根不存在。 */
  /* 四个入口:
       index.html         → 桌面 UI(ui/desktop)
       index-tv.html      → Android TV UI(ui/tv,10-foot 版式 + 遥控焦点)
       index-mobile.html  → Android 手机 UI(ui/mobile,触摸版式 + 手势)
       index-android.html → 安卓壳的**分流 shim**,按 UA 标转到上面两者之一
     TV 和手机是**两套完整界面**,不是彼此的响应式断点(交互模型根本不同:
     一个是遥控焦点格子,一个是拇指手势),所以各自独立入口独立产物。
     桌面用户不该下载 TV 的代码,手机用户不该下载遥控焦点库,反之亦然。

     ★ 一旦写了 rollupOptions.input,vite 就不再默认打包 index.html,
       **每一个都得列出来**(漏掉的那个不会报错,只是静默产不出 html)。
       2026-07-26 加手机端时这条差点又栽:漏了 index-android.html 的话,
       安卓壳打开的是个 404,而 CI 全绿。 */
  build: {
    sourcemap: Boolean(sentryToken),
    rollupOptions: {
      input: {
        main: fileURLToPath(new URL("./index.html", import.meta.url)),
        tv: fileURLToPath(new URL("./index-tv.html", import.meta.url)),
        mobile: fileURLToPath(new URL("./index-mobile.html", import.meta.url)),
        android: fileURLToPath(new URL("./index-android.html", import.meta.url)),
      },
    },
  },

  /* ui/shared 是各端(desktop/mobile/tv)共用的那一层 —— api 桥、主题 token。
     用别名而不是 ../../shared 相对路径:mobile/tv 的目录深度和 desktop 不一样,
     相对路径写法会在每个端各写一套。tsconfig.json 的 paths 必须同步,否则
     `tsc` 红而 vite 绿。 */
  resolve: {
    alias: { "@shared": fileURLToPath(new URL("./ui/shared", import.meta.url)) },
  },

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent Vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // 3. tell Vite to ignore watching `src-tauri`
      /* ★ 必须挡掉安卓的 gradle 构建树。
         gen/android/app/build/ 里有正在被 gradle 写的 .so,vite 的 FSWatcher
         监听到它会直接 EBUSY **崩掉整个 dev server**(实测:
         watch liblinplayer_android_lib.so → errno -4082 → 进程退出)。
         症状是"跑着跑着前端就没了",而报错在 chokidar 深处,很难联想到安卓构建。 */
      ignored: [
        "**/apps/desktop/**",
        "**/apps/android/gen/**",
        "**/target/**",
      ],
    },
  },
}));
