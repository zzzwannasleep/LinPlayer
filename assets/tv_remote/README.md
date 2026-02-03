# TV Remote Web UI (Embedded)

This folder contains static web assets served by LinPlayer's built-in TV pairing server (`TvRemoteService`).

Sources / attribution:
- Remote UI inspiration & base assets: `synamedia-senza/remote` (ISC license as declared in its `package.json`)
  - `images/buttons.png` is downloaded from that repo.

LinPlayer customizations:
- Replaced the Node + Socket.IO transport with a lightweight WebSocket endpoint implemented in Dart.
- Added a "Setup" page for adding Emby/Jellyfin/WebDAV servers directly to the TV via the local network.
- Added a "Settings" page for adjusting TV settings from the phone (e.g. background, UI scale, TV-only toggles).
