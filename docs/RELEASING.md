# 发布 Release

普通源码更新提交并推送到 `main` 即可同步 GitHub；只有推送版本 tag 才会触发 App Release。

## 发布新版

1. 更新 `Support/Info.plist` 中的版本号和构建号。tag 必须为 `v` 加版本号，例如版本 `1.0.9` 对应 `v1.0.9`。
2. 完成本地验证，将需要发布的源码提交并推送到 `main`。发布流程会再次执行测试和打包检查。
3. 在准备发布的提交上创建并推送 tag：

   ```bash
   git switch main
   git pull --ff-only
   git tag -a v1.0.9 -m "AdbManager 1.0.9"
   git push origin v1.0.9
   ```

   后续版本应替换示例中的版本号。不要移动或覆盖已经发布的 tag。

4. 在 GitHub **Actions** 查看 Release 工作流。工作流测试通过后构建 App，创建草稿 Release、上传 ZIP 与校验文件，全部成功后公开发布。
5. 在 **Releases** 确认版本、下载附件和安装说明正确。下载 ZIP 与 `SHA256SUMS.txt`，再执行一次校验并检查解压后的 App。

也可以通过工作流的手动运行入口选择一个已经存在的版本 tag；它不会把任意 `main` 分支内容当作版本发行，也不会覆盖已有 Release。

## 本地准备发行包

在项目根目录运行：

```bash
./scripts/package-release.sh v1.0.9
```

脚本核对版本，构建包含 Apple Silicon（arm64）与 Intel（x86_64）的 Universal App，最低支持 macOS 14，并在 `dist/releases/v1.0.9/` 生成发行文件。ZIP 名称为 `AdbManager-v1.0.9-macOS-universal.zip`，配套校验文件为 `SHA256SUMS.txt`。`dist/` 不提交到 Git，发行附件由工作流上传。

当前发行包使用 ad-hoc 签名，尚未进行 Developer ID 签名和 Apple 公证。Release 和安装说明必须保留这一状态；不能将本地代码签名检查通过描述为已通过 Apple 公证。应用继续使用用户本机的 ADB，发行包不捆绑 Android SDK Platform Tools。
