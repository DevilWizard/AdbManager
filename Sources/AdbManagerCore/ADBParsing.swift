import Foundation

/// 将设备输出的解析与 I/O 分开，便于测试不同系统厂商和 ADB 版本的输出差异。
public enum ADBOutputParser {
    /// adb devices -l 中的提示行不会进入设备列表；所有命令始终使用 serial 定向到具体传输。
    public static func transports(from output: String) -> [ADBTransport] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count >= 2, columns[0] != "List", !columns[0].hasPrefix("*"),
                  !columns[0].hasPrefix("adb:") else { return nil }
            let serial = columns[0]
            let fields: [String: String] = columns.dropFirst(2).reduce(into: [:]) { result, field in
                guard let colon = field.firstIndex(of: ":") else { return }
                result[String(field[..<colon])] = String(field[field.index(after: colon)...])
            }
            let kind: ADBConnectionKind
            if serial.hasPrefix("emulator-") {
                kind = .other
            } else if fields["usb"] != nil {
                kind = .usb
            } else if serial.contains(":") || serial.contains("_adb-tls-connect._tcp") {
                kind = .wireless
            } else {
                // 部分平台不输出 usb: 元数据，普通物理序列号仍属于 USB 传输。
                kind = .usb
            }
            return ADBTransport(serial: serial, kind: kind, state: ADBDeviceState(rawValue: columns[1]),
                                model: fields["model"], product: fields["product"], transportID: fields["transport_id"])
        }
    }

    /// 从 ip -o -4 addr show 的 WLAN 接口行中提取单个 IPv4，排除蜂窝、回环和链路本地地址。
    public static func wiFiIPv4(from output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 4 else { continue }
            let interface = fields[1].split(separator: "@").first.map(String.init) ?? fields[1]
            guard interface.hasPrefix("wlan") || interface.hasPrefix("wifi") || interface.hasPrefix("swlan") else { continue }
            guard let index = fields.firstIndex(of: "inet"), index + 1 < fields.count else { continue }
            let address = String(fields[index + 1].split(separator: "/")[0])
            guard isUsableIPv4(address) else { continue }
            return address
        }
        return nil
    }

    /// 部分 Android 版本没有 -o 选项，route 回退同样只接受 WLAN 接口，不会错误连接蜂窝 IP。
    public static func wiFiIPv4FromRoutes(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let dev = fields.firstIndex(of: "dev"), dev + 1 < fields.count,
                  let src = fields.firstIndex(of: "src"), src + 1 < fields.count else { continue }
            let interface = fields[dev + 1]
            guard interface.hasPrefix("wlan") || interface.hasPrefix("wifi") || interface.hasPrefix("swlan") else { continue }
            let address = fields[src + 1]
            if isUsableIPv4(address) { return address }
        }
        return nil
    }

    private static func isUsableIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } == true }),
              let first = Int(parts[0]) else { return false }
        return first != 0 && first != 127 && first < 224 && !address.hasPrefix("169.254.")
    }
}
