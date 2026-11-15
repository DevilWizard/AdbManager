# 图标资源

- 用户指定的官方地址：<https://developer.android.com/static/images/brand/android-head_3D.svg>
- 本次下载使用 Android 官方中国镜像：<https://developer.android.google.cn/static/images/brand/android-head_3D.svg>。主机网络访问原始域名连接超时，因此从官方镜像获取同路径资源。
- `android-head_3D.svg` 保留下载内容，不修改 SVG 路径、渐变或颜色。
- `AndroidHead.png`：1024 × 600 透明 PNG，保留原始宽高比例。
- `AppIcon1024.png`：1024 × 1024 透明图标母版，官方图形等比居中并预留边距。
- `AppIcon.icns`：从母版生成 macOS 标准及 Retina 尺寸。

需要重新生成 PNG 与 ICNS 时，在项目目录执行：

```bash
./scripts/make-icons.sh
```

渲染仅使用系统 WebKit Canvas，不访问网络；转换与打包分别使用系统 `sips`、`iconutil`。没有使用生成式图像或替换官方图案。
