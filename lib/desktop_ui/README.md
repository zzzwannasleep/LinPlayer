# Desktop UI

This folder contains the desktop-only UI entry layer for Windows and macOS.

Current state:
- `desktop_shell.dart` is the single shared entry for Windows and macOS.
- `pages/desktop_root_page.dart` chooses root page by server state.
- `pages/desktop_home_page.dart` now implements a desktop-first cinematic UI:
  top floating pill nav, main player surface, and right recommendation panel.
- `widgets/desktop_cinematic_shell.dart` provides shared desktop chrome
  (dark backdrop + glass top pill + rounded content surface).
- `pages/desktop_server_page.dart` and `pages/desktop_webdav_home_page.dart`
  now both use the same cinematic shell to match playback page style.
- Shared shell & playback visuals support both dark and light themes.
- Desktop theme settings are binary (`Light` / `Dark`), and first desktop
  launch auto-resolves to current system brightness.

Next step:
- Continue refining per-page content details while keeping shell consistent.
