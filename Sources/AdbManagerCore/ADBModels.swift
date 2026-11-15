import Foundation

/// ADB 传输状态。未知状态保留原始值，便于兼容后续 Platform Tools 版本。
public enum ADBDeviceState: Equatable, Sendable {
    case device
    case offline
    case unauthorized
    case unknown(String)

    /// 面向界面的中文说明；业务判断应使用枚举值，避免依赖文案。
    public var title: String {
        switch self {
        case .device: return "已连接"
        case .offline: return "离线"
        case .unauthorized: return "待授权"
        case .unknown(let value): return value.isEmpty ? "未知状态" : value
        }
    }

    /// 统一解析 adb devices 的状态字段。
    public init(rawValue: String) {
        switch rawValue {
        case "device": self = .device
        case "offline": self = .offline
        case "unauthorized": self = .unauthorized
        default: self = .unknown(rawValue)
        }
    }
}

/// 描述同一设备连接到 ADB Server 的方式；模拟器归入 other，不能执行 USB 初始化。
public enum ADBConnectionKind: String, Sendable {
    case usb
    case wireless
    case other

    public var title: String {
        switch self {
        case .usb: return "USB"
        case .wireless: return "无线"
        case .other: return "其他"
        }
    }
}

/// 一条独立的 ADB 传输。serial 既可能是 USB 序列号，也可能是 IP:端口。
public struct ADBTransport: Identifiable, Equatable, Sendable {
    public let serial: String
    public let kind: ADBConnectionKind
    public let state: ADBDeviceState
    public let model: String?
    public let product: String?
    public let transportID: String?
    public var id: String { serial }

    public init(serial: String, kind: ADBConnectionKind, state: ADBDeviceState,
                model: String? = nil, product: String? = nil, transportID: String? = nil) {
        self.serial = serial
        self.kind = kind
        self.state = state
        self.model = model
        self.product = product
        self.transportID = transportID
    }
}

/// 物理设备聚合模型。无线传输读取 ro.serialno 后，与 USB 传输归并到相同 serial。
public struct ADBDevice: Identifiable, Equatable, Sendable {
    public let serial: String
    public let transports: [ADBTransport]
    public var id: String { serial }

    public init(serial: String, transports: [ADBTransport]) {
        self.serial = serial
        self.transports = transports
    }

    public var model: String? {
        preferredTransport?.model ?? transports.compactMap(\.model).first
    }

    public var name: String {
        model?.replacingOccurrences(of: "_", with: " ") ?? serial
    }

    /// 优先选择可用的 USB 传输，避免无线重启时影响正在执行的设备命令。
    public var preferredTransport: ADBTransport? {
        transports.first { $0.kind == .usb && $0.state == .device }
            ?? transports.first { $0.state == .device }
            ?? transports.first
    }

    public var usbTransport: ADBTransport? {
        transports.first { $0.kind == .usb && $0.state == .device }
            ?? transports.first { $0.kind == .usb }
    }

    public var wirelessTransport: ADBTransport? {
        transports.first { $0.kind == .wireless && $0.state == .device }
            ?? transports.first { $0.kind == .wireless }
    }

    /// 同一设备只要存在一条可用传输，就应显示已连接，而不是被失效的旧端点覆盖。
    public var state: ADBDeviceState {
        if transports.contains(where: { $0.state == .device }) { return .device }
        if transports.contains(where: { $0.state == .unauthorized }) { return .unauthorized }
        if transports.contains(where: { $0.state == .offline }) { return .offline }
        return transports.first?.state ?? .unknown("")
    }
}

/// 设备详情按需加载，避免自动刷新列表时频繁唤醒手机。
public struct DeviceDetails: Equatable, Sendable {
    public let androidVersion: String?
    public let apiLevel: String?
    public let ipAddress: String?
    public let proxy: ProxyConfiguration?
    public let proxyReadError: String?
    /// 产品品牌与制造商分别保留；OEM 生产的手机不一定使用制造商的消费品牌。
    public let productBrand: String?
    public let manufacturer: String?

    /// 在所有界面共用同一套优先级和别名规则，不从名称、IP 或连接方式推断品牌。
    public var brand: DeviceBrand {
        DeviceBrand.resolve(productBrand: productBrand, manufacturer: manufacturer)
    }

    public init(androidVersion: String? = nil, apiLevel: String? = nil,
                ipAddress: String? = nil, proxy: ProxyConfiguration? = nil,
                proxyReadError: String? = nil, productBrand: String? = nil,
                manufacturer: String? = nil) {
        self.androidVersion = androidVersion
        self.apiLevel = apiLevel
        self.ipAddress = ipAddress
        self.proxy = proxy
        self.proxyReadError = proxyReadError
        self.productBrand = productBrand
        self.manufacturer = manufacturer
    }
}

