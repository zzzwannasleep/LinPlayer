# LinPlayer

<p align="center">
  <a href="https://github.com/zzzwannasleep/LinPlayer/stargazers"><img src="https://img.shields.io/github/stars/zzzwannasleep/LinPlayer?style=flat&logo=github&label=Stars" alt="Stars"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/github/v/release/zzzwannasleep/LinPlayer?label=stable&color=blue" alt="Stable"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/github/v/release/zzzwannasleep/LinPlayer?include_prereleases&label=pre-release&color=orange" alt="Pre-release"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/github/downloads/zzzwannasleep/LinPlayer/total?label=downloads&color=green&logo=github" alt="Downloads"></a>
  <a href="https://linplayer.sentry.io"><img src="https://img.shields.io/endpoint?url=https://linplayeroaproxy.pages.dev/sentry/users" alt="Active Users"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/blob/main/LICENSE"><img src="https://img.shields.io/github/license/zzzwannasleep/LinPlayer" alt="License"></a>
  <img src="https://img.shields.io/badge/Rust-1.80+-000000?logo=rust" alt="Rust">
  <img src="https://img.shields.io/badge/React-19-61DAFB?logo=react&logoColor=white" alt="React">
  <img src="https://img.shields.io/badge/Tauri-2-24C8DB?logo=tauri&logoColor=white" alt="Tauri">
  <a href="https://github.com/zzzwannasleep/LinPlayer/actions"><img src="https://img.shields.io/github/actions/workflow/status/zzzwannasleep/LinPlayer/build.yml?branch=main&label=build&logo=github" alt="Build"></a>
  <a href="https://t.me/MikudesuChannels"><img src="https://img.shields.io/badge/Telegram-MikudesuChannels-26A5E4?logo=telegram&logoColor=white" alt="Telegram"></a>
</p>

<p align="center">
  <a href="../README.md">简体中文</a> ·
  <a href="README.en.md">English</a> ·
  <b>日本語</b>
</p>

**LinPlayer** は **Windows / Linux / Android / Android TV** を対象とした Emby サードパーティクライアントです。

