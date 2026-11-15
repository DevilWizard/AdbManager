import AppKit
import SwiftUI

/// 应用主窗口：用单一侧栏宽度驱动设备列表和详情布局，保留 macOS 原生窗口与工具栏。
/// 视图只表达界面状态，所有 ADB 命令和状态更新都交由 AppModel 处理。
@MainActor
struct ContentView: View {
    /// 可观察的页面模型；通过 Bindable 让选中设备和代理输入框保持单一数据来源。
    @Bindable var model: AppModel

    /// ADB 路径选择属于应用级设置，因此独立于单个设备的详情展示。
    @State private var showingSettings = false

    /// 侧栏 View 始终保留，只改变可见宽度，避免原生分栏跨越显隐阈值时让详情突然跳位。
    @State private var isSidebarVisible = true

    /// 只跟踪列表和侧栏按钮的焦点；代理输入框持有焦点时，切换侧栏不打断其编辑。
    @FocusState private var isSidebarListFocused: Bool
    @FocusState private var isSidebarToggleFocused: Bool

    /// 尊重系统的“减少动态效果”，此时直接切换几何宽度而不播放展开动画。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 内部内容画布保持正常宽度，动画只有外层 viewport 的宽度这一处几何来源。
    private static let sidebarContentWidth: CGFloat = 260

    /// 仅在明确传入诊断参数时采样布局宽度；默认不记录，也不增加任何产品控件。
    private static let sidebarAnimationDiagnostics = CommandLine.arguments.contains("--sidebar-animation-diagnostics")

    var body: some View {
        HStack(spacing: 0) {
            sidebarViewport

            Group {
                if let device = model.selectedDevice {
                    DeviceDetailView(model: model, device: device)
                } else {
                    EmptyDeviceView(
                        hasDevices: !model.devices.isEmpty,
                        isRefreshing: model.isRefreshing,
                        hasADB: !model.adbPath.isEmpty,
                        chooseADB: { showingSettings = true }
                    )
                }
            }
            // 详情始终使用同一 HStack 剩余宽度，与侧栏共享一次宽度事务，不另设偏移或显隐过渡。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(model.selectedDevice?.name ?? "AdbManager")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Label(isSidebarVisible ? "隐藏设备侧栏" : "显示设备侧栏", systemImage: "sidebar.left")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .focusable()
                .focused($isSidebarToggleFocused)
                .accessibilityLabel(isSidebarVisible ? "隐藏设备侧栏" : "显示设备侧栏")
                .help(isSidebarVisible ? "隐藏设备侧栏（⌃⌘S）" : "显示设备侧栏（⌃⌘S）")
                .accessibilityIdentifier("toggleSidebar")
            }

            ToolbarItemGroup(placement: .automatic) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新设备", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing || model.isPerformingAction)
                .help("刷新设备列表（⌘R）")
                .accessibilityIdentifier("refreshDevices")

                Button {
                    showingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .help("查看和选择 ADB 可执行文件")
                .accessibilityIdentifier("openSettings")
            }
        }
        .tint(AdbTheme.accent)
        .frame(minWidth: 940, minHeight: 660)
        .accessibilityIdentifier("adbmanager.main")
        .sheet(isPresented: $showingSettings) {
            ADBSettingsSheet(model: model)
        }
        .alert("操作未完成", isPresented: errorPresentation) {
            Button("好", role: .cancel) { model.clearError() }
        } message: {
            Text(model.lastError ?? "请稍后重试。")
        }
    }

    /// 常驻的侧栏画布通过单一 viewport 参与 HStack 布局，避免中间态重复约束或显隐阈值。
    private var sidebarViewport: some View {
        sidebar
            // 先固定内容画布，展开过程中不让列表的文字和图标按 0…260 的中间宽度重新排版。
            .frame(width: Self.sidebarContentWidth)
            .background(.regularMaterial)
            .overlay(alignment: .trailing) {
                // 分隔线放在画布内部，不作为 HStack 独立子视图占宽，收起后不会残留一条缝。
                Divider()
                    .accessibilityHidden(true)
            }
            // 只有这一层改变布局宽度；详情同步使用剩余空间，不移除侧栏、不增加 opacity 动画。
            .frame(width: isSidebarVisible ? Self.sidebarContentWidth : 0, alignment: .leading)
            .overlay {
                if Self.sidebarAnimationDiagnostics {
                    // overlay 不参与父布局，只读取现有 viewport 的实际 layout 宽度；不将采样值写回状态。
                    GeometryReader { geometry in
                        Color.clear.preference(key: SidebarViewportWidthPreferenceKey.self, value: geometry.size.width)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onPreferenceChange(SidebarViewportWidthPreferenceKey.self) { width in
                guard Self.sidebarAnimationDiagnostics, width >= 0 else { return }
                let timestamp = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
                let measuredWidth = String(format: "%.3f", Double(width))
                print("SIDEBAR_SAMPLE t=\(timestamp) width=\(measuredWidth)")
            }
            .clipped()
            .allowsHitTesting(isSidebarVisible)
            .disabled(!isSidebarVisible)
            .accessibilityHidden(!isSidebarVisible)
            .accessibilityIdentifier("sidebarViewport")
    }

    /// 工具栏与快捷键共用同一动作；焦点交接只在收起且列表持有焦点时发生。
    private func toggleSidebar() {
        // 诊断启动时只延长同一动画的时长，方便截取中间画面；正常运行仍保持 0.24 秒。
        let animationDuration = Self.sidebarAnimationDiagnostics ? 1.6 : 0.24
        if Self.sidebarAnimationDiagnostics {
            print("SIDEBAR_TOGGLE target=\(isSidebarVisible ? 0 : Int(Self.sidebarContentWidth)) duration=\(reduceMotion ? 0 : animationDuration)")
        }
        if isSidebarVisible && isSidebarListFocused {
            // 先结束列表的原生 first responder，防止零宽度 List 继续处理上下键；不触碰详情输入框焦点。
            NSApp.keyWindow?.makeFirstResponder(nil)
            isSidebarListFocused = false
            isSidebarToggleFocused = true
        }

        var transaction = Transaction(animation: reduceMotion ? nil : .easeInOut(duration: animationDuration))
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) {
            isSidebarVisible.toggle()
        }
    }

    /// 左侧保持紧凑的设备导航：同一台手机的 USB 与无线连接由模型合并展示。
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("设备")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(model.devices.count)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollViewReader { scrollProxy in
                List(selection: $model.selectedDeviceID) {
                    ForEach(model.devices) { device in
                        DeviceSidebarRow(device: device)
                            .id(device.id)
                            .tag(device.id)
                            .padding(.vertical, 5)
                            .accessibilityIdentifier("device.\(device.id)")
                    }
                }
                .listStyle(.sidebar)
                .focused($isSidebarListFocused)
                .accessibilityLabel("Android 设备列表")
                .accessibilityIdentifier("deviceList")
                .onChange(of: model.devices.map(\.id)) { previousIDs, currentIDs in
                    let knownIDs = Set(previousIDs)
                    guard let addedID = currentIDs.first(where: { !knownIDs.contains($0) }) else {
                        return
                    }

                    // 原生侧栏在前方插入新行时可能保留原内容锚点，导致新行上半部分被裁掉。
                    // 只在出现新的物理设备 ID 时调整滚动位置；详情刷新、状态更新和重新排序不干扰手动滚动。
                    Task { @MainActor in
                        // 让本轮新增行先注册到 List，再通过稳定 ID 定位；不使用任意延时或重建列表。
                        await Task.yield()
                        guard model.devices.contains(where: { $0.id == addedID }) else {
                            return
                        }
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            scrollProxy.scrollTo(addedID, anchor: .top)
                        }
                    }
                }
                .overlay {
                    if model.devices.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "iphone.slash")
                                .font(.system(size: 25, weight: .light))
                            Text(model.isRefreshing ? "正在查找设备…" : "暂无设备")
                                .font(.callout)
                        }
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                    }
                }
            }

            Divider()
            HStack(spacing: 7) {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(model.adbPath.isEmpty ? Color.orange : AdbTheme.accent)
                        .frame(width: 6, height: 6)
                }
                Text(model.adbPath.isEmpty ? "需要配置 ADB" : "监听设备连接")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("AdbManager")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            .help("连接状态变化时自动更新设备列表；设备详情每分钟更新；仍可手动刷新")
        }
    }

    /// Alert 的显隐由错误本身驱动，关闭弹窗时同步清理错误，避免后续刷新重复弹出。
    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { isPresented in
                if !isPresented { model.clearError() }
            }
        )
    }
}

