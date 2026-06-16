#!/bin/sh
# 用完整版 libmpv 覆盖 media_kit 随包的 Mpv.framework 二进制（macOS）。
#
# 触发：Xcode「Upgrade libmpv」Run Script 阶段在构建末尾调用。
# 机制：若仓库 macos/libmpv/Mpv 存在（用户放入的完整版 libmpv 二进制），
#       就覆盖 .app 内 Contents/Frameworks/Mpv.framework/Mpv；不存在则跳过。
# 用 LINPLAYER_SKIP_LIBMPV_UPGRADE=1 可显式跳过。
set -e

if [ "${LINPLAYER_SKIP_LIBMPV_UPGRADE}" = "1" ]; then
  echo "[upgrade_libmpv] 已通过环境变量跳过"
  exit 0
fi

SRC="${SRCROOT}/libmpv/Mpv"
DEST_FRAMEWORK="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Frameworks/Mpv.framework"
DEST="${DEST_FRAMEWORK}/Mpv"

if [ ! -f "${SRC}" ]; then
  echo "[upgrade_libmpv] 未提供 macos/libmpv/Mpv，跳过（使用 media_kit 自带 libmpv）"
  exit 0
fi
if [ ! -d "${DEST_FRAMEWORK}" ]; then
  echo "[upgrade_libmpv] 未找到 Mpv.framework，跳过：${DEST_FRAMEWORK}"
  exit 0
fi

echo "[upgrade_libmpv] 用完整版 libmpv 覆盖：${DEST}"
cp -f "${SRC}" "${DEST}"

# 重新签名，避免 Gatekeeper / 加载失败（使用工程当前签名身份）。
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY}" ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${DEST}" || \
    echo "[upgrade_libmpv] 警告：codesign 失败，可能需手动签名"
fi
echo "[upgrade_libmpv] 完成"
