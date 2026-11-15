import AppKit
import SwiftUI

/// 只集中定义少量跨卡片的视觉常量，避免各功能视图重复维护颜色与圆角。
enum AdbTheme {
    /// 采用便于在浅色和深色界面识别的绿色，与 Android 图标的品牌色保持呼应。
    static let accent = Color(red: 0.13, green: 0.61, blue: 0.35)
    static let cardRadius: CGFloat = 14
}

/// 统一的功能卡片容器：使用系统背景色与细描边，支持 macOS 深浅色自动切换。
struct FeatureCard<Content: View>: View {
    private let content: Content

    /// 通过 ViewBuilder 接收内容，使后续功能可沿用相同视觉容器，无需耦合具体操作。
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: AdbTheme.cardRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AdbTheme.cardRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            }
    }
}

/// 标题旁的小型状态标签；颜色之外始终保留文字和符号，兼顾可访问性。
struct ConnectionBadge: View {
    let title: String
    let symbol: String
    var isActive = true

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(isActive ? AdbTheme.accent : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                (isActive ? AdbTheme.accent : Color.secondary).opacity(0.1),
                in: Capsule()
            )
    }
}

/// 官方 Android 图形只从 App Bundle 读取；构建资源缺失时使用系统符号保证界面可用。
struct AndroidBrandMark: View {
    /// NSImage 的读取在创建时完成，避免视图 body 的重复求值反复访问资源。
    private let brandImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AndroidHead", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let brandImage {
                Image(nsImage: brandImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "iphone")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(AdbTheme.accent)
                    .padding(8)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 无设备、未选设备与缺少 ADB 三种空态共用布局，但给出各自可执行的下一步。
struct EmptyDeviceView: View {
    let hasDevices: Bool
    let isRefreshing: Bool
    let hasADB: Bool
    let chooseADB: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AndroidBrandMark()
                .frame(width: 102, height: 82)
                .padding(.bottom, 6)

            Text(title)
                .font(.title2.weight(.semibold))

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .frame(maxWidth: 360)

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 4)
            } else if !hasADB {
                Button("选择 ADB…", action: chooseADB)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            } else if !hasDevices {
                Label("自动检测设备接入，也可手动刷新", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 正在扫描时避免把临时空列表误报为配置问题。
    private var title: String {
        if isRefreshing { return "正在查找设备…" }
        if !hasADB { return "先配置 ADB" }
        return hasDevices ? "选择一台设备" : "连接你的 Android 设备"
    }

    /// 空态只解释用户当前需要完成的动作，不暴露后台命令或解析细节。
    private var message: String {
        if !hasADB {
            return "选择 Android SDK 中的 ADB，\n即可管理设备连接与抓包代理。"
        }
        if hasDevices {
            return "从左侧选择设备，\n设置无线连接或 Proxyman 代理。"
        }
        return "用 USB 连接手机，开启 USB 调试，\n并在手机上允许这台 Mac 进行调试。"
    }
}
