# Desktop UI 鏋舵瀯涓庢帴鍏ヨ鏄?
> 閫傜敤浜?`lib/desktop_ui/` 鐨勬闈㈢ UI 涓撻」閲嶆瀯瀹炵幇銆? 
> 鏈枃妗ｅ彧瑕嗙洊 UI/Desktop 灞傦紝涓嶆秹鍙?Core/Adapter/Playback 鐨勯噸鏋勩€?
## 1. 閲嶆瀯鐩爣

- 浠呴噸鏋勬闈㈢ UI 灞傘€?- 淇濇寔涓庣幇鏈?`AppState + ServerAdapter` 鏁版嵁鎺ュ彛鍏煎銆?- 涓嶆敼鍙樼Щ鍔ㄧ椤甸潰涓庤矾鐢辫涓恒€?- 椋庢牸鎺ヨ繎 Emby Desktop锛氫綆瀵嗗害銆佸ぇ闂磋窛銆侀潰鏉垮垎灞傘€丠ero 瑙嗚銆?- 缁勪欢妯″潡鍖栵紝閬垮厤宸ㄥ瀷椤甸潰锛屼究浜庨暱鏈熺淮鎶ゃ€?
## 2. 鏋舵瀯杈圭晫

蹇呴』淇濇寔锛?
- 涓嶄慨鏀?`packages/lin_player_core`
- 涓嶄慨鏀?`packages/lin_player_server_adapters`
- 涓嶄慨鏀?`packages/lin_player_player`
- 涓嶆柊澧炲亣鏈嶅姟鍣ㄥ疄鐜般€佷笉鏀?API 鍗忚

妗岄潰灞傚厑璁革細

- 鏂板妗岄潰椤甸潰銆佺粍浠躲€乂iewModel
- 鍦ㄦ闈㈠３鍐呴儴鍋氬鑸紪鎺掍笌涓婚鎵╁睍
- 閫氳繃 `resolveServerAccess(...)` 璁块棶鐜版湁閫傞厤鍣ㄨ兘鍔?
## 3. 鐩綍涓庤亴璐?
```text
lib/desktop_ui/
  desktop_shell.dart                 # 妗岄潰鍏ュ彛澹?+ 鐘舵€佸垎娴?+ 妗岄潰宸ヤ綔鍖?  pages/
    desktop_navigation_layout.dart   # Row: Sidebar + TopBar + Content
    desktop_library_page.dart        # 妗岄潰搴撻椤碉紙缁х画瑙傜湅/鎺ㄨ崘/鍚勫獟浣撳簱锛?    desktop_search_page.dart         # 妗岄潰鎼滅储椤?    desktop_detail_page.dart         # 妗岄潰璇︽儏椤碉紙Hero + 鍖哄潡鍒楄〃锛?    desktop_server_page.dart         # 鐜版湁鏃犳湇鍔″櫒鎬侀〉锛堜繚鐣欙級
    desktop_webdav_home_page.dart    # 鐜版湁 WebDAV 妗岄潰椤碉紙淇濈暀锛?  view_models/
    desktop_detail_view_model.dart   # 璇︽儏椤垫暟鎹閰嶄笌鐘舵€佺鐞?  widgets/
    desktop_sidebar.dart
    desktop_sidebar_item.dart
    desktop_top_bar.dart
    desktop_media_card.dart
    desktop_horizontal_section.dart
    desktop_hero_section.dart
    desktop_action_button_group.dart
    hover_effect_wrapper.dart
    focus_traversal_manager.dart
    desktop_shortcut_wrapper.dart
    window_padding_container.dart
    desktop_media_meta.dart
  theme/
    desktop_theme_extension.dart
```

## 4. 鍏ュ彛鍒嗘祦涓庤矾鐢辨帴鍏?
鍏ュ彛浠嶆槸 `main.dart -> DesktopShell(appState)`銆?
`DesktopShell` 鍒嗘祦閫昏緫锛?
1. 鏃犳椿璺冩湇鍔℃垨 profile 涓嶅畬鏁达細杩涘叆 `DesktopServerPage`
2. `WebDAV`锛氳繘鍏?`DesktopWebDavHomePage`
3. Emby/Jellyfin/Plex锛氳繘鍏ユ闈㈠伐浣滃尯 `_DesktopWorkspace`

