import XCTest
@testable import AdbManagerCore

/// 覆盖 ADB 原始输出边界和用户输入边界，不依赖本机是否插着 Android 设备。
final class ADBModelTests: XCTestCase {
    func testDeviceParserPreservesTransportsAndAuthorizationState() {
        let output = """
        * daemon started successfully
        List of devices attached
        PHONE001 device usb:1-1 product:pixel model:Pixel_8 device:husky transport_id:1
        192.168.1.20:5555 device product:pixel model:Pixel_8 transport_id:2
        PHONE002 unauthorized usb:1-2 transport_id:3
        adb-PHONE003-abcdef._adb-tls-connect._tcp offline transport_id:4
        emulator-5554 device product:sdk model:Android_SDK transport_id:5
        """
        let transports = ADBOutputParser.transports(from: output)
        XCTAssertEqual(transports.count, 5)
        XCTAssertEqual(transports[0].kind, .usb)
        XCTAssertEqual(transports[0].model, "Pixel_8")
        XCTAssertEqual(transports[1].kind, .wireless)
        XCTAssertEqual(transports[2].state, .unauthorized)
        XCTAssertEqual(transports[3].kind, .wireless)
        XCTAssertEqual(transports[3].state, .offline)
        XCTAssertEqual(transports[4].kind, .other)
    }

    func testDevicePrefersUsableUSBAndDoesNotShowOfflineForStaleWireless() {
        let usb = ADBTransport(serial: "PHONE", kind: .usb, state: .device, model: "Pixel_8")
        let stale = ADBTransport(serial: "192.168.1.20:5555", kind: .wireless, state: .offline)
        let device = ADBDevice(serial: "PHONE", transports: [stale, usb])
        XCTAssertEqual(device.state, .device)
        XCTAssertEqual(device.preferredTransport, usb)
        XCTAssertEqual(device.name, "Pixel 8")
    }

    func testWiFiAddressParserIgnoresCellularVPNAndLoopback() {
        // WLAN 使用 RFC 5737 的 TEST-NET-1 文档地址，避免公开测试夹带真实设备网络。
        // 其余地址继续覆盖移动网络、VPN、回环和链路本地地址的过滤语义。
        let output = """
        1: lo inet 127.0.0.1/8 scope host lo
        9: rmnet_data0 inet 10.0.0.5/24 scope global rmnet_data0
        10: tun0 inet 10.8.0.2/24 scope global tun0
        37: wlan0 inet 192.0.2.40/24 brd 192.0.2.255 scope global wlan0
        """
        XCTAssertEqual(ADBOutputParser.wiFiIPv4(from: output), "192.0.2.40")
        XCTAssertNil(ADBOutputParser.wiFiIPv4(from: "1: wlan0 inet 169.254.2.3/16 scope global wlan0"))
        XCTAssertNil(ADBOutputParser.wiFiIPv4(from: "1: wlan0 inet 999.2.3.4/24 scope global wlan0"))
    }

    func testRouteFallbackDoesNotUseMobileDefaultRoute() {
        let output = """
        default via 10.0.0.1 dev rmnet_data0 src 10.0.0.2
        192.168.5.0/24 dev wlan1 proto kernel scope link src 192.168.5.26
        """
        XCTAssertEqual(ADBOutputParser.wiFiIPv4FromRoutes(output), "192.168.5.26")
    }

    func testProxySupportsIPv4AndDNSButRejectsShellAndURLInputs() throws {
        XCTAssertEqual(try ProxyConfiguration(host: "192.168.1.2").description, "192.168.1.2:9090")
        XCTAssertEqual(try ProxyConfiguration(host: "my-mac.local", port: 8080).port, 8080)
        for host in ["https://192.168.1.2", "192.168.1.2:9090", "mac.local;reboot", "$(whoami)", "mac local", "256.1.2.3", "-bad.local", "a..local", "::1"] {
            XCTAssertThrowsError(try ProxyConfiguration(host: host), "Should reject \(host)")
        }
        XCTAssertThrowsError(try ProxyConfiguration(host: "192.168.1.2", port: 0))
        XCTAssertThrowsError(try ProxyConfiguration(host: "192.168.1.2", port: 65536))
    }

    func testProxyParsingRecognizesDisabledValuesAndReportsMalformedValues() throws {
        for value in ["", "null\n", ":0", ":-1", "0.0.0.0:0"] {
            XCTAssertNil(try ProxyConfiguration.parse(value))
        }
        XCTAssertEqual(try ProxyConfiguration.parse("192.168.1.2:9090\n"), try ProxyConfiguration(host: "192.168.1.2"))
        XCTAssertThrowsError(try ProxyConfiguration.parse("unrecognized"))
    }
}