> ### 🚧 再構築中（2026-07）
>
> 本プロジェクトは Flutter から **Rust コア + React/TypeScript UI + Tauri シェル** へ全面移行しました。
>
> - **デスクトップ（Windows / Linux）** —— 利用可能、通常どおり配布中。
> - **Android / Android TV** —— UI を再構築中。現時点で新しいビルドはありません。
> - **Apple 系（iOS / macOS / tvOS）** —— サポート終了、リポジトリから削除済みです。
>
> Flutter 時代の完全なコードはタグ [`flutter-final`](https://github.com/zzzwannasleep/LinPlayer/tree/flutter-final) に保存されています。

ビジネスロジック（データソース / ネットワーク / 再生制御 / 同期 / ダウンロード）は**全プラットフォーム共通の単一 Rust クレート**にまとまっており、各プラットフォームは自分の UI だけを書きます。したがって下表の 🔨 は「未着手」ではなく、**コアは完成済みで UI の配線待ち**という意味です。

## 機能

| 機能 | 内容 | デスクトップ | Android / TV |
|:--|:--|:--:|:--:|
| **MPV 再生コア** | 全フォーマット；HDR / Dolby Vision（gpu-next + ソフトデコードへ自動切替）；PGS/SUP グラフィック字幕；Anime4K 超解像と画質プリセット | ✅ | 🔨 |
| **弾幕（コメント）** | DanDanPlay など複数バックエンド、話数の自動マッチング、ソース並列取得、縁取りと表示領域の調整 | ✅ | 🔨 |
| **字幕** | Emby 字幕ストリームの自動読み込み；トラック切替、遅延、フォント／サイズ／位置；libass のフル特効 | ✅ | 🔨 |
| **マルチソース閲覧** | Emby 以外に OpenList、Quark（Cookie / QR）、Ani-rss、飛牛 | ✅ | 🔨 |
| **再生同期** | Emby への進捗レポート、サーバー跨ぎのレジューム | ✅ | 🔨 |
| **Trakt / Bangumi** | 視聴記録の Scrobble とアニメ視聴進捗の同期 | ✅ | 🔨 |
| **放送カレンダー** | Trakt / Bangumi の放送スケジュール | ✅ | 🔨 |
| **ランキング** | DanDanPlay アニメランキング + TMDB 映画・ドラマランキング（切替可） | ✅ | 🔨 |
| **ダウンロード** | 自作のマルチスレッド（レンジ分割）ダウンロードエンジン | ✅ | 🔨 |
| **マルチスレッド読み込み** | ローカルプリフェッチプロキシが並列レンジ取得で先読みしプレーヤーへ供給 | ✅ | 🔨 |
| **プロキシ** | カスタムプロキシ + Cloudflare 最速 IP ローカルリバースプロキシ | ✅ | 🔨 |
| **プラグインシステム** | QuickJS エンジン、プラグインごとに隔離——クラッシュやタイムアウトはホストに波及しません | ✅ | 🔨 |
| **サーバー一括追加** | 複数行の設定を貼り付けて一度に解析・取り込み | ✅ | 🔨 |
| **設定の移行** | QR でデバイス間にサーバー設定を直接転送（認証情報を含み、完全オフライン） | ✅ | 🔨 |
| **アプリ内アップデート** | デュアルチャンネル（stable / pre）の上書き更新 | ✅ | 🔨 |

<sub>✅ 配線済みで利用可能 · 🔨 コアは完成済み、UI 再構築中</sub>

## スクリーンショット

### デスクトップ

> 表示コンテンツは [**UHD MEDIA**](https://www.uhdnow.com) のご提供です。

<table>
  <tr>
    <td colspan="2"><img src="images/screenshots/pc-player.png" width="100%" alt="プレーヤー"><br><sub><b>プレーヤー</b></sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="images/screenshots/pc-home.png" width="100%" alt="ホーム"><br><sub><b>ホーム</b></sub></td>
    <td width="50%"><img src="images/screenshots/pc-library.png" width="100%" alt="ライブラリ"><br><sub><b>ライブラリ</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-series-detail.png" width="100%" alt="シリーズ詳細"><br><sub><b>シリーズ詳細</b></sub></td>
    <td><img src="images/screenshots/pc-episode-detail.png" width="100%" alt="エピソード詳細"><br><sub><b>エピソード詳細</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-rankings.png" width="100%" alt="ランキング"><br><sub><b>ランキング</b></sub></td>
    <td><img src="images/screenshots/pc-favorites.png" width="100%" alt="お気に入り"><br><sub><b>お気に入り</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-calendar-week.png" width="100%" alt="カレンダー 今週"><br><sub><b>カレンダー · 今週</b></sub></td>
    <td><img src="images/screenshots/pc-calendar-day.png" width="100%" alt="カレンダー 今日"><br><sub><b>カレンダー · 今日</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-plugins.png" width="100%" alt="プラグイン"><br><sub><b>プラグイン</b></sub></td>
    <td><img src="images/screenshots/pc-servers.png" width="100%" alt="サーバー"><br><sub><b>サーバー</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-add-server.png" width="100%" alt="サーバー追加"><br><sub><b>サーバー追加</b></sub></td>
    <td><img src="images/screenshots/pc-settings.png" width="100%" alt="設定"><br><sub><b>設定</b></sub></td>
  </tr>
  <tr>
    <td colspan="2" width="50%"><img src="images/screenshots/pc-login.png" width="100%" alt="初回ログイン"><br><sub><b>初回ログイン</b></sub></td>
  </tr>
</table>

### モバイル

<details>
<summary><b>Flutter 版のスクリーンショット</b> —— 新しい Android UI は再構築中で、完了後に差し替えます</summary>

<br>

> 表示コンテンツは [**BAVA サーバー**](https://shop.mebimmer.de) のご提供です。

<table>
  <tr>
    <td colspan="3"><img src="images/screenshots/mobile-player.jpg" width="100%" alt="プレーヤー"><br><sub><b>プレーヤー</b></sub></td>
  </tr>
  <tr>
    <td width="33%"><img src="images/screenshots/mobile-home.jpg" width="100%" alt="ホーム"><br><sub><b>ホーム</b></sub></td>
    <td width="33%"><img src="images/screenshots/mobile-series-detail.jpg" width="100%" alt="シリーズ詳細"><br><sub><b>シリーズ詳細</b></sub></td>
    <td width="33%"><img src="images/screenshots/mobile-episode-detail.jpg" width="100%" alt="エピソード詳細"><br><sub><b>エピソード詳細</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/mobile-movie-detail.jpg" width="100%" alt="映画詳細"><br><sub><b>映画詳細</b></sub></td>
    <td><img src="images/screenshots/mobile-rankings.jpg" width="100%" alt="ランキング"><br><sub><b>ランキング</b></sub></td>
    <td><img src="images/screenshots/mobile-settings.jpg" width="100%" alt="設定"><br><sub><b>設定</b></sub></td>
  </tr>
</table>

</details>

## 開発と技術

リポジトリ構成、ローカル開発とビルド、技術スタックは **[開発ドキュメント →](DEVELOPMENT.md)** を参照してください。

## 免責事項

### コンテンツ・リソースについて

- LinPlayer は**純粋なローカルプレーヤー / サードパーティクライアント**であり、それ自体は**いかなる映像リソースも提供・保存・ホスト・配布しません**。コンテンツソースも内蔵していません。
- アプリ内で表示・再生されるすべてのメディアは、**ユーザー自身が追加したサーバー（Emby など）またはユーザー自身が設定したネットワーク上の提供元**に由来し、その出所・著作権・適法性は**すべてユーザー自身の責任**です。
- **合法的に所有している、または利用を許諾されている**コンテンツのみを再生し、お住まいの国・地域の法令を遵守してください。利用者の不適切な使用に起因するいかなる紛争・損失・法的責任も**利用者自身が負う**ものとし、本プロジェクトおよび開発者とは一切関係ありません。
- 本プロジェクトは**無料・オープンソース・非営利**のソフトウェアであり、コンテンツの伝播からいかなる形でも利益を得ません。権利者の方がコンテンツを不適切とお考えの場合、問題は提供元にありますので、該当するリソース／サーバーの提供者へお問い合わせください。

### 匿名テレメトリとプライバシーについて

- 安定性を継続的に改善するため、LinPlayer は [Sentry](https://sentry.io) を用いた**クラッシュ／エラー報告**と**匿名のアクティブ利用統計**（クラッシュ状況とおおよその利用規模の把握のみに使用）を組み込んでいます。
- 私たちは**個人を特定できる情報を一切収集しません**。アカウント、パスワード、Cookie、トークン、サーバーアドレス、ライブラリの内容、視聴履歴、IP アドレスは収集せず、**画面録画も行動追跡も行いません**。
- 報告されるデータは、**匿名のクラッシュスタックトレース、アプリのバージョン、プラットフォーム／OS の種類**などの技術情報のみで、ランダムな匿名識別子で端末を区別します（人数を数えるだけで、身元は特定しません）。
- 私たちはこのデータを**販売・共有したり、広告その他いかなる商業目的にも使用しません**。設定は公開されており検証可能です：[`ui/desktop/telemetry.ts`](../ui/desktop/telemetry.ts) と [`apps/desktop/src/telemetry.rs`](../apps/desktop/src/telemetry.rs)。

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

- [Rust](https://www.rust-lang.org/) / [Tokio](https://tokio.rs) / [reqwest](https://github.com/seanmonstar/reqwest) — 全プラットフォーム共通のビジネスコア
- [Tauri 2](https://tauri.app) — デスクトップシェル（ウィンドウ / IPC / パッケージング）
- [React 19](https://react.dev) / [TypeScript](https://www.typescriptlang.org) / [Vite](https://vite.dev) — 各プラットフォームの UI

### サービスとデータソース

- [Emby](https://emby.media/) — メディアサーバー
- [DanDanPlay](https://www.dandanplay.com/) — 弾幕とアニメランキングデータ
- [TMDB](https://www.themoviedb.org/) — 映画・ドラマランキングデータ
- [Bangumi (bgm.tv)](https://bgm.tv/) — アニメの視聴進捗とコレクション同期
- [anibt](https://anibt.net) — 国内向け Bangumi リバースプロキシ（API と画像の高速化）を LinPlayer に提供いただき、視聴同期がそのまま使える状態に。次世代の BT／マグネット検索サイトでもあり、リソース豊富で快適、おすすめです
- [Trakt](https://trakt.tv/) — 映画・ドラマの視聴履歴同期（Scrobble）
- [OpenList](https://github.com/OpenListTeam/OpenList) — ネットワークディスク集約ソース
- [Ani-rss](https://github.com/wushuo894/ani-rss) — アニメ RSS 購読と自動ダウンロード

### Emby サーバー

UI デモと長期的なサポートを提供いただいた以下の Emby サーバーに感謝します：

- [UHD MEDIA](https://www.uhdnow.com) — デスクトップのスクリーンショット提供
- [BAVA サーバー](https://shop.mebimmer.de) — モバイルのスクリーンショット提供

### ネットワークとプロキシ

- [rustls](https://github.com/rustls/rustls) — TLS 実装（自己署名証明書はホスト許可リスト単位で許容）
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
