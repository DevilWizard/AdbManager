import AppKit
import SwiftUI
import AdbManagerCore

/// 设备列表和详情共用的品牌标志；所有图片随 App 离线分发，不因设备刷新发起网络请求。
@MainActor
struct DeviceBrandLogo: View {
    /// 跟随当前窗口的系统外观；切换主题时 SwiftUI 会重新选择官方素材与承载底色。
    @Environment(\.colorScheme) private var colorScheme

    let brand: DeviceBrand
    /// 容器保持正方形，品牌原图仍按自身比例等比显示，避免拉伸 Samsung 等宽字标。
    let size: CGFloat

    var body: some View {
        let resolved = DeviceBrandImageCache.image(for: brand, colorScheme: colorScheme)
        let image = resolved?.image

        Group {
            if let image {
                Image(nsImage: image)
                    // 官方彩色原图不参与按钮或侧栏的模板着色；PDF 保留矢量 representation。
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.13)
            } else {
                // 未识别、未读到详情或资源缺失时沿用 Android 标志，保证设备列表始终有图形。
                AndroidBrandMark()
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        // 透明原图不需要白色方块；主题版本使用当前主题的中性底色。若缺少对应官方版本，
        // 则尊重清单指定的保底背景，避免将黑字放在深底或将白字放在浅底而看不见。
        .background(backingColor(for: resolved?.backing ?? .adaptive),
                    in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                              lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(image == nil ? DeviceBrand.android.displayName : brand.displayName) 标志")
    }

    /// 浅深承载层只改变应用自己的底色，绝不对官方彩色图进行反色、灰度化或模板着色。
    private func backingColor(for backing: DeviceBrandImageCache.Backing) -> Color {
        switch backing {
        case .adaptive:
            return colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.97)
        case .white:
            return Color(white: 0.97)
        case .black:
            return Color(white: 0.14)
        }
    }
}

/// 只在主线程访问 NSImage，并缓存成功和缺失结果，避免 SwiftUI 重算或分钟刷新时重复读磁盘。
@MainActor
private enum DeviceBrandImageCache {
    /// adaptive 表示原图可跨主题共用；固定明暗背景仅用于缺少官方主题版本时的可读性兜底。
    enum Backing: String {
        case adaptive, white, black
    }

    struct ResolvedImage {
        let image: NSImage
        let backing: Backing
    }

    private static var images: [String: NSImage] = [:]
    private static var missingNames: Set<String> = []

    /// 来源清单同时记录基础版本适合的背景；不把某个品牌的呈现规则散落在多处 switch 中。
    private static let baseBackings: [String: Backing] = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "DeviceBrands"),
              let data = try? Data(contentsOf: url),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let brands = manifest["brands"] as? [[String: Any]] else { return [:] }
        var backings: [String: Backing] = [:]
        for brand in brands where (brand["appearance"] as? String ?? "base") == "base" {
            guard let identifier = brand["id"] as? String,
                  let value = brand["backing"] as? String,
                  let backing = Backing(rawValue: value) else { continue }
            backings[identifier] = backing
        }
        return backings
    }()

    /// 先选择当前主题的官方版本，再尝试基础版本；缓存键包含完整资源名，避免切换主题仍沿用旧图。
    static func image(for brand: DeviceBrand, colorScheme: ColorScheme) -> ResolvedImage? {
        guard brand != .android else { return nil }
        let resourceName = "Brand-\(brand.rawValue)"
        let appearance = colorScheme == .dark ? "dark" : "light"
        if let image = load(resourceName: "\(resourceName)-\(appearance)") {
            return ResolvedImage(image: image, backing: .adaptive)
        }
        guard let image = load(resourceName: resourceName) else { return nil }
        // 打包清单缺失时沿用已知安全背景；正常包始终由离线准备脚本提供完整清单。
        let backing = baseBackings[brand.rawValue] ?? (brand == .sony ? .black : .white)
        return ResolvedImage(image: image, backing: backing)
    }

    /// PDF/PNG 按原始内容解码；命中或缺失均以完整文件名缓存，同品牌不同主题不会互相覆盖。
    private static func load(resourceName: String) -> NSImage? {
        if let image = images[resourceName] { return image }
        guard !missingNames.contains(resourceName) else { return nil }

        // 矢量 PDF 优先；只有官方提供的是位图时才读取原分辨率 PNG。Runtime 目录在打包时已筛选，
        // 这里不会读取项目中遗留的第三方 SVG，也不在运行时启动 WebView 进行图形转换。
        let image = ["pdf", "png"].lazy.compactMap { fileExtension -> NSImage? in
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: fileExtension,
                                            subdirectory: "DeviceBrands") else { return nil }
            return NSImage(contentsOf: url)
        }.first
        guard let image else {
            // 不使用其他品牌冒充缺失标志，也不从远端临时下载；交给调用方显示 Android 兜底。
            missingNames.insert(resourceName)
            return nil
        }
        images[resourceName] = image
        return image
    }
}
