# LinPlayer

<p align="center">
  <a href="https://github.com/zzzwannasleep/LinPlayer/stargazers"><img src="https://img.shields.io/github/stars/zzzwannasleep/LinPlayer?style=flat&logo=github&label=Stars" alt="Stars"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/github/v/release/zzzwannasleep/LinPlayer?label=stable&color=blue" alt="Stable"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/github/v/release/zzzwannasleep/LinPlayer?include_prereleases&label=pre-release&color=orange" alt="Pre-release"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/github/downloads/zzzwannasleep/LinPlayer/total?label=downloads&color=green&logo=github" alt="Downloads"></a>
  <a href="https://linplayer.sentry.io"><img src="https://img.shields.io/endpoint?url=https://linplayeroaproxy.pages.dev/sentry/users" alt="Active Users"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/blob/main/LICENSE"><img src="https://img.shields.io/github/license/zzzwannasleep/LinPlayer" alt="License"></a>
  <img src="https://img.shields.io/badge/Go-1.24+-00ADD8?logo=go&logoColor=white" alt="Go">
  <img src="https://img.shields.io/badge/C%23-.NET%2010-512BD4?logo=dotnet&logoColor=white" alt="C#">
  <img src="https://img.shields.io/badge/Avalonia-11-8B44AC" alt="Avalonia">
  <a href="https://github.com/zzzwannasleep/LinPlayer/actions"><img src="https://img.shields.io/github/actions/workflow/status/zzzwannasleep/LinPlayer/build.yml?branch=main&label=build&logo=github" alt="Build"></a>
  <a href="https://t.me/MikudesuChannels"><img src="https://img.shields.io/badge/Telegram-MikudesuChannels-26A5E4?logo=telegram&logoColor=white" alt="Telegram"></a>
</p>

<p align="center">
  <a href="../README.md">简体中文</a> ·
  <a href="README.en.md">English</a> ·
  <b>日本語</b>
</p>

**LinPlayer** は Emby サードパーティクライアントです。共通の Go コア + 各プラットフォームのネイティブ UI という構成で、対象は **Windows / Android / Android TV / Linux**。現時点で **Windows と Android（スマートフォン / タブレット）が利用可能**です。