鍥犳鏃犻渶璋冩暣绉诲姩绔矾鐢便€傛闈㈤噸鏋勫绉诲姩绔槸闅旂鐨勩€?
## 5. 妗岄潰甯冨眬瑙勮寖

涓诲竷灞€鍥哄畾涓猴細

```text
Row
 鈹溾攢鈹€ DesktopSidebar (fixed width)
 鈹斺攢鈹€ Expanded
       鈹溾攢鈹€ DesktopTopBar
       鈹斺攢鈹€ ContentArea
```

瀹炵幇鏂囦欢锛歚pages/desktop_navigation_layout.dart`銆?
鏀寔鑳藉姏锛?
- 瀹藉睆涓庣獥鍙ｆ媺浼革紙鎸夊彲鐢ㄥ搴﹁嚜閫傚簲锛?- Hover 鍔ㄧ敾锛坄HoverEffectWrapper`锛?- 閿洏鐒︾偣瀵艰埅锛坄FocusTraversalManager`锛?
## 6. 璇︽儏椤佃璁★紙DesktopDetailPage锛?
璇︽儏椤电敱 `DesktopDetailPage + DesktopDetailViewModel` 缁勬垚銆?
瑙嗚缁撴瀯锛?
- 娣辩伆钃濊儗鏅笌鍒嗗眰闈㈡澘
- Hero 鑳屾櫙澶у浘 + 娓愬彉閬僵
- 宸﹀皝闈€佸彸鏍囬涓庡厓淇℃伅
- 鎾斁鎸夐挳 + 鏀惰棌鎸夐挳
- 妯悜鍓ч泦鍒楄〃銆佹帹鑽愬垪琛ㄣ€佹紨鍛樺垪琛?- 鍗＄墖 hover 鏀惧ぇ鏁堟灉

鏁版嵁鏉ユ簮锛?
- 杈撳叆涓?`MediaItem`锛坰eed锛?- `DesktopDetailViewModel` 璋冪敤鏃㈡湁 adapter锛?  - `fetchItemDetail`
  - `fetchSeasons`
  - `fetchEpisodes`
  - `fetchSimilar`
- 椤甸潰鍙秷璐?ViewModel 鐘舵€侊紝涓嶇洿鎺ヨ闂?Repository

## 7. 涓婚绛栫暐

- 鏂板 `DesktopThemeExtension` 鎻愪緵妗岄潰 token銆?- 鍦?`DesktopShell` 鍐呮寜闇€鎸傝浇 extension锛坄Theme.copyWith(extensions: ...)`锛夈€?- 涓嶄慨鏀瑰叏灞€ `AppTheme.light/dark` 瀹氫箟锛屼笉褰卞搷绉诲姩绔富棰樸€?
## 8. 鍙墿灞曠偣

- `DesktopShortcutWrapper`
  - 宸查鐣?`shortcuts/actions/enabled`锛屽彲鍚庣画鎺ュ叏灞€蹇嵎閿€?- `WindowPaddingContainer`
  - 宸查鐣欑獥鍙ｆ嫋鎷藉尯浜嬩欢锛屽彲鍚庣画鎺ユ棤杈规绐楀彛鎻掍欢锛堝 `window_manager`锛夈€?- `DesktopDetailViewModel`
  - 鍙户缁墿灞曡瘎鍒嗐€佹爣绛俱€佹洿澶氬獟浣撴簮淇℃伅锛岃€屼笉褰卞搷椤甸潰缁撴瀯銆?
## 9. 缁存姢绾﹀畾

