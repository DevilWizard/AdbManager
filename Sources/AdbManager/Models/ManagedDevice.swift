import Foundation
import AdbManagerCore

/// 界面使用的连接种类；显示层不直接依赖底层 ADB 输出的拼写。
enum TransportKind {
    case usb
    case wireless
    case other
}

/// ADB 连接状态的展示模型，保留未知状态，避免把异常误判为在线。
enum TransportState {
    case device
    case offline
    case unauthorized
    case unknown
}

/// 同一台手机可能同时存在 USB 和无线连接，每条连接单独保留其状态。
struct DeviceTransport: Identifiable {
    let id: String
    let kind: TransportKind
    let state: TransportState
    let address: String
}

/// 按手机物理序列号归并的界面模型，刷新时保留已经读到的设备详情。
struct ManagedDevice: Identifiable {
    let id: String
    let name: String
    let serial: String
    var androidVersion: String?
    /// 只根据手机报告的产品品牌和厂商识别，USB 与无线连接共用同一个物理设备品牌。
    var brand: DeviceBrand
    let transports: [DeviceTransport]
    var ipAddress: String?
    var proxyDescription: String?

    /// 至少存在一条已经授权且在线的连接，才能读取或修改设备设置。
    var isAuthorized: Bool { transports.contains { $0.state == .device } }

    /// USB 和无线标记反映在线连接，离线的旧条目不算可用连接。
    var hasUSB: Bool { transports.contains { $0.kind == .usb && $0.state == .device } }
    var hasWireless: Bool { transports.contains { $0.kind == .wireless && $0.state == .device } }

    /// 未授权的设备应明确提示确认手机，而不是笼统显示“离线”。
    var statusTitle: String {
        if isAuthorized { return "已连接" }
        if transports.contains(where: { $0.state == .unauthorized }) { return "等待授权" }
        if transports.contains(where: { $0.state == .offline }) { return "设备离线" }
        return "连接不可用"
    }

    /// 列表中的简短连接摘要，避免同一台手机出现两张独立设备卡片。
    var connectionSummary: String {
        if hasUSB && hasWireless { return "USB + 无线" }
        if hasUSB { return "USB 已连接" }
        if hasWireless { return "无线已连接" }
        return statusTitle
    }

    /// 将核心层的传输状态转换为稳定的展示状态，不丢弃异常连接。
    init(device: ADBDevice, previous: ManagedDevice? = nil, details: DeviceDetails? = nil) {
        id = device.id
        name = device.name
        serial = device.serial
        transports = device.transports.map { transport in
            let kind: TransportKind
            switch transport.kind {
            case .usb: kind = .usb
            case .wireless: kind = .wireless
            case .other: kind = .other
            }
            let state: TransportState
            switch transport.state {
            case .device: state = .device
            case .offline: state = .offline
            case .unauthorized: state = .unauthorized
            case .unknown: state = .unknown
            }
            return DeviceTransport(id: transport.id, kind: kind, state: state, address: transport.serial)
        }
        androidVersion = details?.androidVersion ?? previous?.androidVersion
        if let details, details.productBrand != nil || details.manufacturer != nil {
            brand = details.brand
        } else {
            // 短暂离线或属性查询失败时保留上次已识别结果，避免品牌图标在刷新间闪回 Android。
            brand = previous?.brand ?? .android
        }
        ipAddress = details?.ipAddress ?? previous?.ipAddress
        if let details {
            // 查询失败和“未设置代理”分开显示，避免把读取失败当作已关闭。
            proxyDescription = details.proxyReadError.map { "读取失败：\($0)" }
                ?? details.proxy?.description
                ?? "未设置代理"
        } else {
            proxyDescription = previous?.proxyDescription
        }
    }
}

/// 会话内的操作记录，只保存结果说明，不记录配对码或其他凭据。
struct ActivityEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
    let isError: Bool
}
