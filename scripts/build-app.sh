#!/bin/bash
# 构建原生 macOS 应用包。所有产物均写入项目目录，不安装到系统目录。
set -euo pipefail

# 通过脚本所在位置定位项目，允许从任意工作目录调用并兼容带空格的路径。
SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
CONFIGURATION="${ADB_MANAGER_CONFIGURATION:-release}"
OUTPUT_DIRECTORY="${PROJECT_DIRECTORY}/dist"
APPLICATION_PATH="${OUTPUT_DIRECTORY}/AdbManager.app"
# 品牌资源随应用离线分发；集中定义目录，避免资源预检与组装路径不一致。
DEVICE_BRAND_DIRECTORY="${PROJECT_DIRECTORY}/Assets/DeviceBrands"
# 只发布已由官方来源清单生成的 Runtime；不把原始下载包、字体或旧图标库素材复制进应用。
DEVICE_BRAND_RUNTIME_DIRECTORY="${DEVICE_BRAND_DIRECTORY}/Runtime"
DEVICE_BRANDS=(samsung google xiaomi huawei honor oppo vivo oneplus motorola lenovo sony asus)

# 项目不含第三方依赖；只需要 Xcode 或 Command Line Tools 提供的 Swift 工具链。
if ! command -v swift >/dev/null 2>&1; then
    echo "未找到 Swift。请先安装 Xcode 或执行 xcode-select --install。" >&2
    exit 1
fi

# 提前检查资源，避免生成缺少图标或应用元数据的不完整应用。
for resource in "Assets/AndroidHead.png" "Assets/AppIcon.icns" "Support/Info.plist"; do
    if [[ ! -f "${PROJECT_DIRECTORY}/${resource}" ]]; then
        echo "缺少构建资源：${resource}" >&2
        exit 1
    fi
done

# 准备脚本已在开发时校验官方原件并导出矢量；普通构建无需重复启动 WebKit。
if [[ ! -f "${DEVICE_BRAND_RUNTIME_DIRECTORY}/manifest.json" ]]; then
    echo "缺少官方品牌 Runtime；请先执行 swift scripts/prepare-brand-assets.swift Assets/DeviceBrands。" >&2
    exit 1
fi
for brand in "${DEVICE_BRANDS[@]}"; do
    if [[ ! -f "${DEVICE_BRAND_RUNTIME_DIRECTORY}/Brand-${brand}.pdf" && ! -f "${DEVICE_BRAND_RUNTIME_DIRECTORY}/Brand-${brand}.png" ]]; then
        echo "缺少官方品牌图标：Runtime/Brand-${brand}.pdf 或 .png" >&2
        exit 1
    fi
done

echo "正在构建 AdbManager（${CONFIGURATION}）…"
# 显式使用项目内缓存与 SwiftPM 状态目录，兼容权限受限的工作目录执行环境。
BUILD_DIRECTORY="${PROJECT_DIRECTORY}/.build"
export CLANG_MODULE_CACHE_PATH="${BUILD_DIRECTORY}/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${BUILD_DIRECTORY}/module-cache"
mkdir -p "${BUILD_DIRECTORY}/module-cache" "${BUILD_DIRECTORY}/cache" \
    "${BUILD_DIRECTORY}/config" "${BUILD_DIRECTORY}/security"
SWIFT_PACKAGE_OPTIONS=(
    --package-path "${PROJECT_DIRECTORY}"
    --scratch-path "${BUILD_DIRECTORY}"
    --cache-path "${BUILD_DIRECTORY}/cache"
    --config-path "${BUILD_DIRECTORY}/config"
    --security-path "${BUILD_DIRECTORY}/security"
    --disable-sandbox
    --configuration "${CONFIGURATION}"
)
swift build "${SWIFT_PACKAGE_OPTIONS[@]}"
BINARY_DIRECTORY="$(swift build "${SWIFT_PACKAGE_OPTIONS[@]}" --show-bin-path)"

