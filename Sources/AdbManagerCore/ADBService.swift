import Foundation

/// 设备操作边界。Actor 保护传输到物理设备的身份缓存，所有 adb 命令均显式指定目标。
public actor ADBService {
    public nonisolated let executableURL: URL
    private let runner: any ADBCommandRunning
    /// 地址可能在一次刷新中临时离线；保留身份能避免列表出现同一手机的重复项。
    private var identities: [String: String] = [:]

    public init(executableURL: URL, runner: any ADBCommandRunning = ProcessCommandRunner()) {
        self.executableURL = executableURL
        self.runner = runner
    }

    /// 单条无线传输的身份查询失败不会影响其他设备，也不会把未知身份猜测成另一台手机。
    public func devices() async throws -> [ADBDevice] {
        let output = try await command(["devices", "-l"])
        let transports = ADBOutputParser.transports(from: output)
        var groups: [String: [ADBTransport]] = [:]
        for transport in transports {
            try Task.checkCancellation()
            // 在线端点可能已被 DHCP 分配给另一台手机。只有离线记录可以沿用历史身份；
            // 在线身份读取失败时必须单独显示端点，不能凭旧缓存把它归到另一台设备。
            var identity = transport.serial
            if transport.kind == .wireless && transport.state == .offline {
                identity = identities[transport.serial] ?? transport.serial
            }
            if transport.kind == .usb {
                identity = transport.serial
            } else if transport.kind == .wireless && transport.state == .device {
                if let value = try? await readPhysicalSerial(transport: transport), Self.isUsableSerial(value) {
                    identity = value
                }
            }
            identities[transport.serial] = identity
            groups[identity, default: []].append(transport)
        }
        return groups.map { ADBDevice(serial: $0.key, transports: $0.value) }
            .sorted { left, right in
                if left.state == .device && right.state != .device { return true }
                if left.state != .device && right.state == .device { return false }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    /// 展示字段分别读取；缺失某个厂商属性不会让整页失败。
    public func details(for device: ADBDevice) async throws -> DeviceDetails {
        let transport = try await connectedTransport(for: device)
        async let version = optionalProperty("ro.build.version.release", transport: transport)
        async let level = optionalProperty("ro.build.version.sdk", transport: transport)
        // 品牌随现有详情刷新读取，使用同一条已验证传输；单个属性失败仅影响该属性。
        async let productBrand = optionalProperty("ro.product.brand", transport: transport)
        async let manufacturer = optionalProperty("ro.product.manufacturer", transport: transport)
        async let address = optionalWiFiAddress(transport: transport)
        let proxyConfiguration: ProxyConfiguration?
        let proxyError: String?
        do {
            // 详情内所有字段使用同一条已探测传输，避免再次选到已经失效的 USB。
            proxyConfiguration = try await proxy(using: transport)
            proxyError = nil
        } catch {
            proxyConfiguration = nil
            proxyError = error.localizedDescription
        }
        return await DeviceDetails(androidVersion: version, apiLevel: level, ipAddress: address,
                                   proxy: proxyConfiguration, proxyReadError: proxyError,
                                   productBrand: productBrand, manufacturer: manufacturer)
    }

    /// 官方 USB 初始化无线流程：读取 WLAN 地址，开启 TCP，连接后核对身份，再返回成功。
    /// 此操作启用传统 TCP 模式，并不是 Android 11+ 的 TLS 配对，应仅用于可信局域网。
    public func enableWireless(for device: ADBDevice, port: Int = 5555) async throws -> WirelessConnectionResult {
        guard (1...65535).contains(port) else { throw ADBError.invalidPort }
        guard let usb = device.usbTransport else { throw ADBError.noUSBConnection }
        try validate(usb)
        guard try await isAvailable(usb) else { throw ADBError.noUSBConnection }
        let physicalSerial = try await readPhysicalSerial(transport: usb)
        guard Self.isUsableSerial(physicalSerial) else {
            throw ADBError.wirelessVerificationFailed("无法读取 USB 设备的物理序列号，已停止操作。")
        }
        guard let address = await optionalWiFiAddress(transport: usb) else { throw ADBError.noWiFiAddress }
        let endpoint = "\(address):\(port)"
        _ = try await command(targeting: usb, arguments: ["tcpip", String(port)], timeout: 12)

        var lastFailure = "设备没有响应。"
        // adbd 重启时 USB 会短暂断开。重试仅针对刚刚读到的单个端点，不扫描局域网。
        for attempt in 0..<4 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(600_000_000 + attempt * 300_000_000))
            do {
                let response = try await command(["connect", endpoint], timeout: 8)
                guard response.contains("connected to \(endpoint)") else {
                    lastFailure = response.isEmpty ? "ADB 没有确认连接成功。" : response
                    continue
                }
                let wireless = ADBTransport(serial: endpoint, kind: .wireless, state: .device)
                let actualSerial = try await readPhysicalSerial(transport: wireless)
                guard actualSerial == physicalSerial else {
                    // DHCP 地址变化或错误端点不能伪装成成功；立即断开本次新连接。
                    _ = try? await command(["disconnect", endpoint], timeout: 5)
                    throw ADBError.wirelessVerificationFailed("目标身份与 USB 设备不一致，已断开本次连接。")
                }
                let state = try await command(targeting: wireless, arguments: ["get-state"], timeout: 5)
                guard state.trimmingCharacters(in: .whitespacesAndNewlines) == "device" else {
                    lastFailure = "无线端点当前状态为 \(state)。"
                    continue
                }
                identities[endpoint] = physicalSerial
                return WirelessConnectionResult(address: address, port: port, physicalSerial: physicalSerial)
            } catch let error as ADBError {
                if case .wirelessVerificationFailed = error { throw error }
                if case .cancelled = error { throw error }
                lastFailure = error.localizedDescription
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = error.localizedDescription
            }
        }
        throw ADBError.wirelessVerificationFailed("\(lastFailure) 请确认 Mac 与手机的 Wi-Fi 可以互通；网络隔离无法由 App 自动解除。TCP 监听可能已经开启，可插线后重试。")
    }

    /// 仅断开所选手机的无线传输，不执行全局 adb disconnect，其他设备不受影响。
    public func disconnectWireless(for device: ADBDevice) async throws {
        let wireless = device.transports.filter { $0.kind == .wireless && $0.state == .device }
        var disconnected = false
        for transport in wireless {
            guard try await isAvailable(transport) else { continue }
            // 缓存地址可能已被 DHCP 复用。即使目标能够响应，也只能断开仍属于所选手机的连接。
            guard let actualSerial = try? await readPhysicalSerial(transport: transport),
                  actualSerial == device.serial else { continue }
            _ = try await command(["disconnect", transport.serial], timeout: 8)
            disconnected = true
        }
        guard disconnected else { throw ADBError.noUsableConnection }
    }

    /// 读取 Android 全局代理，nil 表示已关闭。异常值会明确报错而不是伪装成未配置。
    public func proxy(for device: ADBDevice) async throws -> ProxyConfiguration? {
        let transport = try await connectedTransport(for: device)
        return try await proxy(using: transport)
    }

    /// 全部参数都以独立参数传给 Process；host 还经过严格格式校验，避免远端 shell 元字符。
    public func setProxy(_ configuration: ProxyConfiguration, for device: ADBDevice) async throws {
        let transport = try await connectedTransport(for: device)
        _ = try await command(targeting: transport, arguments: ["shell", "settings", "put", "global", "http_proxy", configuration.description])
        let actual = try await command(targeting: transport, arguments: ["shell", "settings", "get", "global", "http_proxy"])
        guard try ProxyConfiguration.parse(actual) == configuration else {
            throw ADBError.proxyVerificationFailed(expected: configuration.description, actual: actual)
        }
    }

    /// :0 是 Android 常用的关闭代理表示；写入后必须读取校验，避免界面误报成功。
    public func disableProxy(for device: ADBDevice) async throws {
        let transport = try await connectedTransport(for: device)
        _ = try await command(targeting: transport, arguments: ["shell", "settings", "put", "global", "http_proxy", ":0"])
        let actual = try await command(targeting: transport, arguments: ["shell", "settings", "get", "global", "http_proxy"])
        guard try ProxyConfiguration.parse(actual) == nil else {
            throw ADBError.proxyVerificationFailed(expected: "关闭（:0）", actual: actual)
        }
    }

    /// 获取 Wi-Fi 地址失败时回退到路由表；始终忽略蜂窝和 VPN 接口。
    private func optionalWiFiAddress(transport: ADBTransport) async -> String? {
        if let value = try? await command(targeting: transport, arguments: ["shell", "ip", "-o", "-4", "addr", "show"], timeout: 6),
           let address = ADBOutputParser.wiFiIPv4(from: value) {
            return address
        }
        if let routes = try? await command(targeting: transport, arguments: ["shell", "ip", "route"], timeout: 6) {
            return ADBOutputParser.wiFiIPv4FromRoutes(routes)
        }
        return nil
    }

    private func optionalProperty(_ key: String, transport: ADBTransport) async -> String? {
        guard let output = try? await command(targeting: transport, arguments: ["shell", "getprop", key], timeout: 6),
              !output.isEmpty else { return nil }
        return output
    }

    /// 不凭型号或设备名称合并；只有设备返回的稳定序列号才可以作为物理身份。
    private func readPhysicalSerial(transport: ADBTransport) async throws -> String {
        let primary = try await command(targeting: transport, arguments: ["shell", "getprop", "ro.serialno"], timeout: 5)
        if Self.isUsableSerial(primary) { return primary }
        return try await command(targeting: transport, arguments: ["shell", "getprop", "ro.boot.serialno"], timeout: 5)
    }

    private static func isUsableSerial(_ serial: String) -> Bool {
        !serial.isEmpty && !["unknown", "null"].contains(serial.lowercased()) && !serial.contains(where: \.isWhitespace)
    }

    /// 仅探测这一台手机已有的已连接传输，不扫描设备、不改变列表。
    /// USB 拔线后可以回退到之前已验证归并的无线连接；过期 transport_id 不能降级成同 IP 的 -s。
    private func connectedTransport(for device: ADBDevice) async throws -> ADBTransport {
        let candidates = device.transports.filter { $0.state == .device }.sorted {
            func priority(_ transport: ADBTransport) -> Int {
                switch transport.kind {
                case .usb: return 0
                case .wireless: return 1
                case .other: return 2
                }
            }
            return priority($0) < priority($1)
        }
        for transport in candidates {
            guard try await isAvailable(transport) else { continue }
            if transport.kind == .wireless {
                // 无线地址即使仍有响应，也可能已属于另一台手机；回退前再次核对稳定身份。
                let actualSerial = try? await readPhysicalSerial(transport: transport)
                try Task.checkCancellation()
                guard actualSerial == device.serial else { continue }
            }
            return transport
        }
        if candidates.isEmpty, let transport = device.preferredTransport { try validate(transport) }
        throw ADBError.noUsableConnection
    }

    /// 查询当前传输是否仍存活。探测失败只允许尝试同一设备的另一已知传输。
    private func isAvailable(_ transport: ADBTransport) async throws -> Bool {
        try Task.checkCancellation()
        do {
            return try await command(targeting: transport, arguments: ["get-state"], timeout: 3) == "device"
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ADBError where error == .cancelled {
            throw error
        } catch {
            try Task.checkCancellation()
            return false
        }
    }

    /// 私有读取接口供详情复用已探测的目标，避免在一次详情读取中反复探测失效 USB。
    private func proxy(using transport: ADBTransport) async throws -> ProxyConfiguration? {
        let rawValue = try await command(targeting: transport, arguments: ["shell", "settings", "get", "global", "http_proxy"])
        return try ProxyConfiguration.parse(rawValue)
    }

    private func validate(_ transport: ADBTransport) throws {
        switch transport.state {
        case .device: return
        case .unauthorized: throw ADBError.unauthorized
        case .offline: throw ADBError.offline
        case .unknown: throw ADBError.noUsableConnection
        }
    }

    private func command(targeting transport: ADBTransport, arguments: [String], timeout: TimeInterval = 10) async throws -> String {
        // transport_id 属于当前 ADB Server 会话，不会因为 DHCP 地址被复用而自动指向别的手机。
        // 已记录 ID 的传输失效时应明确失败，不能悄悄回退 -s 再命中新的同地址设备。
        if let identifier = transport.transportID, UInt64(identifier) != nil {
            return try await command(["-t", identifier] + arguments, timeout: timeout)
        }
        return try await command(["-s", transport.serial] + arguments, timeout: timeout)
    }

    /// adb connect 某些失败会以退出码 0 返回；连接流程另外验证文本、状态和设备身份。
    private func command(_ arguments: [String], timeout: TimeInterval = 10) async throws -> String {
        try Task.checkCancellation()
        let result = try await runner.run(executable: executableURL, arguments: arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            let summary = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ADBError.commandFailed(String(summary.prefix(1400)))
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
