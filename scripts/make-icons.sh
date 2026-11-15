#!/bin/bash
# 重新生成图标：只使用 macOS 自带的 WebKit、sips 与 iconutil，不依赖第三方包。
set -euo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
ASSET_DIRECTORY="${PROJECT_DIRECTORY}/Assets"

# Swift 模块缓存放在项目构建目录，避免向系统或用户全局缓存写入文件。
MODULE_CACHE_DIRECTORY="${PROJECT_DIRECTORY}/.build/IconModuleCache"
mkdir -p "${MODULE_CACHE_DIRECTORY}"
swift -module-cache-path "${MODULE_CACHE_DIRECTORY}" \
    "${SCRIPT_DIRECTORY}/render-icon.swift" \
    "${ASSET_DIRECTORY}/android-head_3D.svg" "${ASSET_DIRECTORY}"

# 一个 .iconset 同时包含标准分辨率与 Retina 图像，系统可按显示尺寸选择清晰版本。
TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/AdbManager-icons.XXXXXX")"
trap 'rm -rf "${TEMPORARY_DIRECTORY}"' EXIT
ICONSET_DIRECTORY="${TEMPORARY_DIRECTORY}/AppIcon.iconset"
mkdir -p "${ICONSET_DIRECTORY}"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "${size}" "${size}" "${ASSET_DIRECTORY}/AppIcon1024.png" \
        --out "${ICONSET_DIRECTORY}/icon_${size}x${size}.png" >/dev/null
    retina_size="$((size * 2))"
    /usr/bin/sips -z "${retina_size}" "${retina_size}" "${ASSET_DIRECTORY}/AppIcon1024.png" \
        --out "${ICONSET_DIRECTORY}/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "${ICONSET_DIRECTORY}" -o "${ASSET_DIRECTORY}/AppIcon.icns"
echo "图标资源已更新：${ASSET_DIRECTORY}/AppIcon.icns"
