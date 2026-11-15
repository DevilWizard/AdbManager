import AdbManagerCore
import AppKit
import Foundation
import Observation

/// 窗口级状态和操作协调器；核心命令保留在独立 actor 中，界面只负责呈现。
@MainActor
@Observable
final class AppModel {
    var devices: [ManagedDevice] = []
    var selectedDeviceID: String?
    var isRefreshing = false
    var isPerformingAction = false
    var activity: [ActivityEntry] = []
    var adbPath: String
    var proxyHost: String
    var proxyPort: String
    var proxyHostCandidates: [String]
    var lastError: String?
    var statusMessage: String?

    /// 选择使用稳定物理序列号；USB 拔出后，无线连接仍归属于同一设备。
    var selectedDevice: ManagedDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    @ObservationIgnored private var service: ADBService?
    @ObservationIgnored private var coreDevices: [String: ADBDevice] = [:]
    @ObservationIgnored private var lastRefreshError: String?
    /// 更换 ADB 时递增，阻止上一可执行文件的迟到刷新覆盖新配置。
    @ObservationIgnored private var configurationRevision = 0
    @ObservationIgnored private let preferences: UserDefaults
    /// 设备列表使用独立的长期 ADB 事件订阅，详情计时器不负责扫描列表。
    @ObservationIgnored private let deviceTracker = ADBDeviceTracker()
    @ObservationIgnored private var connectionMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var isMonitoring = false
    /// 每次窗口任务独占一个代次，旧任务结束时不能取消重开窗口的新订阅。
    @ObservationIgnored private var monitoringGeneration: UUID?