- 椤甸潰灏介噺鍙仛甯冨眬涓庝簨浠跺垎鍙戯紱鐘舵€佺鐞嗕笅娌夎嚦 `view_models/`銆?- 妯悜濯掍綋灞曠ず缁熶竴鐢?`DesktopMediaCard`銆?- 鏂板尯鍧椾紭鍏堝鐢?`DesktopHorizontalSection`銆?- 涓嶅湪妗岄潰椤典腑纭紪鐮佹湇鍔″櫒绫诲瀷鍒嗘敮閫昏緫銆?- 涓嶅湪妗岄潰灞傚紩鍏ユ柊鐨?API 璋冪敤鍗忚銆?
## 10. 宸插疄鐜版枃浠舵竻鍗曪紙鏈閲嶆瀯鏂板/鏇存柊锛?
鏂板锛?
- `lib/desktop_ui/pages/desktop_detail_page.dart`
- `lib/desktop_ui/pages/desktop_library_page.dart`
- `lib/desktop_ui/pages/desktop_navigation_layout.dart`
- `lib/desktop_ui/pages/desktop_search_page.dart`
- `lib/desktop_ui/theme/desktop_theme_extension.dart`
- `lib/desktop_ui/view_models/desktop_detail_view_model.dart`
- `lib/desktop_ui/widgets/desktop_action_button_group.dart`
- `lib/desktop_ui/widgets/desktop_hero_section.dart`
- `lib/desktop_ui/widgets/desktop_horizontal_section.dart`
- `lib/desktop_ui/widgets/desktop_media_card.dart`
- `lib/desktop_ui/widgets/desktop_media_meta.dart`
- `lib/desktop_ui/widgets/desktop_shortcut_wrapper.dart`
- `lib/desktop_ui/widgets/desktop_sidebar.dart`
- `lib/desktop_ui/widgets/desktop_sidebar_item.dart`
- `lib/desktop_ui/widgets/desktop_top_bar.dart`
- `lib/desktop_ui/widgets/focus_traversal_manager.dart`
- `lib/desktop_ui/widgets/hover_effect_wrapper.dart`
- `lib/desktop_ui/widgets/window_padding_container.dart`

鏇存柊锛?
- `lib/desktop_ui/desktop_shell.dart`
- `lib/desktop_ui/README.md`