# 先在临时目录组装完整应用；构建或签名失败时保留上一次可用产物。
mkdir -p "${OUTPUT_DIRECTORY}"
STAGING_DIRECTORY="$(mktemp -d "${OUTPUT_DIRECTORY}/.AdbManager.build.XXXXXX")"
trap 'rm -rf "${STAGING_DIRECTORY}"' EXIT
STAGING_APPLICATION="${STAGING_DIRECTORY}/AdbManager.app"
mkdir -p "${STAGING_APPLICATION}/Contents/MacOS" "${STAGING_APPLICATION}/Contents/Resources"
cp "${BINARY_DIRECTORY}/AdbManager" "${STAGING_APPLICATION}/Contents/MacOS/AdbManager"
cp "${PROJECT_DIRECTORY}/Support/Info.plist" "${STAGING_APPLICATION}/Contents/Info.plist"
cp "${PROJECT_DIRECTORY}/Assets/AndroidHead.png" "${STAGING_APPLICATION}/Contents/Resources/AndroidHead.png"
cp "${PROJECT_DIRECTORY}/Assets/AppIcon.icns" "${STAGING_APPLICATION}/Contents/Resources/AppIcon.icns"
# 按批准品牌逐个复制，只包含官方矢量 PDF 或官方高分辨率 PNG；Nokia 暂无可信手机字标，
# 因而不打包曾经误用的网络公司标识，运行时自动显示 Android 兜底。
PACKAGED_BRAND_DIRECTORY="${STAGING_APPLICATION}/Contents/Resources/DeviceBrands"
mkdir -p "${PACKAGED_BRAND_DIRECTORY}"
for brand in "${DEVICE_BRANDS[@]}"; do
    if [[ -f "${DEVICE_BRAND_RUNTIME_DIRECTORY}/Brand-${brand}.pdf" ]]; then
        cp "${DEVICE_BRAND_RUNTIME_DIRECTORY}/Brand-${brand}.pdf" "${PACKAGED_BRAND_DIRECTORY}/"
    else
        cp "${DEVICE_BRAND_RUNTIME_DIRECTORY}/Brand-${brand}.png" "${PACKAGED_BRAND_DIRECTORY}/"
    fi
    # 主题版本由官方片段单独准备；按已批准品牌和固定后缀复制，避免把原始包或其他文件带入 App。
    # 没有主题文件表示该品牌使用可共用原图或对比度安全兜底，不会在构建时擅自改色。
    for appearance in light dark; do
        if [[ -f "${DEVICE_BRAND_RUNTIME_DIRECTORY}/Brand-${brand}-${appearance}.pdf" ]]; then
            cp "${DEVICE_BRAND_RUNTIME_DIRECTORY}/Brand-${brand}-${appearance}.pdf" "${PACKAGED_BRAND_DIRECTORY}/"
        elif [[ -f "${DEVICE_BRAND_RUNTIME_DIRECTORY}/Brand-${brand}-${appearance}.png" ]]; then
            cp "${DEVICE_BRAND_RUNTIME_DIRECTORY}/Brand-${brand}-${appearance}.png" "${PACKAGED_BRAND_DIRECTORY}/"
        fi
    done
done
cp "${DEVICE_BRAND_RUNTIME_DIRECTORY}/manifest.json" "${PACKAGED_BRAND_DIRECTORY}/manifest.json"
cp "${DEVICE_BRAND_DIRECTORY}/README.md" "${PACKAGED_BRAND_DIRECTORY}/README.md"
chmod +x "${STAGING_APPLICATION}/Contents/MacOS/AdbManager"

# 本地 ad-hoc 签名不需要开发者证书；正式分发时应替换为 Developer ID 签名与公证。
/usr/bin/plutil -lint "${STAGING_APPLICATION}/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "${STAGING_APPLICATION}"
/usr/bin/codesign --verify --deep --strict "${STAGING_APPLICATION}"

# 只替换本脚本生成的固定路径，避免影响项目中的源码与其他应用。
if [[ -e "${APPLICATION_PATH}" ]]; then
    rm -rf "${APPLICATION_PATH}"
fi
mv "${STAGING_APPLICATION}" "${APPLICATION_PATH}"
echo "构建完成：${APPLICATION_PATH}"
echo "可在 Finder 中打开此应用，或执行：open \"${APPLICATION_PATH}\""
