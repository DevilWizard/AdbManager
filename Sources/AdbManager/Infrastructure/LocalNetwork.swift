import Darwin
import Foundation

/// 使用系统网络接口读取 Mac 的局域网 IPv4，不依赖 shell 命令或特定 Wi-Fi 名称。
enum LocalNetwork {
    /// 过滤回环、VPN 和点对点接口，优先提供手机通常能够访问的 en 系列地址。
    static func ipv4Addresses() -> [String] {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let first = interfaceList else { return [] }
        defer { freeifaddrs(interfaceList) }

        var candidates: [(name: String, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let socketAddress = current.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(current.pointee.ifa_flags)
            let name = String(cString: current.pointee.ifa_name)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_POINTOPOINT == 0,
                  name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: host)
            guard !address.hasPrefix("169.254."), address != "0.0.0.0" else { continue }
            candidates.append((name, address))
        }

        // 多网卡时提供候选而不声称一定可达；用户可按实际网络选择或输入。
        var seen = Set<String>()
        return candidates.sorted {
            let leftRank = $0.name.hasPrefix("en") ? 0 : 1
            let rightRank = $1.name.hasPrefix("en") ? 0 : 1
            return leftRank == rightRank ? $0.name < $1.name : leftRank < rightRank
        }.compactMap { candidate in
            seen.insert(candidate.address).inserted ? candidate.address : nil
        }
    }
}