/// 只向上报告诊断 overlay 的布局宽度；此值不作为动画或业务状态来源。
private struct SidebarViewportWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = -1

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 侧栏中的单台物理设备：连接方式与可用状态分开，便于识别同时在线的 USB 和 Wi-Fi。
@MainActor
private struct DeviceSidebarRow: View {
    let device: ManagedDevice

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            // 品牌图形与文字使用稳定尺寸，不参与侧栏展开时的文字压缩或设备身份判断。
            DeviceBrandLogo(brand: device.brand, size: 38)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(device.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Circle()
                        .fill(device.isAuthorized ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(device.statusTitle)
                }
                Text(device.serial)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    if device.hasUSB {
                        Label("USB", systemImage: "cable.connector")
                    }
                    if device.hasWireless {
                        Label("无线", systemImage: "wifi")
                    }
                    if !device.isAuthorized {
                        Text(device.statusTitle)
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                // 侧栏会为 Label 选择自动样式；显式保留图标和文字，避免连接类型只显示图标。
                .labelStyle(.titleAndIcon)
            }
            // 名称、序列号和连接状态共用完整文字区域，优先于装饰图标获取横向空间。
            .layoutPriority(1)
        }
        // 使用内容理想高度保持紧凑布局；新增行被裁切的问题由列表滚动锚点修正处理。
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// ADB 配置表单使用原生 sheet；路径只读展示，选择行为委托给模型的文件面板。
@MainActor
private struct ADBSettingsSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 27))
                    .foregroundStyle(AdbTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ADB 设置")
                        .font(.title2.weight(.semibold))
                    Text("使用本机 Android SDK 中的 ADB。")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("可执行文件")
                    .font(.callout.weight(.medium))
                Text(model.adbPath.isEmpty ? "尚未找到 ADB" : model.adbPath)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(model.adbPath.isEmpty ? Color.orange : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                Button("选择 ADB…") { model.chooseADB() }
                    .disabled(model.isPerformingAction)
                    .accessibilityIdentifier("chooseADB")
            }

            Text("安装 Android SDK Platform-Tools 后，ADB 通常位于 Android SDK 的 platform-tools 文件夹。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 520)
    }
}