> ### 🚧 移行中
>
> 本プロジェクトは **Rust コア + React/Tauri** から **Go コア + 各プラットフォームのネイティブ UI** へ移行しました。
> 旧 Rust/Tauri スタックは 2026-09-04 にリポジトリから削除され、タグ [`rust-final`](https://github.com/zzzwannasleep/LinPlayer/tree/rust-final) がその最終状態です。
>
> | プラットフォーム | 状況 |
> |:--|:--|
> | **Windows** | 利用可能、通常どおり配布中。インストール不要の ZIP で、データはすべて実行ファイルと同じ階層の `userdata/` に入ります |
> | **Android スマホ / タブレット** | 利用可能（2026-09-06 以降）。Jetpack Compose によるネイティブ UI、署名済み APK を配布 |
> | **Android TV** | 未着手 —— タッチ前提の操作はリモコンに移植できないため、フォーカス移動版を別に作る必要があります |
> | **Linux** | 未着手 —— 旧 Tauri 実装はリファクタとともに削除されました。過去のビルドは Releases から入手できます |
> | **Apple 系** | 対応予定なし |

## ダウンロード

[**Releases**](https://github.com/zzzwannasleep/LinPlayer/releases) から入手できます：

- **Windows** —— `LinPlayer-Windows-v*.zip`。インストール不要、解凍してそのまま実行でき、レジストリにも書き込みません。更新は同じフォルダーに上書きするだけ —— アカウントと設定は `userdata/` にあるので消えません。
- **Android** —— `app-arm64-v8a-release.apk`（arm64 のスマホ / タブレット）。
- チャンネルは 2 つ：**stable** と **pre-release**。インストール後は「設定 → このアプリについて → 更新を確認」からそのままダウンロードして上書きできます。

## 機能

ビジネスロジック（Emby プロトコル / ネットワーク / 再生制御 / 同期 / ダウンロード / プラグイン）は**全プラットフォーム共通の単一 Go コア**にまとまっており、`lpcore` 共有ライブラリとしてビルドされます。各プラットフォームは自分の UI だけを、それぞれの流儀で書きます。したがって下表の ⬜ は「未着手」ではなく、**コアは完成済みで、そのプラットフォームの UI 配線だけが残っている**という意味です。

| 機能 | 説明 | Windows | Android |
|:--|:--|:--:|:--:|
| **MPV 再生コア** | 全フォーマット；HDR / Dolby Vision（gpu-next + ソフトデコードへ自動切替）；PGS/SUP 画像字幕；Anime4K 画質強化 6 段階 | ✅ | ✅ |
| **第 2 のコア（ExoPlayer）** | Android 限定、再生ボタン長押しで切替。このコアでは画質強化は使えません（glsl-shaders は mpv のもの） | — | ✅ |
| **弾幕** | DanDanPlay ほか複数バックエンド、話数の自動マッチング、ソース並列取得、検索と 9 項目の表示設定 | ✅ | ✅ |
| **字幕** | Emby の字幕ストリームを自動読み込み；トラック切替、遅延、フォント/サイズ/位置；libass の全効果と埋め込みフォント | ✅ | ✅ |
| **再生記録の同期** | Emby への進捗報告、サーバーをまたぐレジューム | ✅ | ✅ |
| **放送カレンダー** | Trakt / Bangumi の放送スケジュール（Android は現状 Bangumi のみ） | ✅ | ✅ |
| **ランキング** | DanDanPlay アニメランキング + TMDB 映画・ドラマランキング | ✅ | ✅ |
| **ダウンロード** | 自前のマルチスレッド Range 分割ダウンロードエンジン | ✅ | ✅ |
| **マルチスレッド読み込み** | ローカル先読みプロキシ。並列 Range 要求で先回りして取得しプレーヤーへ供給 | ✅ | ✅ |
| **プラグイン** | QuickJS エンジン、プラグインごとの隔離と権限確認。クラッシュやタイムアウトはホストに波及しません | ✅ | ✅ |
| **アプリ内更新** | 2 チャンネル（stable / pre）、ダウンロードして上書き | ✅ | ✅ |
| **Trakt / Bangumi** | 視聴履歴の Scrobble とアニメ進捗の同期 | ✅ | ⬜ |
| **プロキシ** | カスタムプロキシ + Cloudflare 最速 IP ローカルリバースプロキシ | ✅ | ⬜ |
| **サーバー一括追加** | 複数行の設定を貼り付けて一括で解析・取り込み | ✅ | ⬜ |
| **設定の移行** | QR コードで端末間にサーバー設定を直接転送（認証情報込み、クラウドを経由しない） | ✅ | ⬜ |
| **キーボードショートカット** | 再生画面のキー操作とキー一覧の表示 | ✅ | — |

<sub>✅ 配線済みで利用可能 · ⬜ コアは完成済み、このプラットフォームの UI が未配線 · — 対象外</sub>

> **対象外にしたもの**（2026-09-04 決定）：クラウドストレージ（Aliyun / Baidu / 115 / 189 / 139 / Quark / OpenList / 飛牛）、
> LAN ソース（SMB / WebDAV / FTP）、Ani-RSS はすべて取りやめ、コードも削除済みです。
> 動画リソースサイトは今後**プラグインの形でのみ**提供されます。ローカルフォルダー再生は残します —— プレーヤーの基本機能だからです。

## スクリーンショット

### デスクトップ（Windows）

> 表示内容は [**UHD MEDIA**](https://www.uhdnow.com) によるものです。

<table>
  <tr>
    <td colspan="2"><img src="images/screenshots/pc-player.jpg" width="100%" alt="プレーヤー"><br><sub><b>プレーヤー</b> —— 弾幕・二言語字幕・画質強化はすべてこの層にあります</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="images/screenshots/pc-home.jpg" width="100%" alt="ホーム"><br><sub><b>ホーム</b></sub></td>
    <td width="50%"><img src="images/screenshots/pc-library.jpg" width="100%" alt="ライブラリ"><br><sub><b>ライブラリ</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-series-detail.jpg" width="100%" alt="シリーズ詳細"><br><sub><b>シリーズ詳細</b></sub></td>
    <td><img src="images/screenshots/pc-movie-detail.jpg" width="100%" alt="映画詳細"><br><sub><b>映画詳細</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-episode-detail.jpg" width="100%" alt="エピソード詳細"><br><sub><b>エピソード詳細</b></sub></td>
    <td><img src="images/screenshots/pc-add-server.jpg" width="100%" alt="サーバー追加"><br><sub><b>サーバー追加</b> —— 初回起動時のログイン画面</sub></td>
  </tr>
</table>

### タブレット（Android）

> 表示内容は [**稳健115**](https://shop.wenjian.de) によるものです。

<table>
  <tr>
    <td width="33%"><img src="images/screenshots/tablet-home.jpg" width="100%" alt="ホーム"><br><sub><b>ホーム</b></sub></td>
    <td width="33%"><img src="images/screenshots/tablet-series-detail.jpg" width="100%" alt="シリーズ詳細"><br><sub><b>シリーズ詳細</b></sub></td>
    <td width="33%"><img src="images/screenshots/tablet-episode-detail.jpg" width="100%" alt="エピソード詳細"><br><sub><b>エピソード詳細</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/tablet-player.jpg" width="100%" alt="プレーヤー"><br><sub><b>プレーヤー</b></sub></td>
    <td><img src="images/screenshots/tablet-rankings.jpg" width="100%" alt="ランキング"><br><sub><b>ランキング</b></sub></td>
    <td><img src="images/screenshots/tablet-calendar.jpg" width="100%" alt="放送カレンダー"><br><sub><b>放送カレンダー</b></sub></td>
  </tr>
</table>

### スマートフォン（Android）

> 表示内容は [**ME MEDIA**](https://shop.mebimmer.de) によるものです。

<table>
  <tr>
    <td colspan="3"><img src="images/screenshots/phone-player.jpg" width="100%" alt="プレーヤー"><br><sub><b>プレーヤー</b> —— 横画面 OSD。右のパネルは画面比率 / バージョンと回線 / 音声トラック / 弾幕 / 字幕スタイル</sub></td>
  </tr>
  <tr>
    <td width="33%"><img src="images/screenshots/phone-home.jpg" width="100%" alt="ホーム"><br><sub><b>ホーム</b></sub></td>
    <td width="33%"><img src="images/screenshots/phone-aggregate.jpg" width="100%" alt="集約ビュー"><br><sub><b>集約ビュー</b> —— サーバーをまたぐお気に入り / ダウンロード / ランキング / カレンダー</sub></td>
    <td width="33%"><img src="images/screenshots/phone-rankings.jpg" width="100%" alt="ランキング"><br><sub><b>ランキング</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/phone-series-detail.jpg" width="100%" alt="シリーズ詳細"><br><sub><b>シリーズ詳細</b></sub></td>
    <td><img src="images/screenshots/phone-calendar.jpg" width="100%" alt="放送カレンダー"><br><sub><b>放送カレンダー</b></sub></td>
    <td><img src="images/screenshots/phone-settings.jpg" width="100%" alt="設定"><br><sub><b>設定</b></sub></td>
  </tr>
</table>

## 開発と技術

リポジトリ構成、ローカル開発とビルド、技術スタックは **[開発ドキュメント →](DEVELOPMENT.md)** を参照してください。

## 免責事項

### コンテンツ・リソースについて

- LinPlayer は**純粋なローカルプレーヤー / サードパーティクライアント**であり、それ自体は**いかなる映像リソースも提供・保存・ホスト・配布しません**。コンテンツソースも内蔵していません。
- アプリ内で表示・再生されるすべてのメディアは、**ユーザー自身が追加したサーバー（Emby など）またはユーザー自身が設定したネットワーク上の提供元**に由来し、その出所・著作権・適法性は**すべてユーザー自身の責任**です。
- **合法的に所有している、または利用を許諾されている**コンテンツのみを再生し、お住まいの国・地域の法令を遵守してください。利用者の不適切な使用に起因するいかなる紛争・損失・法的責任も**利用者自身が負う**ものとし、本プロジェクトおよび開発者とは一切関係ありません。
- 本プロジェクトは**無料・オープンソース・非営利**のソフトウェアであり、コンテンツの伝播からいかなる形でも利益を得ません。権利者の方がコンテンツを不適切とお考えの場合、問題は提供元にありますので、該当するリソース／サーバーの提供者へお問い合わせください。

### 匿名テレメトリとプライバシーについて

- **現行の Windows 版（Go コア + C#/Avalonia シェル）にはテレメトリもクラッシュ報告も一切含まれていません。**
  組み込まれていた Sentry は 2026-09-04 の Rust/Tauri スタック削除と同時に取り除かれました ——
  `git grep -i sentry` は `core/`・`apps/`・`bindings/` のいずれにもヒットしません。
- 私たちは**個人を特定できる情報を一切収集しません**：アカウント、パスワード、Cookie、トークン、
  サーバーアドレス、ライブラリの内容、視聴履歴、IP アドレスのいずれも収集せず、**画面録画も行動追跡も行いません**。
- 将来的に匿名のクラッシュ報告を再導入する場合は、収集範囲を本節に明記したうえで、
  **販売・共有したり、広告その他いかなる商業目的にも使用しません**。

## ライセンス

[LICENSE](../LICENSE)

## 謝辞

LinPlayer は以下のオープンソースプロジェクト、メディアサービス、コアの肩の上に立っています：

### 再生コア

- [mpv](https://github.com/mpv-player/mpv) / [libmpv](https://github.com/mpv-player/mpv) — 全フォーマット再生コア
- [shinchiro mpv-winbuild](https://github.com/shinchiro/mpv-winbuild-cmake) — Windows 向けフル機能 libmpv プリビルド
- [Anime4K](https://github.com/bloc97/Anime4K) — アニメ向けリアルタイム超解像 GLSL シェーダー
- [mpv_PlayKit](https://github.com/hooke007/mpv_PlayKit) — 画質プリセットシェーダーの移植とドキュメント
- [AMD FidelityFX (FSR / CAS)](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK) — アップスケールとシャープ化シェーダー
- [NVIDIA Image Scaling](https://github.com/NVIDIAGameWorks/NVIDIAImageScaling) — NVScaler / NVSharpen シェーダー

### UI とフレームワーク

- [Go](https://go.dev) — 全プラットフォーム共通のビジネスコア（`lpcore` 共有ライブラリとしてビルドし、C ABI 経由で各端から呼び出す）
- [.NET 10](https://dotnet.microsoft.com) / [Avalonia](https://avaloniaui.net) — Windows のシェルと UI
- [Kotlin](https://kotlinlang.org) / [Jetpack Compose](https://developer.android.com/compose) — Android のシェルと UI
- [AndroidX Media3 / ExoPlayer](https://github.com/androidx/media) — Android で切り替えられる第 2 の再生コア

### サービスとデータソース

- [Emby](https://emby.media/) — メディアサーバー
- [DanDanPlay](https://www.dandanplay.com/) — 弾幕とアニメランキングデータ
- [TMDB](https://www.themoviedb.org/) — 映画・ドラマランキングデータ
- [Bangumi (bgm.tv)](https://bgm.tv/) — アニメの視聴進捗とコレクション同期
- [anibt](https://anibt.net) — 国内向け Bangumi リバースプロキシ（API と画像の高速化）を LinPlayer に提供いただき、視聴同期がそのまま使える状態に。次世代の BT／マグネット検索サイトでもあり、リソース豊富で快適、おすすめです
- [Trakt](https://trakt.tv/) — 映画・ドラマの視聴履歴同期（Scrobble）

### Emby サーバー

UI デモと長期的なサポートを提供いただいた以下の Emby サーバーに感謝します：

- [UHD MEDIA](https://www.uhdnow.com) — デスクトップのスクリーンショット提供
- [稳健115](https://shop.wenjian.de) — タブレットのスクリーンショット提供
- [ME MEDIA](https://shop.mebimmer.de) — スマートフォンのスクリーンショット提供

### ネットワークとプロキシ

- [Cloudflare](https://www.cloudflare.com/) — 最速 IP ローカルリバースプロキシが依拠するエッジネットワーク

### スクリプトとツール

- [QuickJS](https://bellard.org/quickjs/) — プラグインスクリプトエンジン

> TMDB と DanDanPlay のコンテンツの著作権はそれぞれの権利者に帰属します。本プロジェクトは集約・表示を行うのみで、著作権保護されたメディアの保存や配布は行いません。

## Star History

<!-- 自建实时图(oauth-proxy/functions/star/history.svg.js)。
     不用 star-history.com:它没命中缓存就现场去 GitHub 拉,超过自己 10 秒上限就回 500，
     README 里那张图「时不时看不了」就是这么来的（实测连 facebook/react 都 500）。 -->
<a href="https://github.com/zzzwannasleep/LinPlayer/stargazers">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://291277.xyz/star/history.svg?theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://291277.xyz/star/history.svg" />
   <img alt="Star History Chart" src="https://291277.xyz/star/history.svg" />
 </picture>
</a>

## プロジェクトの活動

![Alt](https://repobeats.axiom.co/api/embed/4858243f2148dfeaa4e82f119fa918f3ec581a11.svg "Repobeats analytics image")

## スポンサー

[Afdian（爱发电）](https://afdian.com/a/zzzwannasleep) で LinPlayer を支援してくださっている皆様に感謝します（リストはリアルタイム更新）：

<p align="center">
  <a href="https://afdian.com/a/zzzwannasleep"><img src="https://291277.xyz/afdian/sponsors.svg" alt="Afdian スポンサー"></a>
</p>

## チャンネル

Telegram チャンネル [**@MikudesuChannels**](https://t.me/MikudesuChannels) —— リリース、更新予告、ディスカッション。
