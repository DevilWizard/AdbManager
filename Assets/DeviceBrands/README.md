# 手机品牌官方素材

此目录保存品牌官方原件、来源证据与用于应用的离线资源。所有标识、素材与商标权利归对应品牌所有；官方提供下载并不表示对 AdbManager 的赞助或背书。

## 当前资源

- 已取得 **12 个品牌**的官方素材；**Nokia 手机传统字标未取得可靠官方原件**，应用显示 Android 兜底，不使用 Nokia 网络公司的新标识代替。

- `Originals/<brand>/`：官方下载的原始文件；原字节不修改，官网内嵌 SVG 或字体轮廓的提取过程另有记录。

- `official-*.json`：来源采集记录，包含来源页、下载 URL、原件 SHA-256 与必要的提取说明。

- `Runtime/`：应用实际使用的 12 个基础 Logo、官方主题版本，以及合并后的 `manifest.json`。基础资源为 9 个矢量 PDF、3 个官方 PNG；主题文件使用 `-dark` / `-light` 后缀。旧的 Simple Icons 素材已移除，不再参与打包。

- 根 `manifest.json`：与 Runtime 相同，记录原件及运行文件摘要、转换过程和矢量验证结果。


| 品牌 | 官方来源 | 应用格式 |
| --- | --- | --- |
| asus | [官方页面](https://www.asus.com/) | PDF |
| google | [官方页面](https://partnermarketinghub.withgoogle.com/brands/google/branding-guidelines/how-to-show-googles-brand/) | PNG |
| honor | [官方页面](https://www.honor.com/cn/) | PDF |
| huawei | [官方页面](https://www.huawei.com/en/) | PDF |
| lenovo | [官方页面](https://brandworld.lenovo.com/visual-identity/logo/) | PNG |
| motorola | [官方页面](https://www.motorola.com/us/en) | PDF |
| nokia | 未取得可信手机品牌原件 | Android 兜底 |
| oneplus | [官方页面](https://www.oneplus.com/uk/brand/asset) | PNG |
| oppo | [官方页面](https://www.oppo.com/cn/) | PDF |
| samsung | [官方页面](https://www.samsung.com/us/about-us/brand-identity/logo/) | PDF |
| sony | [官方页面](https://www.sony.net/) | PDF |
| vivo | [官方页面](https://www.vivo.com.cn/) | PDF |
| xiaomi | [官方页面](https://www.mi.com/) | PDF |

## 无损准备方式

Samsung 官方 RGB `.ai` 本身是 PDF-compatible 矢量；运行资源仅改变扩展名，文件字节及 SHA-256 完全一致。其余 SVG 直接内联到系统 WebKit，以透明背景导出 PDF，没有经过 Canvas、屏幕截图或固定像素母版。脚本递归检查 PDF 实际绘制的路径、曲线和 Image XObject，确认 Logo 保持矢量；AppKit 加载时保留 `NSPDFImageRep`。

Google 使用官方当前彩色渐变 G 的 2820×2820 原始透明 PNG。因原画布存在大量透明留白，运行文件仅精确裁去透明区，并保留相当于图形最长边 12% 的安全边距；图形像素没有缩放、重绘或改色。原件完整保留。Lenovo 与 OnePlus 的官方 PNG 原字节复制，未重新编码。Sony 官方白色字标保持原色，界面以黑色承载层保证可见。

## 深浅主题

应用使用当前窗口的 SwiftUI `colorScheme` 选择资源，并以完整资源名分别缓存基础图、深色图和浅色图。主题切换会重新选择素材与中性承载底色，列表和详情的外框尺寸保持不变。图片保留原色，不统一套用模板着色。

| 品牌 | 深色模式素材与证据 |
| --- | --- |
| Samsung | 官方品牌包 White RGB AI/PDF 原件 |
| Google | 官方指南要求完整彩色渐变 G；同一透明原图适用简单浅/深背景 |
| Xiaomi | 官方橙色底形与白色 mi 完整共用 |
| Huawei | 官方消费者官网深色 Logo SVG 内嵌的透明 PNG，原字节解码保留红花瓣和白字；该版本为位图 |
| OnePlus | 官方品牌包 White RGB PNG 原件 |
| OPPO、vivo | 官网明确的白色呈现规则与原 SVG/字体轮廓精确组合；属于官方样式复现，另存原轮廓、CSS 与摘要，并非另行下载的白色 SVG 原件 |
| Motorola | 官方手机官网直接引用的白色蝙蝠圆标 SVG |
| ASUS | 官方 Pressroom White 原 PNG；仅裁透明留白并保留 12% 安全边距 |
| Sony | 官网原始白字 SVG 直接用于深色；浅色暂无可靠黑字原件，继续以深底承载白字 |
| Lenovo | 官方红色包含框与白字原 PNG 共用，保留完整红框 |
| HONOR | 当前核对的官方 header/footer 仅见黑字；未取得可靠反白原件或官方反白规则，深色暂用浅灰底承载官方黑字 |

深色来源单独记录在 `official-dark-a.json` / `official-dark-b.json`。脚本同时核验主题输入、原轮廓和 CSS 证据的 SHA-256；清单中的 `source_status`、`transformation` 与 `official_style_rule` 区分官方原始文件和官方网页样式复现。未取得版本记录为 `unavailable`，安全兜底不会被标成官方反白素材。


## 重新准备

首次下载或更新官方原件后，检查 `official-*.json` 的来源与摘要，再从项目根目录执行：

```bash
swift scripts/prepare-brand-assets.swift Assets/DeviceBrands
```

准备过程完全离线，不显示窗口，不执行素材中的 JavaScript；输入只能来自 `Originals/` 且须与官方清单 SHA-256 相符。先在临时目录完成所有转换和验证，再替换 `Runtime/`，失败时保留上次完整资源。

普通 `scripts/build-app.sh` 不重复运行转换，只将批准品牌的 Runtime PDF/PNG、合并清单和本说明复制到 App；不会把官方 ZIP、字体、原始下载包或旧第三方素材带入应用。
