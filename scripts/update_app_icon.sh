#!/bin/bash
set -euo pipefail

# 从最终确认的透明 PNG 母版生成全部 macOS 图标尺寸。
# 这里只做确定性的尺寸转换，不修改图案、色彩或透明边缘；构建时由 Xcode 生成 ICNS。
ICON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICON_PROJECT_ROOT="$(cd "${ICON_SCRIPT_DIR}/.." && pwd)"
ICON_SOURCE_PATH="${1:-${ICON_PROJECT_ROOT}/docs/branding/quotio-plus-icon.png}"
ICON_ASSET_ROOT="${ICON_PROJECT_ROOT}/Quotio/Assets.xcassets"

[[ -f "${ICON_SOURCE_PATH}" ]] || { echo "找不到图标母版：${ICON_SOURCE_PATH}" >&2; exit 1; }

# 稳定版与 Beta 入口都替换，避免切换更新通道时重新出现原作者旧图标。
# 文件名与资产目录的 Contents.json 对齐，保留既有 Xcode 资源引用。
for ICON_SET_NAME in AppIcon AppIconBeta; do
    while read -r ICON_FILE_NAME ICON_PIXEL_SIZE; do
        /usr/bin/sips -z "${ICON_PIXEL_SIZE}" "${ICON_PIXEL_SIZE}" "${ICON_SOURCE_PATH}" \
            --out "${ICON_ASSET_ROOT}/${ICON_SET_NAME}.appiconset/${ICON_FILE_NAME}" >/dev/null
    done <<'ICON_SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
icon_1024x1024.png 1024
ICON_SIZES
done

# 侧栏、关于页面及运行时通道图标读取独立 imageset，也必须同步更新。
for ICON_IMAGE_SET in AppIconImage AppIconBetaImage; do
    /usr/bin/sips -z 1024 1024 "${ICON_SOURCE_PATH}" \
        --out "${ICON_ASSET_ROOT}/${ICON_IMAGE_SET}.imageset/icon.png" >/dev/null
done

echo "已更新应用图标、侧栏图标和更新通道图标。"