    /// 只读取本机偏好和网卡信息；初始化不会修改任何手机设置。
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let savedADB = preferences.string(forKey: "adbExecutablePath")
        let executable = ADBLocator.locate(customPath: savedADB)
        adbPath = executable?.path ?? savedADB ?? ""
        service = executable.map { ADBService(executableURL: $0) }
        let addresses = LocalNetwork.ipv4Addresses()
        proxyHostCandidates = addresses
        proxyHost = preferences.string(forKey: "proxyHost") ?? addresses.first ?? ""
        proxyPort = preferences.string(forKey: "proxyPort") ?? "9090"
        // 没有正在执行的操作时不展示成功横幅，避免已连接后仍显示入门提示。
        statusMessage = executable == nil ? "请选择本机 ADB 可执行文件" : nil
    }

    /// 启动时读取列表，同时监听连接事件；每分钟任务只更新已有设备详情。
    /// 关闭窗口会同时取消事件客户端与详情等待，不遗留后台监听进程。
    func monitor() async {
        let generation = UUID()
        monitoringGeneration = generation
        isMonitoring = true
        stopConnectionMonitoring()
        defer {
            if monitoringGeneration == generation {
                monitoringGeneration = nil
                isMonitoring = false
                stopConnectionMonitoring()
            }
        }
        // 快速关闭、重开窗口时，旧任务的只读查询可能还在退出，先等待它释放。
        while isRefreshing || isPerformingAction {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
            guard monitoringGeneration == generation else { return }
        }
        await refresh()
        guard !Task.isCancelled, monitoringGeneration == generation else { return }
        startConnectionMonitoring()
        while !Task.isCancelled, monitoringGeneration == generation {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
            guard !Task.isCancelled, monitoringGeneration == generation else { return }
            await refreshDetailsOnly()
        }
    }

    /// 每个窗口生命周期和 ADB 配置只保留一个订阅，切换路径时取消旧客户端。
    private func startConnectionMonitoring() {
        stopConnectionMonitoring()
        guard isMonitoring, let generation = monitoringGeneration, let service else { return }
        let revision = configurationRevision
        let executableURL = service.executableURL
        connectionMonitorTask = Task { [weak self] in
            guard let self else { return }
            await self.watchDeviceConnections(executableURL: executableURL, revision: revision, generation: generation)
        }
    }

    /// 取消仅影响本 App 的 track-devices 客户端，不停止共享的 ADB server。
    private func stopConnectionMonitoring() {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        // 直接触达会话，任务正在处理快照而非等待 next() 时也同步结束客户端。
        deviceTracker.cancelAll()
    }

    /// AppKit 退出回调使用同步入口，不依赖 SwiftUI 任务在进程退出前完成清理。
    func prepareForApplicationTermination() {
        monitoringGeneration = nil
        isMonitoring = false
        stopConnectionMonitoring()
    }

    /// track-devices 在接入、断开和连接状态变化时推送快照；相同拓扑不刷新。
    /// 重新订阅使用退避，仅恢复事件连接，不用定时 devices 查询代替监听。
    private func watchDeviceConnections(executableURL: URL, revision: Int, generation: UUID) async {
        var retrySeconds = 1
        var reportedFailure: String?

        while !Task.isCancelled, isMonitoring, revision == configurationRevision, monitoringGeneration == generation {
            let subscriptionStarted = Date()
            var failureReason = "设备事件连接已结束。"
            do {
                let snapshots = deviceTracker.snapshots(executableURL: executableURL)
                for try await snapshot in snapshots {
                    guard !Task.isCancelled, isMonitoring, revision == configurationRevision,
                          monitoringGeneration == generation else { return }
                    if let reportedFailure, lastError == reportedFailure { lastError = nil }
                    reportedFailure = nil

                    let incoming = ADBDeviceTopology(transports: snapshot)
                    let current = ADBDeviceTopology(transports: coreDevices.values.flatMap(\.transports))
                    guard incoming != current else { continue }

                    // 写操作可能正重启 adbd；等待后重新比较，避免忽略这次连接变化。
                    while isRefreshing || isPerformingAction {
                        try await Task.sleep(for: .milliseconds(100))
                        guard isMonitoring, revision == configurationRevision,
                              monitoringGeneration == generation else { return }
                    }
                    let latest = ADBDeviceTopology(transports: coreDevices.values.flatMap(\.transports))
                    guard incoming != latest else { continue }
                    await refresh()
                }
            } catch is CancellationError {
                return
            } catch {
                failureReason = error.localizedDescription
            }
            guard !Task.isCancelled, isMonitoring, revision == configurationRevision,
                  monitoringGeneration == generation else { return }

            let message = "设备连接监听中断，将自动重连，也可手动刷新。\(failureReason)"
            if reportedFailure != message {
                appendActivity(message, isError: true)
                lastError = message
                reportedFailure = message
            }
            // 正常工作一段时间后恢复较短重连间隔，连续失败时最多等待 15 秒。
            if Date().timeIntervalSince(subscriptionStarted) > 30 { retrySeconds = 1 }
            do { try await Task.sleep(for: .seconds(retrySeconds)) }
            catch { return }
            retrySeconds = min(retrySeconds * 2, 15)
        }
    }

    /// 启动、连接事件、手动刷新及写操作完成后，主动更新列表和详情。
    func refresh() async {
        await refreshDevices()
    }

    /// 完整刷新只由明确的列表更新事件触发，不由周期任务调用。
    /// 读取不与写操作交叉提交结果，防止旧代理状态覆盖刚完成的操作。
    private func refreshDevices() async {
        guard !isRefreshing, !isPerformingAction else { return }
        guard let service else {
            reportRefreshFailure("未找到 ADB。请点击“选择 ADB”并选择 Android SDK 中的 platform-tools/adb。")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let revision = configurationRevision

        do {
            let current = try await service.devices()
            guard !Task.isCancelled, !isPerformingAction, revision == configurationRevision else { return }

            let previous = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
            let details = await readDetails(for: current, using: service)
            guard !Task.isCancelled, !isPerformingAction, revision == configurationRevision else { return }

            coreDevices = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            devices = current.map { ManagedDevice(device: $0, previous: previous[$0.id], details: details[$0.id]) }
                .sorted { left, right in
                    if left.isAuthorized != right.isAuthorized { return left.isAuthorized }
                    return left.name.localizedStandardCompare(right.name) == .orderedAscending
                }
            if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = devices.first?.id
            }
            proxyHostCandidates = LocalNetwork.ipv4Addresses()
            if proxyHost.isEmpty { proxyHost = proxyHostCandidates.first ?? "" }
            if let lastRefreshError, lastError == lastRefreshError { lastError = nil }
            lastRefreshError = nil
        } catch is CancellationError {
            // 窗口关闭取消刷新属于正常生命周期，不显示为设备故障。
        } catch {
            guard !Task.isCancelled, revision == configurationRevision else { return }
            reportRefreshFailure(error.localizedDescription)
        }
    }

    /// 每分钟只查询列表中已有且已授权的设备，不执行 adb devices，
    /// 因此不会自动新增、移除、重排设备或改变选中项。
    private func refreshDetailsOnly() async {
        guard !isRefreshing, !isPerformingAction, let service else { return }
        let knownDevices = devices.compactMap { coreDevices[$0.id] }
            .filter { $0.state == .device }
        guard !knownDevices.isEmpty else { return }

        isRefreshing = true
        defer { isRefreshing = false }
        let revision = configurationRevision
        let details = await readDetails(for: knownDevices, using: service)
        guard !Task.isCancelled, !isPerformingAction, revision == configurationRevision else { return }

        // 以当前列表为基准合并详情，避免周期刷新变成隐式的设备列表扫描。
        devices = devices.map { previous in
            guard let device = coreDevices[previous.id], let detail = details[previous.id] else {
                return previous
            }
            return ManagedDevice(device: device, previous: previous, details: detail)
        }
        proxyHostCandidates = LocalNetwork.ipv4Addresses()
    }

    /// 共用详情查询，保证完整刷新与每分钟刷新使用相同的字段和错误处理。
    /// 单台设备读取失败时保留上次详情，不影响其他设备成功更新。
    private func readDetails(for current: [ADBDevice], using service: ADBService) async -> [String: DeviceDetails] {
        await withTaskGroup(of: (String, DeviceDetails?).self) { group in
            for device in current where device.state == .device {
                group.addTask {
                    (device.id, try? await service.details(for: device))
                }
            }
            var snapshots: [String: DeviceDetails] = [:]
            for await (id, value) in group {
                if let value { snapshots[id] = value }
            }
            return snapshots
        }
    }

    /// 一键无线只针对当前选中设备；底层会核对连接后的物理序列号。
    func enableWireless() async {
        await performAction(title: "启用无线连接") { service, device in
            let connection = try await service.enableWireless(for: device)
            return "\(device.name) 已通过 \(connection.endpoint) 连接，可拔掉 USB 线。"
        }
    }

    /// 先校验编辑内容，再写入选中手机，失败时保持已有代理显示不变。
    func applyProxy() async {
        let configuration: ProxyConfiguration
        do {
            guard let port = Int(proxyPort.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw InputError.invalidPort
            }
            configuration = try ProxyConfiguration(host: proxyHost, port: port)
        } catch {
            presentError(error.localizedDescription)
            return
        }
        await performAction(title: "设置代理") { service, device in
            try await service.setProxy(configuration, for: device)
            return "\(device.name) 的代理已设置为 \(configuration.description)。"
        }
        // 仅保存编辑偏好，不保存或隐式修改其他手机的代理。
        preferences.set(proxyHost, forKey: "proxyHost")
        preferences.set(proxyPort, forKey: "proxyPort")
    }

    /// 关闭手机的全局 HTTP 代理，并通过底层回读确认结果。
    func clearProxy() async {
        await performAction(title: "关闭代理") { service, device in
            try await service.disableProxy(for: device)
            return "\(device.name) 的代理已关闭。"
        }
    }

    /// 仅断开当前设备的无线传输；存在的 USB 连接继续可用。
    func disconnectWireless() async {
        await performAction(title: "断开无线连接") { service, device in
            try await service.disconnectWireless(for: device)
            return "已断开 \(device.name) 的无线连接。"
        }
    }

    /// 用系统文件选择器选择 ADB，兼容自定义 SDK 安装目录。
    func chooseADB() {
        guard !isPerformingAction else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 ADB 可执行文件"
        panel.message = "通常位于 Android SDK 的 platform-tools 文件夹中。"
        panel.prompt = "使用此 ADB"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if !adbPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: adbPath).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let executable = ADBLocator.locate(customPath: url.path), executable.path == url.path else {
            presentError("所选文件不可执行，请选择 platform-tools 中的 adb 文件。")
            return
        }
        adbPath = executable.path
        configurationRevision += 1
        stopConnectionMonitoring()
        service = ADBService(executableURL: executable)
        preferences.set(adbPath, forKey: "adbExecutablePath")
        devices = []
        coreDevices = [:]
        selectedDeviceID = nil
        lastRefreshError = nil
        clearError()
        appendActivity("已选择 ADB：\(adbPath)")
        Task {
            // 文件选择期间可能仍有旧查询在运行，等待它退出后刷新新配置。
            while isRefreshing {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
            await refresh()
            startConnectionMonitoring()
        }
    }

    /// 允许用户关闭错误横幅；操作记录仍保留原始失败信息。
    func clearError() { lastError = nil }

    /// 所有写操作在窗口内串行；正在运行的刷新会先退出，随后才修改设备。
    private func performAction(
        title: String,
        action: @MainActor (ADBService, ADBDevice) async throws -> String
    ) async {
        guard !isPerformingAction else { return }
        guard let service, let selectedID = selectedDeviceID, let device = coreDevices[selectedID] else {
            presentError("请先选择一台已连接的设备。")
            return
        }
        isPerformingAction = true
        lastError = nil
        statusMessage = "正在\(title)…"

        // 先占用写操作状态，自动刷新将停止提交，避免新一轮读取抢在写入前面。
        while isRefreshing {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch {
                isPerformingAction = false
                return
            }
        }

        do {
            let message = try await action(service, device)
            statusMessage = message
            appendActivity(message)
        } catch is CancellationError {
            statusMessage = "操作已取消，请刷新确认设备状态。"
        } catch {
            statusMessage = "\(title)失败"
            presentError(error.localizedDescription)
        }
        isPerformingAction = false
        await refresh()
    }

    /// 自动刷新错误只在原因改变时记一次，避免设备拔出后日志不断重复。
    private func reportRefreshFailure(_ message: String) {
        if lastRefreshError != message {
            appendActivity(message, isError: true)
            lastError = message
        }
        lastRefreshError = message
    }

    /// 用户操作错误同时呈现在横幅和操作记录中。
    private func presentError(_ message: String) {
        lastError = message
        appendActivity(message, isError: true)
    }

    /// 记录只在内存保留最近 40 条，不累积无限增长的文件或 UI 列表。
    private func appendActivity(_ message: String, isError: Bool = false) {
        activity.insert(ActivityEntry(message: message, isError: isError), at: 0)
        if activity.count > 40 { activity.removeLast(activity.count - 40) }
    }
}

/// 编辑框的格式错误与设备执行错误分离，便于后续复用输入校验。
private enum InputError: LocalizedError {
    case invalidPort
    var errorDescription: String? { "端口请输入 1–65535 之间的整数。" }
}
