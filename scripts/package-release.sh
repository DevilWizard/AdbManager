#!/bin/bash
# 生成可下载的 Universal 发行包。只处理本地文件，不创建 Git tag 或 GitHub Release。
set -euo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_DIRECTORY}/Support/Info.plist")"
RELEASE_TAG="${1:-v${VERSION}}"
SKIP_BUILD=false

# 只接受正式三段版本号，标签同时进入文件名和发行文案，不能包含路径或 shell 片段。
if [[ ! "${RELEASE_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "${RELEASE_TAG}" != "v${VERSION}" ]]; then
    echo "发行标签必须等于 Info.plist 中的版本：v${VERSION}" >&2
    exit 1
fi
if [[ "${2:-}" == "--skip-build" && "$#" -eq 2 ]]; then
    # 已经由调用方完成相同源码的 Universal 构建时，可仅重新执行打包与校验。
    SKIP_BUILD=true
elif [[ "$#" -gt 1 ]]; then
    echo "用法：$0 [v${VERSION}] [--skip-build]" >&2
    exit 1
fi

APPLICATION_PATH="${PROJECT_DIRECTORY}/dist/AdbManager.app"
RELEASE_DIRECTORY="${PROJECT_DIRECTORY}/dist/releases/${RELEASE_TAG}"
ARCHIVE_NAME="AdbManager-${RELEASE_TAG}-macOS-universal.zip"
if [[ -e "${RELEASE_DIRECTORY}" ]]; then
    echo "发行产物目录已存在，不会覆盖：${RELEASE_DIRECTORY}" >&2
    exit 1
fi

if [[ "${SKIP_BUILD}" != true ]]; then
    ADB_MANAGER_CONFIGURATION=release "${SCRIPT_DIRECTORY}/build-app.sh" --universal
fi

# 即使跳过构建，也必须验证应用版本、两个架构及签名，避免误发旧包或当前机器的单架构包。
APPLICATION_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APPLICATION_PATH}/Contents/Info.plist")"
if [[ "${APPLICATION_VERSION}" != "${VERSION}" ]]; then
    echo "应用版本与发行标签不匹配。" >&2
    exit 1
fi
/usr/bin/xcrun lipo "${APPLICATION_PATH}/Contents/MacOS/AdbManager" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --deep --strict "${APPLICATION_PATH}"

# 压缩包包含单一 AdbManager 文件夹，用户解压后可以直接把 .app 拖入 Applications。
# 先写临时目录，全部验证成功后才移动为版本目录，失败不留下半成品发行文件。
mkdir -p "${PROJECT_DIRECTORY}/dist/releases"
STAGING_DIRECTORY="$(mktemp -d "${PROJECT_DIRECTORY}/dist/.AdbManager.release.XXXXXX")"
trap 'rm -rf "${STAGING_DIRECTORY}"' EXIT
PACKAGE_DIRECTORY="${STAGING_DIRECTORY}/AdbManager"
mkdir -p "${PACKAGE_DIRECTORY}"
/usr/bin/ditto "${APPLICATION_PATH}" "${PACKAGE_DIRECTORY}/AdbManager.app"
cp "${PROJECT_DIRECTORY}/LICENSE" "${PACKAGE_DIRECTORY}/LICENSE"
cp "${PROJECT_DIRECTORY}/THIRD_PARTY_NOTICES.md" "${PACKAGE_DIRECTORY}/THIRD_PARTY_NOTICES.md"
{
    # 变量仅由 printf 输出；正文用引用 heredoc，Markdown 反引号不会触发 shell 执行。
    printf '# AdbManager %s\n\n' "${VERSION}"
    cat <<'EOF'
## 安装

1. 将同目录的 AdbManager.app 拖入“应用程序”（Applications）。
2. 打开应用，选择需要管理的设备。

系统要求：macOS 14 或更新版本。此包同时包含 Apple Silicon（arm64）和 Intel（x86_64）可执行文件，无需编译源码。

## ADB 与设备

本包不捆绑 Android SDK。请先安装官方 Android SDK Platform Tools，应用会自动查找已有的 adb；未找到时，可在应用设置中选择 adb 可执行文件。

Platform Tools：https://developer.android.com/tools/releases/platform-tools

手机需开启 USB 调试并授权当前电脑。插线初始化的传统无线连接使用 TCP 5555，调试流量不加密，请仅在可信网络使用。HTTPS 抓包还需手机和目标应用信任抓包证书。

## 代理默认值

每次启动都会检测当前 Mac 的局域网 IPv4，用检测到的第一个地址填入代理主机；没有可用地址时保持为空，可手动填写。端口恢复上次应用时保存的值，首次默认 9090。运行中的定时刷新和设备切换不覆盖当前输入；点击“应用代理”后才会将主机和端口写入手机。

## 首次打开与签名状态

此版本仅采用本地 ad-hoc 签名，没有 Developer ID 签名，也未经 Apple 公证。macOS 首次打开可能会阻止运行；这不等于已经获得 Apple 安全审核。

确认文件来自本项目且校验值一致后，按 Apple 官方指南处理系统提示：先尝试打开，再进入“系统设置 → 隐私与安全性”查看该应用的“仍要打开”选项。不要关闭系统整体的 Gatekeeper 防护。

Apple 指南：https://support.apple.com/102445

代码许可与品牌素材权利分别见同目录 LICENSE 和 THIRD_PARTY_NOTICES.md。
EOF
} > "${PACKAGE_DIRECTORY}/INSTALL.md"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${PACKAGE_DIRECTORY}" "${STAGING_DIRECTORY}/${ARCHIVE_NAME}"
(
    cd "${STAGING_DIRECTORY}"
    # 校验清单只列公开下载的 ZIP；下载 ZIP 与清单即可完整执行 shasum -c。
    /usr/bin/shasum -a 256 "${ARCHIVE_NAME}" > SHA256SUMS.txt
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)

# 再从 ZIP 解压并校验，而非只检查压缩前目录，捕获打包造成的权限或资源损坏。
VERIFICATION_DIRECTORY="${STAGING_DIRECTORY}/verify"
/usr/bin/ditto -x -k "${STAGING_DIRECTORY}/${ARCHIVE_NAME}" "${VERIFICATION_DIRECTORY}"
/usr/bin/codesign --verify --deep --strict "${VERIFICATION_DIRECTORY}/AdbManager/AdbManager.app"
/usr/bin/xcrun lipo "${VERIFICATION_DIRECTORY}/AdbManager/AdbManager.app/Contents/MacOS/AdbManager" -verify_arch arm64 x86_64

# 发行说明与下载包一起交给 CI 发布 job；说明不是下载附件，故不加入 SHA 清单。
{
    printf '## 下载与安装\n\n下载 **%s**，解压后将 AdbManager.app 拖入“应用程序”。无需编译源码。\n\n' "${ARCHIVE_NAME}"
    cat <<'EOF'
- macOS 14 或更新版本；Universal 包同时支持 Apple Silicon 与 Intel Mac。
- 需要本机已安装 Android SDK Platform Tools（adb）；应用会自动查找，也可在设置中手动选择。
- SHA256SUMS.txt 用于校验 ZIP：将两个文件放在同一目录，执行 `shasum -a 256 -c SHA256SUMS.txt`。

## 功能

- 多 Android 设备管理，同一设备 USB / 无线连接合并展示。
- 已授权 USB 设备一键建立传统 TCP 5555 无线连接，并核对设备身份。
- Android HTTP 代理设置，默认端口 9090，支持自定义。
- 代理主机每次启动重新检测当前 Mac IP，不恢复旧地址；无可用地址时留空，端口保留上次应用值或默认 9090。
- 品牌 Logo 跟随系统深浅外观；设备连接事件驱动刷新，详情每分钟更新。

## 首次打开提示

**本版本为 ad-hoc 签名，未使用 Developer ID，也未经过 Apple 公证。** macOS 可能拦截首次启动。确认来源与校验值后，按照 [Apple 官方指南](https://support.apple.com/102445) 在“系统设置 → 隐私与安全性”处理该应用的“仍要打开”提示。项目不会移除 quarantine 或关闭系统防护。

传统 TCP 5555 调试流量不加密，仅用于可信网络；HTTPS 抓包仍需手机及目标应用信任证书。

代码采用 MIT License；品牌 Logo 等第三方素材的权利归属见包内 THIRD_PARTY_NOTICES.md。
EOF
} > "${STAGING_DIRECTORY}/release-notes.md"

# 最终目录只放应发布/消费的三个文件，源码与临时解压校验目录不会随之上传。
FINAL_STAGING="${STAGING_DIRECTORY}/final"
mkdir -p "${FINAL_STAGING}"
mv "${STAGING_DIRECTORY}/${ARCHIVE_NAME}" "${STAGING_DIRECTORY}/SHA256SUMS.txt" \
    "${STAGING_DIRECTORY}/release-notes.md" "${FINAL_STAGING}/"
mv "${FINAL_STAGING}" "${RELEASE_DIRECTORY}"
echo "发行包已生成：${RELEASE_DIRECTORY}/${ARCHIVE_NAME}"
echo "SHA-256 校验清单：${RELEASE_DIRECTORY}/SHA256SUMS.txt"