/// Android 全局 HTTP 代理。初始化即校验，确保传给 adb shell 的值不含 shell 元字符。
public struct ProxyConfiguration: Equatable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: Int
    public var description: String { "\(host):\(port)" }

    public init(host: String, port: Int = 9090) throws {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...65535).contains(port) else { throw ADBError.invalidPort }
        guard !normalized.isEmpty else { throw ADBError.invalidHost("请输入 Mac 的局域网 IP 或主机名。") }
        guard !normalized.contains(":") else {
            throw ADBError.invalidHost("当前版本仅支持 IPv4 或 DNS 主机名，请勿填写协议、端口或 IPv6 地址。")
        }
        guard Self.isValidHost(normalized) else {
            throw ADBError.invalidHost("主机格式不正确，请只填写 IPv4 或 DNS 主机名，不要包含协议、路径或空格。")
        }
        self.host = normalized
        self.port = port
    }

    /// 解析 Android settings 的值。关闭状态采用 nil，避免界面把 :0 误判为有效代理。
    public static func parse(_ rawValue: String) throws -> ProxyConfiguration? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["", "null", ":0", ":-1", "0.0.0.0:0"].contains(value) { return nil }
        guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else {
            throw ADBError.invalidHost("设备返回了无法识别的代理配置：\(value)")
        }
        return try ProxyConfiguration(host: String(value[..<colon]), port: port)
    }

    /// IPv4 严格校验每一段，DNS 则限制为 ASCII 标签，避免注入 adb shell 的拼接参数。
    private static func isValidHost(_ host: String) -> Bool {
        guard host.utf8.count <= 253, host.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return labels.count == 4 && labels.allSatisfy { label in
                !label.isEmpty && label.count <= 3 && Int(label).map { (0...255).contains($0) } == true
            }
        }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  label.first?.isLetter == true || label.first?.isNumber == true,
                  label.last?.isLetter == true || label.last?.isNumber == true else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

/// 一键无线使用官方 USB 初始化 TCP 流程，与 Android 11+ TLS 配对模式明确分开。
public enum WirelessConnectionMode: String, Sendable {
    case legacyTCP
}

/// 只有已验证目标身份与无线 shell 可用，才会返回该成功结果。
public struct WirelessConnectionResult: Equatable, Sendable {
    public let address: String
    public let port: Int
    public let physicalSerial: String
    public let mode: WirelessConnectionMode
    public var endpoint: String { "\(address):\(port)" }

    public init(address: String, port: Int, physicalSerial: String, mode: WirelessConnectionMode = .legacyTCP) {
        self.address = address
        self.port = port
        self.physicalSerial = physicalSerial
        self.mode = mode
    }
}

/// 核心错误统一提供中文解释，界面无需分析原始 adb 文本来决定错误类型。
public enum ADBError: LocalizedError, Equatable, Sendable {
    case adbNotFound
    case commandFailed(String)
    case commandTimedOut(TimeInterval)
    case cancelled
    case noUSBConnection
    case unauthorized
    case offline
    case noUsableConnection
    case noWiFiAddress
    case invalidHost(String)
    case invalidPort
    case wirelessVerificationFailed(String)
    case proxyVerificationFailed(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .adbNotFound: return "未找到可执行的 adb。请在设置中选择 Android SDK 的 platform-tools/adb。"
        case .commandFailed(let message): return "ADB 操作失败：\(message)"
        case .commandTimedOut(let seconds): return "ADB 操作超过 \(Int(seconds)) 秒。请检查设备与网络后重试。"
        case .cancelled: return "操作已取消。"
        case .noUSBConnection: return "请先通过 USB 连接这台设备，再启用一键无线。"
        case .unauthorized: return "请解锁手机，并在手机上允许这台 Mac 进行 USB 调试。"
        case .offline: return "设备离线，请重新插线或检查无线网络后重试。"
        case .noUsableConnection: return "当前设备没有可用的 ADB 连接。"
        case .noWiFiAddress: return "未读到设备的 WLAN IPv4 地址。请先让手机与 Mac 连接同一个可互通的 Wi-Fi。"
        case .invalidHost(let message): return message
        case .invalidPort: return "端口必须是 1 到 65535 之间的整数。"
        case .wirelessVerificationFailed(let message): return "无线连接未通过验证：\(message)"
        case .proxyVerificationFailed(let expected, let actual):
            return "代理写入后校验失败。预期：\(expected)，设备实际返回：\(actual)。"
        }
    }
}
