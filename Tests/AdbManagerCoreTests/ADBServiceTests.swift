import XCTest
@testable import AdbManagerCore

/// 命令队列同时验证调用顺序与完整参数，确保多设备操作没有遗漏 -s 目标。
private actor ScriptedRunner: ADBCommandRunning {
    struct Step: Sendable {
        let arguments: [String]
        let response: ADBCommandResult
        let error: ADBError?

        init(_ arguments: [String], output: String = "", exitCode: Int32 = 0, error: ADBError? = nil) {
            self.arguments = arguments
            self.response = ADBCommandResult(standardOutput: output, exitCode: exitCode)
            self.error = error
        }
    }

    private var steps: [Step]
    private(set) var calls: [[String]] = []

    init(_ steps: [Step]) { self.steps = steps }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ADBCommandResult {
        calls.append(arguments)
        guard !steps.isEmpty else { throw ADBError.commandFailed("测试出现未预期的额外命令：\(arguments)") }
        let step = steps.removeFirst()
        guard step.arguments == arguments else {
            throw ADBError.commandFailed("命令目标或顺序错误：\(arguments)，预期 \(step.arguments)")
        }
        if let error = step.error { throw error }
        return step.response
    }

    var remainingCount: Int { steps.count }
}

/// 详情字段会并发读取，此 mock 按完整参数路由而不依赖并发任务的调度顺序。
private actor RoutingRunner: ADBCommandRunning {
    private let stepsByArguments: [String: ScriptedRunner.Step]
    private(set) var calls: [[String]] = []

    init(_ steps: [ScriptedRunner.Step]) {
        stepsByArguments = Dictionary(uniqueKeysWithValues: steps.map { ($0.arguments.joined(separator: "\u{1F}"), $0) })
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ADBCommandResult {
        calls.append(arguments)
        guard let step = stepsByArguments[arguments.joined(separator: "\u{1F}")] else {
            throw ADBError.commandFailed("未预期的命令：\(arguments)")
        }
        if let error = step.error { throw error }
        return step.response
    }
}

final class ADBServiceTests: XCTestCase {
    private let adbURL = URL(fileURLWithPath: "/test/adb")

    private var usbDevice: ADBDevice {
        ADBDevice(serial: "PHONE001", transports: [
            ADBTransport(serial: "PHONE001", kind: .usb, state: .device, model: "Pixel_8")
        ])
    }

    /// 模拟一键无线成功后列表尚未手动刷新的快照，USB 与无线都曾完成身份归并。
    private var knownDualTransportDevice: ADBDevice {
        ADBDevice(serial: "PHONE001", transports: [
            ADBTransport(serial: "PHONE001", kind: .usb, state: .device, transportID: "11"),
            ADBTransport(serial: "192.168.1.20:5555", kind: .wireless, state: .device, transportID: "42")
        ])
    }

    func testDiscoveryMergesOnlyVerifiedPhysicalIdentity() async throws {
        let runner = ScriptedRunner([
            .init(["devices", "-l"], output: """
                List of devices attached
                PHONE001 device usb:1-1 model:Pixel_8
                192.168.1.20:5555 device model:Pixel_8
                PHONE002 unauthorized usb:1-2
                192.168.1.21:5555 offline model:Pixel_8
                """),
            .init(["-s", "192.168.1.20:5555", "shell", "getprop", "ro.serialno"], output: "PHONE001\n")
        ])
        let service = ADBService(executableURL: adbURL, runner: runner)
        let devices = try await service.devices()
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices.first { $0.serial == "PHONE001" }?.transports.count, 2)
        XCTAssertEqual(devices.first { $0.serial == "PHONE002" }?.state, .unauthorized)
        let remaining = await runner.remainingCount
        XCTAssertEqual(remaining, 0)
    }

    func testSingleWirelessIdentityFailureDoesNotHideAllDevices() async throws {
        let runner = ScriptedRunner([
            .init(["devices", "-l"], output: "List of devices attached\nPHONE001 device usb:1-1\n192.168.1.21:5555 device\n"),
            .init(["-s", "192.168.1.21:5555", "shell", "getprop", "ro.serialno"], error: .commandTimedOut(5))
        ])
        let devices = try await ADBService(executableURL: adbURL, runner: runner).devices()
        XCTAssertEqual(devices.count, 2)
        XCTAssertTrue(devices.contains { $0.serial == "192.168.1.21:5555" })
    }

    /// 同一个 IP:端口再次上线可能已经属于另一台手机；身份读取失败不能沿用旧归属。
    func testReusedOnlineEndpointDoesNotReuseCachedIdentityWhenSerialReadFails() async throws {
        let endpoint = "192.168.1.20:5555"
        let snapshot = "List of devices attached\nPHONE001 device usb:1-1\n\(endpoint) device\n"
        let runner = ScriptedRunner([
            .init(["devices", "-l"], output: snapshot),
            .init(["-s", endpoint, "shell", "getprop", "ro.serialno"], output: "PHONE001"),
            .init(["devices", "-l"], output: snapshot),
            .init(["-s", endpoint, "shell", "getprop", "ro.serialno"], error: .commandTimedOut(5))
        ])
        let service = ADBService(executableURL: adbURL, runner: runner)
        let original = try await service.devices()
        XCTAssertEqual(original.count, 1)
        XCTAssertEqual(original.first?.transports.count, 2)

        let refreshed = try await service.devices()
        XCTAssertEqual(refreshed.count, 2)
        XCTAssertEqual(refreshed.first { $0.serial == "PHONE001" }?.transports.count, 1)
        XCTAssertEqual(refreshed.first { $0.serial == endpoint }?.transports.count, 1)
        let remaining = await runner.remainingCount
        XCTAssertEqual(remaining, 0)
    }

    /// 离线端点不会承接任何设备写操作，可以保留已验证身份以避免产生重复列表项。
    func testOfflineEndpointMayRetainPreviouslyVerifiedIdentity() async throws {
        let endpoint = "192.168.1.20:5555"
        let runner = ScriptedRunner([
            .init(["devices", "-l"], output: "List of devices attached\nPHONE001 device usb:1-1\n\(endpoint) device\n"),
            .init(["-s", endpoint, "shell", "getprop", "ro.serialno"], output: "PHONE001"),
            .init(["devices", "-l"], output: "List of devices attached\nPHONE001 device usb:1-1\n\(endpoint) offline\n")
        ])
        let service = ADBService(executableURL: adbURL, runner: runner)
        _ = try await service.devices()
        let refreshed = try await service.devices()
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.serial, "PHONE001")
        XCTAssertEqual(refreshed.first?.transports.count, 2)
        XCTAssertEqual(refreshed.first?.state, .device)
        let remaining = await runner.remainingCount
        XCTAssertEqual(remaining, 0)
    }

    func testWirelessRejectsAbsentUSBWithoutSendingCommands() async {
        let runner = ScriptedRunner([])
        let service = ADBService(executableURL: adbURL, runner: runner)
        let wirelessOnly = ADBDevice(serial: "PHONE001", transports: [
            ADBTransport(serial: "192.168.1.20:5555", kind: .wireless, state: .device)
        ])
        do {
            _ = try await service.enableWireless(for: wirelessOnly)
            XCTFail("无线连接不能被当成 USB 初始化目标")
        } catch {
            XCTAssertEqual(error as? ADBError, .noUSBConnection)
        }
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testWirelessRejectsUnauthorizedUSBWithoutSendingCommands() async {
        let runner = ScriptedRunner([])
        let device = ADBDevice(serial: "LOCKED", transports: [ADBTransport(serial: "LOCKED", kind: .usb, state: .unauthorized)])
        do {
            _ = try await ADBService(executableURL: adbURL, runner: runner).enableWireless(for: device)
            XCTFail("未授权时不应操作手机")
        } catch {
            XCTAssertEqual(error as? ADBError, .unauthorized)
        }
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testWirelessSuccessVerifiesTheSamePhysicalPhoneBeforeReturning() async throws {
        let endpoint = "192.168.1.20:5555"
        let runner = ScriptedRunner([
            .init(["-s", "PHONE001", "get-state"], output: "device"),
            .init(["-s", "PHONE001", "shell", "getprop", "ro.serialno"], output: "PHONE001"),
            .init(["-s", "PHONE001", "shell", "ip", "-o", "-4", "addr", "show"], output: "37: wlan0 inet 192.168.1.20/24 scope global wlan0"),
            .init(["-s", "PHONE001", "tcpip", "5555"], output: "restarting in TCP mode port: 5555"),
            .init(["connect", endpoint], output: "connected to \(endpoint)"),
            .init(["-s", endpoint, "shell", "getprop", "ro.serialno"], output: "PHONE001"),
            .init(["-s", endpoint, "get-state"], output: "device")
        ])
        let result = try await ADBService(executableURL: adbURL, runner: runner).enableWireless(for: usbDevice)
        XCTAssertEqual(result.endpoint, endpoint)
        XCTAssertEqual(result.physicalSerial, "PHONE001")
        XCTAssertEqual(result.mode, .legacyTCP)
        let remaining = await runner.remainingCount
        XCTAssertEqual(remaining, 0)
    }

    func testWirelessMismatchedPhoneIsDisconnectedAndNeverReportedSuccessful() async {
        let endpoint = "192.168.1.20:5555"
        let runner = ScriptedRunner([
            .init(["-s", "PHONE001", "get-state"], output: "device"),
            .init(["-s", "PHONE001", "shell", "getprop", "ro.serialno"], output: "PHONE001"),
            .init(["-s", "PHONE001", "shell", "ip", "-o", "-4", "addr", "show"], output: "37: wlan0 inet 192.168.1.20/24 scope global wlan0"),
            .init(["-s", "PHONE001", "tcpip", "5555"], output: "restarting in TCP mode port: 5555"),
            .init(["connect", endpoint], output: "connected to \(endpoint)"),
            .init(["-s", endpoint, "shell", "getprop", "ro.serialno"], output: "ANOTHER_PHONE"),
            .init(["disconnect", endpoint], output: "disconnected \(endpoint)")
        ])
        do {
            _ = try await ADBService(executableURL: adbURL, runner: runner).enableWireless(for: usbDevice)
            XCTFail("连接到错误手机必须失败")
        } catch {
            guard let adbError = error as? ADBError, case .wirelessVerificationFailed = adbError else {
                return XCTFail("错误类型不正确：\(error)")
            }
        }
        let remaining = await runner.remainingCount
        XCTAssertEqual(remaining, 0)
    }

    func testMissingWiFiAddressNeverEnablesTCP() async {
        let runner = ScriptedRunner([
            .init(["-s", "PHONE001", "get-state"], output: "device"),
            .init(["-s", "PHONE001", "shell", "getprop", "ro.serialno"], output: "PHONE001"),
            .init(["-s", "PHONE001", "shell", "ip", "-o", "-4", "addr", "show"], output: "9: rmnet_data0 inet 10.0.0.2/24 scope global rmnet_data0"),
            .init(["-s", "PHONE001", "shell", "ip", "route"], output: "default dev rmnet_data0 src 10.0.0.2")
        ])
        do {
            _ = try await ADBService(executableURL: adbURL, runner: runner).enableWireless(for: usbDevice)
            XCTFail("没有 WLAN 时不应开启 TCP")
        } catch {
            XCTAssertEqual(error as? ADBError, .noWiFiAddress)
        }
        let calls = await runner.calls
        XCTAssertFalse(calls.contains { $0.contains("tcpip") })
    }

    func testProxyTargetsSelectedPhoneAndVerifiesReadback() async throws {
        let runner = ScriptedRunner([
            .init(["-s", "PHONE001", "get-state"], output: "device"),
            .init(["-s", "PHONE001", "shell", "settings", "put", "global", "http_proxy", "192.168.1.2:9090"]),
            .init(["-s", "PHONE001", "shell", "settings", "get", "global", "http_proxy"], output: "192.168.1.2:9090")
        ])
        let configuration = try ProxyConfiguration(host: "192.168.1.2")
        try await ADBService(executableURL: adbURL, runner: runner).setProxy(configuration, for: usbDevice)
        let remaining = await runner.remainingCount
        XCTAssertEqual(remaining, 0)
    }

    /// 已知传输 ID 时代理写入与校验必须绑定同一条传输，不能按可复用的 IP:端口重定向。
    func testProxyUsesTransportIDInsteadOfReusableWirelessEndpoint() async throws {
        let device = ADBDevice(serial: "PHONE001", transports: [
            ADBTransport(serial: "192.168.1.20:5555", kind: .wireless, state: .device, transportID: "42")
        ])
        let runner = ScriptedRunner([
            .init(["-t", "42", "get-state"], output: "device"),
            .init(["-t", "42", "shell", "getprop", "ro.serialno"], output: "PHONE001"),
            .init(["-t", "42", "shell", "settings", "put", "global", "http_proxy", "192.168.1.2:9090"]),
            .init(["-t", "42", "shell", "settings", "get", "global", "http_proxy"], output: "192.168.1.2:9090")
        ])
        try await ADBService(executableURL: adbURL, runner: runner)
            .setProxy(try ProxyConfiguration(host: "192.168.1.2"), for: device)
        let remaining = await runner.remainingCount
        XCTAssertEqual(remaining, 0)
    }

    func testProxyReadbackMismatchIsNotReportedAsSuccess() async throws {
        let runner = ScriptedRunner([
            .init(["-s", "PHONE001", "get-state"], output: "device"),
            .init(["-s", "PHONE001", "shell", "settings", "put", "global", "http_proxy", "192.168.1.2:9090"]),
            .init(["-s", "PHONE001", "shell", "settings", "get", "global", "http_proxy"], output: "null")
        ])
        do {
            try await ADBService(executableURL: adbURL, runner: runner).setProxy(try ProxyConfiguration(host: "192.168.1.2"), for: usbDevice)
            XCTFail("代理读回不一致必须失败")
        } catch {
            XCTAssertEqual(error as? ADBError, .proxyVerificationFailed(expected: "192.168.1.2:9090", actual: "null"))
        }
    }

    func testDisableProxyWritesAndroidDisabledValueAndVerifiesIt() async throws {
        let runner = ScriptedRunner([
            .init(["-s", "PHONE001", "get-state"], output: "device"),
            .init(["-s", "PHONE001", "shell", "settings", "put", "global", "http_proxy", ":0"]),
            .init(["-s", "PHONE001", "shell", "settings", "get", "global", "http_proxy"], output: ":0")
        ])
        try await ADBService(executableURL: adbURL, runner: runner).disableProxy(for: usbDevice)
        let remaining = await runner.remainingCount
        XCTAssertEqual(remaining, 0)
    }

    func testDisconnectOnlyTouchesWirelessEndpointsOfSelectedPhone() async throws {
        let device = ADBDevice(serial: "PHONE001", transports: [
            ADBTransport(serial: "PHONE001", kind: .usb, state: .device),
            ADBTransport(serial: "192.168.1.20:5555", kind: .wireless, state: .device)
        ])
        let runner = ScriptedRunner([
            .init(["-s", "192.168.1.20:5555", "get-state"], output: "device"),
            .init(["-s", "192.168.1.20:5555", "shell", "getprop", "ro.serialno"], output: "PHONE001"),
            .init(["disconnect", "192.168.1.20:5555"], output: "disconnected")
        ])
        try await ADBService(executableURL: adbURL, runner: runner).disconnectWireless(for: device)
        let calls = await runner.calls
        XCTAssertEqual(calls.filter { $0.first == "disconnect" }, [["disconnect", "192.168.1.20:5555"]])
    }

    /// 列表快照里 USB 仍在线，实际已拔线；详情必须使用同一手机的已知无线连接。
    func testDetailsFallsBackFromExpiredUSBToKnownWirelessWithoutScanningDevices() async throws {
        let runner = RoutingRunner([
            .init(["-t", "11", "get-state"], error: .commandFailed("transport not found")),
            .init(["-t", "42", "get-state"], output: "device"),
            .init(["-t", "42", "shell", "getprop", "ro.serialno"], output: "PHONE001"),
            .init(["-t", "42", "shell", "getprop", "ro.build.version.release"], output: "14"),
            .init(["-t", "42", "shell", "getprop", "ro.build.version.sdk"], output: "34"),
            .init(["-t", "42", "shell", "getprop", "ro.product.brand"], output: "HONOR\n"),
            .init(["-t", "42", "shell", "getprop", "ro.product.manufacturer"], output: "HUAWEI\n"),
            .init(["-t", "42", "shell", "ip", "-o", "-4", "addr", "show"], output: "37: wlan0 inet 192.168.1.20/24 scope global wlan0"),
            .init(["-t", "42", "shell", "settings", "get", "global", "http_proxy"], output: "192.168.1.2:9090")
        ])
        let details = try await ADBService(executableURL: adbURL, runner: runner).details(for: knownDualTransportDevice)
        XCTAssertEqual(details.androidVersion, "14")
        XCTAssertEqual(details.apiLevel, "34")
        XCTAssertEqual(details.productBrand, "HONOR")
        XCTAssertEqual(details.manufacturer, "HUAWEI")
        XCTAssertEqual(details.brand, .honor)
        XCTAssertEqual(details.ipAddress, "192.168.1.20")
        XCTAssertEqual(details.proxy, try ProxyConfiguration(host: "192.168.1.2"))
        XCTAssertNil(details.proxyReadError)
        let calls = await runner.calls
        XCTAssertFalse(calls.contains { $0.contains("devices") })
        XCTAssertEqual(calls.filter { $0 == ["-t", "11", "get-state"] }.count, 1)
        XCTAssertFalse(calls.contains { $0.first == "-s" })
        XCTAssertTrue(calls.contains(["-t", "42", "shell", "getprop", "ro.product.brand"]))
        XCTAssertTrue(calls.contains(["-t", "42", "shell", "getprop", "ro.product.manufacturer"]))
    }

    /// ROM 不提供品牌属性时仍可显示制造商品牌，版本、IP 与代理等详情不能被连带丢弃。
    func testMissingBrandPropertyFallsBackToManufacturerWithoutFailingDetails() async throws {
        let runner = RoutingRunner([
            .init(["-s", "PHONE001", "get-state"], output: "device"),
            .init(["-s", "PHONE001", "shell", "getprop", "ro.build.version.release"], output: "14"),
            .init(["-s", "PHONE001", "shell", "getprop", "ro.build.version.sdk"], output: "34"),
            .init(["-s", "PHONE001", "shell", "getprop", "ro.product.brand"], error: .commandFailed("属性读取失败")),
            .init(["-s", "PHONE001", "shell", "getprop", "ro.product.manufacturer"], output: "Samsung"),
            .init(["-s", "PHONE001", "shell", "ip", "-o", "-4", "addr", "show"], output: "37: wlan0 inet 192.168.1.20/24 scope global wlan0"),
            .init(["-s", "PHONE001", "shell", "settings", "get", "global", "http_proxy"], output: ":0")
        ])
        let details = try await ADBService(executableURL: adbURL, runner: runner).details(for: usbDevice)
        XCTAssertNil(details.productBrand)
        XCTAssertEqual(details.manufacturer, "Samsung")
        XCTAssertEqual(details.brand, .samsung)
        XCTAssertEqual(details.androidVersion, "14")
        XCTAssertEqual(details.ipAddress, "192.168.1.20")
        XCTAssertNil(details.proxy)
        XCTAssertNil(details.proxyReadError)
    }

    /// 代理的读取、设置和关闭都应重新解析当前可用传输，不能继续写已拔掉的 USB。
    func testAllProxyOperationsUseKnownWirelessWhenUSBHasExpired() async throws {
        let probe: [ScriptedRunner.Step] = [
            .init(["-t", "11", "get-state"], error: .commandFailed("transport not found")),
            .init(["-t", "42", "get-state"], output: "device"),
            .init(["-t", "42", "shell", "getprop", "ro.serialno"], output: "PHONE001")
        ]
        let runner = ScriptedRunner(
            probe + [.init(["-t", "42", "shell", "settings", "get", "global", "http_proxy"], output: "null")]
            + probe + [
                .init(["-t", "42", "shell", "settings", "put", "global", "http_proxy", "192.168.1.2:9090"]),
                .init(["-t", "42", "shell", "settings", "get", "global", "http_proxy"], output: "192.168.1.2:9090")
            ]
            + probe + [
                .init(["-t", "42", "shell", "settings", "put", "global", "http_proxy", ":0"]),
                .init(["-t", "42", "shell", "settings", "get", "global", "http_proxy"], output: ":0")
            ]
        )
        let service = ADBService(executableURL: adbURL, runner: runner)
        let initialProxy = try await service.proxy(for: knownDualTransportDevice)
        XCTAssertNil(initialProxy)
        try await service.setProxy(try ProxyConfiguration(host: "192.168.1.2"), for: knownDualTransportDevice)
        try await service.disableProxy(for: knownDualTransportDevice)
        let calls = await runner.calls
        XCTAssertFalse(calls.contains { $0.contains("devices") || $0.first == "-s" })
        XCTAssertEqual(calls.filter { $0.contains("put") }.count, 2)
        let remaining = await runner.remainingCount
        XCTAssertEqual(remaining, 0)
    }

    /// 两条已知传输都失效时，详情/代理全部失败，不能扫描新设备或向同 IP 的新设备写入。
    func testUnavailableKnownTransportsNeverScanOrWriteProxySettings() async throws {
        let runner = RoutingRunner([
            .init(["-t", "11", "get-state"], error: .commandFailed("transport not found")),
            .init(["-t", "42", "get-state"], error: .commandFailed("transport not found"))
        ])
        let service = ADBService(executableURL: adbURL, runner: runner)
        let device = knownDualTransportDevice
        let configuration = try ProxyConfiguration(host: "192.168.1.2")
        let actions: [() async throws -> Void] = [
            { _ = try await service.details(for: device) },
            { _ = try await service.proxy(for: device) },
            { try await service.setProxy(configuration, for: device) },
            { try await service.disableProxy(for: device) }
        ]
        for action in actions {
            do {
                try await action()
                XCTFail("全部已知传输失效时应明确失败")
            } catch {
                XCTAssertEqual(error as? ADBError, .noUsableConnection)
            }
        }
        let calls = await runner.calls
        XCTAssertTrue(calls.allSatisfy { $0 == ["-t", "11", "get-state"] || $0 == ["-t", "42", "get-state"] })
        XCTAssertFalse(calls.contains { $0.contains("devices") || $0.contains("put") || $0.first == "-s" })
    }

    /// 缓存端点如果已属于另一台手机，不能为了断开所选设备而连带断开它。
    func testDisconnectRefusesAnEndpointWhosePhysicalIdentityHasChanged() async {
        let runner = ScriptedRunner([
            .init(["-t", "42", "get-state"], output: "device"),
            .init(["-t", "42", "shell", "getprop", "ro.serialno"], output: "ANOTHER_PHONE")
        ])
        do {
            try await ADBService(executableURL: adbURL, runner: runner).disconnectWireless(for: knownDualTransportDevice)
            XCTFail("设备身份不符时不能断开该端点")
        } catch {
            XCTAssertEqual(error as? ADBError, .noUsableConnection)
        }
        let calls = await runner.calls
        XCTAssertFalse(calls.contains { $0.first == "disconnect" || $0.contains("devices") })
    }

    /// 一键无线必须重新确认 USB 可用，不能因缓存 USB 失效而改用已有无线执行初始化。
    func testWirelessSetupDoesNotFallbackToWirelessWhenTheKnownUSBHasExpired() async {
        let runner = ScriptedRunner([
            .init(["-t", "11", "get-state"], error: .commandFailed("transport not found"))
        ])
        do {
            _ = try await ADBService(executableURL: adbURL, runner: runner).enableWireless(for: knownDualTransportDevice)
            XCTFail("USB 已拔线时不能执行一键无线初始化")
        } catch {
            XCTAssertEqual(error as? ADBError, .noUSBConnection)
        }
        let calls = await runner.calls
        XCTAssertEqual(calls, [["-t", "11", "get-state"]])
    }
}
