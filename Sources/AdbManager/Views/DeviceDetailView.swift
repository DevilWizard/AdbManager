import SwiftUI

/// 当前设备的功能面板；设备信息、无线连接、代理和操作记录保持清晰的阅读顺序。
@MainActor
struct DeviceDetailView: View {
    @Bindable var model: AppModel
    let device: ManagedDevice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                deviceHeader

                if model.isPerformingAction || model.statusMessage != nil {
                    operationStatus
                }

                if !device.isAuthorized {
                    authorizationNotice
                }

                WirelessSettingsCard(model: model, device: device)
                ProxySettingsCard(model: model, device: device)
                activityCard
            }
            .padding(28)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 设备标题呈现物理序列号和连接方式，USB 与 Wi-Fi 不重复占用设备条目。
    private var deviceHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            DeviceBrandLogo(brand: device.brand, size: 78)
                // 品牌名已在下方文字呈现；详情中的图形仅作视觉区分，避免旁白重复朗读。
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(device.name)
                    .font(.system(size: 25, weight: .semibold))
                    .textSelection(.enabled)

                HStack(spacing: 7) {
                    Text(device.serial)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    if device.brand != .android {
                        Text("·")
                        Text(device.brand.displayName)
                            .font(.caption)
                    }
                    if let version = device.androidVersion, !version.isEmpty {
                        Text("·")
                        Text("Android \(version)")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 7) {
                    if device.hasUSB {
                        ConnectionBadge(title: "USB", symbol: "cable.connector", isActive: device.isAuthorized)
                    }
                    if device.hasWireless {
                        ConnectionBadge(title: "无线", symbol: "wifi", isActive: device.isAuthorized)
                    }
                    if !device.isAuthorized {
                        ConnectionBadge(title: device.statusTitle, symbol: "exclamationmark.circle", isActive: false)
                    }
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.bottom, 3)
    }

    /// 正在进行的命令使用同一条进度提示；完成结果保留，便于确认按钮是否真正生效。
    private var operationStatus: some View {
        HStack(spacing: 10) {
            if model.isPerformingAction {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AdbTheme.accent)
            }
            Text(model.statusMessage ?? "正在处理，请稍候…")
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(AdbTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("operationStatus")
    }

    /// 未授权与离线状态都禁止写操作，并提示用户先恢复可用的设备连接。
    private var authorizationNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.statusTitle)
                    .font(.callout.weight(.medium))
                Text("请解锁手机并允许 USB 调试；若设备离线，请重新连接 USB 后刷新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 最近操作仅展示必要结果和时间，详细错误通过可选中的文本保留给用户排查。
    private var activityCard: some View {
        FeatureCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("最近操作", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Spacer()
                    Text("最近 \(min(model.activity.count, 6)) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.activity.isEmpty {
                    Text("完成无线连接或代理设置后，操作结果会显示在这里。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 5)
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(model.activity.prefix(6))) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: entry.isError ? "exclamationmark.circle" : "checkmark.circle")
                                    .foregroundStyle(entry.isError ? Color.orange : AdbTheme.accent)
                                    .padding(.top, 1)
                                Text(entry.message)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// USB 初始化方式的无线连接卡；端口与安全边界在触发操作前清楚说明。
@MainActor
private struct WirelessSettingsCard: View {
    @Bindable var model: AppModel
    let device: ManagedDevice

    var body: some View {
        FeatureCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    FeatureIcon(symbol: "wifi", color: AdbTheme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("无线连接")
                            .font(.headline)
                        Text("插线设置，拔线继续调试")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device.hasWireless {
                        ConnectionBadge(title: "已连接", symbol: "checkmark", isActive: true)
                    }
                }

                HStack(spacing: 0) {
                    WirelessStep(number: "1", title: "连接 USB")
                    stepConnector
                    WirelessStep(number: "2", title: "一键设置")
                    stepConnector
                    WirelessStep(number: "3", title: "拔线使用")
                }
                .padding(.vertical, 2)

                if let address = device.ipAddress, !address.isEmpty {
                    HStack(spacing: 8) {
                        Text("设备 IP")
                            .foregroundStyle(.secondary)
                        Text(address)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                }

                Text(guidance)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(alignment: .center, spacing: 12) {
                    Button {
                        Task { await model.enableWireless() }
                    } label: {
                        Label("一键设置无线", systemImage: "wifi")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!device.hasUSB || !device.isAuthorized || model.isPerformingAction)
                    .accessibilityIdentifier("enableWireless")

                    if device.hasWireless {
                        Button("断开无线") {
                            Task { await model.disconnectWireless() }
                        }
                        .disabled(model.isPerformingAction)
                        .accessibilityIdentifier("disconnectWireless")
                    }
                    Spacer(minLength: 0)
                }

                Divider()
                Text("通过 USB 授权启用传统 TCP 连接；调试流量不加密，仅在可信网络使用。端口 5555。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 流程连接线只作为装饰，语义由三个带编号的步骤提供。
    private var stepConnector: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(height: 1)
            .frame(maxWidth: 60)
            .padding(.horizontal, 12)
            .accessibilityHidden(true)
    }

    /// 说明跟随连接条件变化，避免仅有无线连接时仍诱导用户点击需要 USB 的按钮。
    private var guidance: String {
        if !device.isAuthorized {
            return "请先在手机上允许 USB 调试，再设置无线连接。"
        }
        if !device.hasUSB {
            return device.hasWireless
                ? "当前已可无线调试。需要重新设置时，请先插入 USB。"
                : "请先用 USB 连接这台设备，再一键建立无线连接。"
        }
        return "自动读取设备地址、建立并验证无线连接，成功后即可拔掉 USB。"
    }
}

/// 系统 HTTP 代理配置卡：编辑值与设备现值分开展示，避免尚未应用的输入被误认为已生效。
@MainActor
private struct ProxySettingsCard: View {
    @Bindable var model: AppModel
    let device: ManagedDevice

    var body: some View {
        FeatureCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    FeatureIcon(symbol: "network", color: .blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("抓包代理")
                            .font(.headline)
                        Text("将设备流量发送到 Mac 上的 Proxyman")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("当前设备代理")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(device.proxyDescription ?? "尚未读取")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                .font(.callout)
                .padding(12)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("代理主机")
                                .font(.callout.weight(.medium))
                            Spacer()
                            if !model.proxyHostCandidates.isEmpty {
                                Menu {
                                    ForEach(model.proxyHostCandidates, id: \.self) { address in
                                        Button(address) { model.proxyHost = address }
                                    }
                                } label: {
                                    Label("本机地址", systemImage: "desktopcomputer")
                                        .font(.caption)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .disabled(model.isPerformingAction)
                            }
                        }

                        TextField("Mac 的局域网 IP 或主机名", text: $model.proxyHost)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("代理主机地址")
                            .accessibilityIdentifier("proxyHost")
                            .disabled(model.isPerformingAction || !device.isAuthorized)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("端口")
                            .font(.callout.weight(.medium))
                            .frame(height: 16)
                        TextField("9090", text: $model.proxyPort)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("代理端口")
                            .accessibilityIdentifier("proxyPort")
                            .disabled(model.isPerformingAction || !device.isAuthorized)
                    }
                    .frame(width: 94)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await model.applyProxy() }
                    } label: {
                        Label("应用代理", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canApplyProxy)
                    .accessibilityIdentifier("applyProxy")

                    Button("关闭代理") {
                        Task { await model.clearProxy() }
                    }
                    .disabled(!device.isAuthorized || model.isPerformingAction)
                    .accessibilityIdentifier("clearProxy")
                    Spacer(minLength: 0)
                    Text("默认 9090，可自定义")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("HTTPS 抓包需在手机安装并信任 Proxyman 证书，目标应用也需允许使用该证书。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("查看 Android HTTPS 抓包配置", destination: URL(string: "https://proxyman.com/docs/debug-devices/android-device")!)
                            .font(.caption)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 空值直接禁用按钮；格式、端口范围和目标可达性由模型统一验证并给出明确错误。
    private var canApplyProxy: Bool {
        device.isAuthorized
            && !model.isPerformingAction
            && !model.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.proxyPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 卡片标题图标使用轻量色块，帮助快速区分无线连接与代理配置。
private struct FeatureIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 42, height: 42)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }
}

/// 无线设置步骤以编号加文字表达，既能快速扫读，也不会依赖单一颜色识别状态。
private struct WirelessStep: View {
    let number: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(AdbTheme.accent)
                .frame(width: 23, height: 23)
                .background(AdbTheme.accent.opacity(0.1), in: Circle())
            Text(title)
                .font(.callout)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