## 11. 鎺ュ彛鎺ュ叆琛紙鍗囩骇缁存姢锛?
| 妯″潡 | 褰撳墠鎺ュ叆鐨勭幇鏈夋帴鍙?| 浠ｇ爜浣嶇疆 | 鍗囩骇鏃朵紭鍏堝叧娉?| 鏄惁闇€瑕佹柊澧炴帴鍙?|
| --- | --- | --- | --- | --- |
| `DesktopShell` | `AppState.activeServer` / `hasActiveServerProfile` / `hasActiveServer` / `activeServerId` | `lib/desktop_ui/desktop_shell.dart` | 鏈嶅姟鍣ㄧ姸鎬佸瓧娈靛彉鏇存椂锛屼紭鍏堣皟鏁存闈㈠叆鍙ｅ垎娴侀€昏緫 | 鍚?|
| `DesktopLibraryPage` | `AppState.refreshLibraries` / `loadHome` / `loadContinueWatching` / `loadRandomRecommendations` / `getHome` | `lib/desktop_ui/pages/desktop_library_page.dart` | Home 缂撳瓨缁撴瀯鎴栧簱鍒楄〃绛栫暐鍙樻洿鏃讹紝鏍稿鍒嗛〉涓庡尯鍧楁覆鏌?| 鍚?|
| `DesktopSearchPage` | `resolveServerAccess(...)` + `MediaServerAdapter.fetchItems(...)` | `lib/desktop_ui/pages/desktop_search_page.dart` | 鎼滅储鍙傛暟锛坄includeItemTypes`銆佹帓搴忋€乴imit锛変笌鏈嶅姟绔吋瀹规€?| 鍚?|
| `DesktopDetailViewModel` | `resolveServerAccess(...)` + `fetchItemDetail` / `fetchSimilar` / `fetchSeasons` / `fetchEpisodes` | `lib/desktop_ui/view_models/desktop_detail_view_model.dart` | 璇︽儏椤垫暟鎹ā鍨嬪瓧娈靛彉鍖栥€佸闆嗘媺鍙栬鍒欍€佺浉浼兼帹鑽愯繑鍥炵粨鏋?| 鍚?|
| `DesktopDetailPage` | 仅消费 `DesktopDetailViewModel`；播放入口通过 `onPlayPressed` 回调 | `lib/desktop_ui/pages/desktop_detail_page.dart` | 已在壳层接入播放流程；若需定制仅改壳层回调注入 | 否（已接入） |
| `DesktopMediaCard` / `DesktopHeroSection` | `MediaServerAdapter.imageUrl(...)` / `personImageUrl(...)` | `lib/desktop_ui/widgets/desktop_media_card.dart` / `lib/desktop_ui/widgets/desktop_hero_section.dart` | 鍥剧墖绫诲瀷鍙傛暟锛圥rimary/Backdrop锛夋垨 URL 瑙勫垯鍙樺寲 | 鍚?|
| `FocusTraversalManager` | Flutter 鍘熺敓鐒︾偣绯荤粺锛歚FocusTraversalGroup` / `Shortcuts` / `Actions` | `lib/desktop_ui/widgets/focus_traversal_manager.dart` | 閿洏浜や簰绛栫暐鍙樻洿鏃讹紝缁熶竴鍦ㄦ澶勬墿灞曪紝涓嶅垎鏁ｅ埌椤甸潰 | 鍚?|
| `DesktopShortcutWrapper` | 蹇嵎閿鐣欙細`shortcuts` / `actions` / `enabled` | `lib/desktop_ui/widgets/desktop_shortcut_wrapper.dart` | 鍚庣画鍚敤鍏ㄥ眬蹇嵎閿椂锛屽湪澹冲眰缁熶竴娉ㄥ叆鏄犲皠 | 鍚︼紙宸查鐣欐帴鍙ｏ級 |
| `WindowPaddingContainer` | 鏃犺竟妗嗘嫋鎷藉尯棰勭暀锛歚onDragRegionPointerDown` / `dragRegion` | `lib/desktop_ui/widgets/window_padding_container.dart` | 鎺ュ叆绐楀彛鎻掍欢锛堝 `window_manager`锛夋椂锛屼粎缁戝畾璇ュ鍣ㄥ洖璋?| 鍚︼紙宸查鐣欐帴鍙ｏ級 |

### 鍗囩骇缁存姢 checklist

1. 鍏堢‘璁?`AppState` 涓?`MediaServerAdapter` 鏂规硶绛惧悕鏄惁鍙樺寲銆? 
2. 鑻ョ鍚嶅彉鍖栵紝鍏堟敼 `view_models/` 涓?`pages/desktop_*_page.dart` 鐨勮皟鐢ㄥ眰锛屼笉鏀?Core/Adapter銆? 
3. 若新增桌面能力，优先走组件预留口（`DesktopShortcutWrapper`、`WindowPaddingContainer`）；播放行为统一走壳层回调。
4. 鏈€鍚庢墽琛?`flutter analyze` + 妗岄潰绔墜鍔ㄥ洖褰掞紙Library/Search/Detail 涓夐〉锛夈€? 

## 12. 鎺ュ彛鍙嶅悜鏄犲皠琛紙鎸夋帴鍙ｇ淮搴︼級

> 鐢ㄤ簬鈥滄帴鍙ｅ崌绾р€濆満鏅細鍏堢湅鎺ュ彛锛屽啀鍙嶆煡鍙楀奖鍝嶉〉闈?缁勪欢銆?
| 鎺ュ彛锛堢幇鏈夛級 | 褰撳墠浣跨敤鏂癸紙Desktop UI锛?| 浠ｇ爜浣嶇疆 | 鍏稿瀷鍗囩骇瑙﹀彂鐐?| 寤鸿缁存姢鍔ㄤ綔 |
| --- | --- | --- | --- | --- |
| `AppState.activeServer` / `hasActiveServerProfile` / `hasActiveServer` / `activeServerId` | `DesktopShell` | `lib/desktop_ui/desktop_shell.dart` | 鏈嶅姟鍣ㄧ姸鎬佸瓧娈点€佽繘鍏ユ潯浠躲€乸rofile 缁撴瀯鍙樻洿 | 鍏堟敼妗岄潰鍏ュ彛鍒嗘祦锛屽啀鍥炲綊鏃犳湇鍔″櫒/WebDAV/EmbyLike 涓夋潯璺緞 |
| `AppState.refreshLibraries()` | `DesktopLibraryPage` | `lib/desktop_ui/pages/desktop_library_page.dart` | 搴撳埛鏂扮瓥鐣ャ€佸紓甯告ā鍨嬪彉鍖?| 淇濇寔鍒锋柊鍏ュ彛闆嗕腑鍦?Library 椤碉紝閿欒鏂囨缁熶竴浠庨〉闈㈠眰澶勭悊 |
| `AppState.loadHome(forceRefresh: ...)` | `DesktopLibraryPage` | `lib/desktop_ui/pages/desktop_library_page.dart` | 棣栭〉鍖哄潡缂撳瓨缁撴瀯鍙樻洿 | 鍏堥€傞厤 `loadHome` 杩斿洖琛屼负锛屽啀鏍稿鍚勫簱鍖哄潡绌烘€?鍔犺浇鎬?|
| `AppState.loadContinueWatching(...)` | `DesktopLibraryPage` | `lib/desktop_ui/pages/desktop_library_page.dart` | 缁х画瑙傜湅鍘婚噸瑙勫垯銆佽繑鍥炲瓧娈靛彉鍖?| 鏍稿鍗＄墖鍏冧俊鎭笌杩涘害鏉℃覆鏌擄紝涓嶅湪 UI 灞傚鍒跺幓閲嶉€昏緫 |
| `AppState.loadRandomRecommendations(...)` | `DesktopLibraryPage` | `lib/desktop_ui/pages/desktop_library_page.dart` | 鎺ㄨ崘绛栫暐銆乴imit 璋冩暣 | 浠呰皟鍙傛暟涓庡睍绀哄瘑搴︼紝涓嶆敼 Adapter/API 鍗忚 |
| `AppState.getHome('lib_{id}')` | `DesktopLibraryPage` | `lib/desktop_ui/pages/desktop_library_page.dart` | Home section key 瑙勫垯鍙樺寲 | 缁熶竴鏀?key 缁勮瑙勫垯锛岄伩鍏嶆暎钀界‖缂栫爜 |
| `resolveServerAccess(appState: ...)` | `DesktopLibraryPage` / `DesktopSearchPage` / `DesktopDetailViewModel` | `lib/desktop_ui/pages/desktop_library_page.dart` / `lib/desktop_ui/pages/desktop_search_page.dart` / `lib/desktop_ui/view_models/desktop_detail_view_model.dart` | 鏈嶅姟璁块棶涓婁笅鏂囧瓧娈靛彉鍖栵紙auth/baseUrl/token锛?| 鍏堟敼 `resolveServerAccess` 璋冪敤灞傦紝鍐嶅洖褰掓悳绱笌璇︽儏鎺ュ彛 |
| `MediaServerAdapter.fetchItems(...)` | `DesktopSearchPage` | `lib/desktop_ui/pages/desktop_search_page.dart` | 鎼滅储鍙傛暟銆佹帓搴忓瓧娈点€佸垎椤靛弬鏁板彉鍖?| 浠呭湪 Search 椤佃皟鏁存煡璇㈠弬鏁帮紱淇濈暀鈥滅簿纭尮閰嶄紭鍏堚€濋€昏緫 |
| `MediaServerAdapter.fetchItemDetail(...)` | `DesktopDetailViewModel` | `lib/desktop_ui/view_models/desktop_detail_view_model.dart` | 璇︽儏瀛楁鏂板/鍙樻洿 | 浼樺厛鍦?ViewModel 閫傞厤鏂板瓧娈碉紝涓嶇洿鎺ユ敼椤甸潰灞?|
| `MediaServerAdapter.fetchSeasons(...)` | `DesktopDetailViewModel` | `lib/desktop_ui/view_models/desktop_detail_view_model.dart` | 瀛ｅ垪琛ㄨ繑鍥炵粨鏋勫彉鍖?| 浠呮敼 ViewModel 瑁呴厤閫昏緫锛岄〉闈㈢户缁秷璐圭粺涓€鍒楄〃 |
| `MediaServerAdapter.fetchEpisodes(...)` | `DesktopDetailViewModel` | `lib/desktop_ui/view_models/desktop_detail_view_model.dart` | 鍒嗗鎷夊彇瑙勫垯銆佸垎椤电瓥鐣ュ彉鍖?| 鍏堜繚鎸佲€滈瀛ｉ粯璁ゅ姞杞解€濊涓猴紝鍐嶆寜闇€姹傛墿灞曞閫夋嫨 |
| `MediaServerAdapter.fetchSimilar(...)` | `DesktopDetailViewModel` | `lib/desktop_ui/view_models/desktop_detail_view_model.dart` | 鎺ㄨ崘鍒楄〃瀛楁/涓婇檺鍙樺寲 | 淇濇寔璇︽儏椤靛幓閲嶈鍒欙紙杩囨护褰撳墠 item锛?|
| `MediaServerAdapter.imageUrl(...)` | `DesktopMediaCard` / `DesktopHeroSection` / `DesktopDetailViewModel` | `lib/desktop_ui/widgets/desktop_media_card.dart` / `lib/desktop_ui/widgets/desktop_hero_section.dart` / `lib/desktop_ui/view_models/desktop_detail_view_model.dart` | 鍥剧墖 URL 瑙勫垯銆乮mageType 绛栫暐鍙樺寲 | 缁熶竴鍦ㄧ粍浠?ViewModel 涓皟鏁达紝閬垮厤椤甸潰灞傜洿鎺ユ嫾 URL |
| `MediaServerAdapter.personImageUrl(...)` | `DesktopDetailViewModel`锛堟紨鍛樺ご鍍忥級 | `lib/desktop_ui/view_models/desktop_detail_view_model.dart` | 浜虹墿鍥炬帴鍙ｅ弬鏁板彉鍖?| 鍦?ViewModel 淇濇寔绌哄€间繚鎶わ紝椤甸潰涓嶆劅鐭ユ湇鍔″樊寮?|

### 12.1 棰勭暀鎺ュ彛锛堥潪鐜版湁涓氬姟鎺ュ彛锛?
| 棰勭暀鐐?| 浠ｇ爜浣嶇疆 | 鍚敤鏃舵満 | 鍚敤鏂瑰紡 |
| --- | --- | --- | --- |
| `DesktopShortcutWrapper.shortcuts/actions/enabled` | `lib/desktop_ui/widgets/desktop_shortcut_wrapper.dart` | 闇€瑕佸叏灞€蹇嵎閿紙鎾斁鎺у埗銆佸鑸€佹悳绱級 | 鍦?`DesktopShell` 椤跺眰娉ㄥ叆蹇嵎閿槧灏勶紝涓嶅湪鍚勯〉闈㈤噸澶嶇粦瀹?|
| `WindowPaddingContainer.onDragRegionPointerDown/dragRegion` | `lib/desktop_ui/widgets/window_padding_container.dart` | 闇€瑕佹帴鍏ユ棤杈规绐楀彛鎷栨嫿 | 鍦ㄥ鍣ㄥ眰缁戝畾绐楀彛鎻掍欢鍥炶皟锛堜緥濡?`window_manager`锛夛紝涓嶆敼涓氬姟椤甸潰 |
| `DesktopDetailPage.onPlayPressed` | `lib/desktop_ui/pages/desktop_detail_page.dart` + `lib/desktop_ui/desktop_shell.dart` | 已接入详情页播放动作 | 壳层统一注入播放回调，页面保持“只发事件不做播放逻辑” |

### 12.2 鎺ュ彛鍗囩骇寤鸿娴佺▼锛堝弽鍚戞槧灏勭敤娉曪級

1. 鍦ㄦ湰琛ㄥ畾浣嶁€滆鍗囩骇鎺ュ彛鈥濄€?2. 鎸夆€滃綋鍓嶄娇鐢ㄦ柟鈥濋€愪竴淇敼璋冪敤灞傦紙浼樺厛 `view_models/`锛屽叾娆?`pages/`锛夈€?3. 浠呭湪 Desktop UI 灞傞€傞厤锛岄伩鍏嶆妸 UI 闇€姹傚弽鍚戜镜鍏?Core/Adapter/Playback銆?4. 鍥炲綊楠岃瘉椤哄簭锛歚DesktopShell` 鍒嗘祦 -> `Library` -> `Search` -> `Detail`銆?5. 鏈€鍚庢墽琛?`flutter analyze` 骞跺仛妗岄潰绔墜鍔ㄥ啋鐑熴€?



