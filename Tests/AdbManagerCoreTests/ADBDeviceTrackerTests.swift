import XCTest
import Darwin
@testable import AdbManagerCore

/// 帧解码与拓扑测试只使用内存；长期进程测试使用独立临时脚本，不连接实际 adb server。
final class ADBDeviceTrackerTests: XCTestCase {
    private func frame(_ payload: String) -> Data {
        var data = Data(String(format: "%04x", payload.utf8.count).utf8)
        data.append(contentsOf: payload.utf8)
        return data
    }

    func testIncrementalFramesAcceptSplitHeaderPayloadAndUTF8Characters() throws {
        let payload = "PHONE device model:像素 transport_id:7\n"
        var decoder = ADBDeviceTrackFrameDecoder()
        var snapshots: [String] = []
        // 每个字节独立到达，覆盖四位长度头和多字节 UTF-8 被拆分的情况。
        for byte in frame(payload) { snapshots += try decoder.append(Data([byte])) }
        XCTAssertEqual(snapshots, [payload])
        XCTAssertNoThrow(try decoder.finish())
    }

    func testGluedFramesIncludeZeroLengthEmptyDeviceLists() throws {
        let payload = "PHONE unauthorized usb:1-1 transport_id:7\n"
        var decoder = ADBDeviceTrackFrameDecoder()
        var data = frame("")
        data.append(frame(payload))
        data.append(frame(""))
        XCTAssertEqual(try decoder.append(data), ["", payload, ""])
        XCTAssertNoThrow(try decoder.finish())
    }

    func testInvalidLengthHeadersAreRejectedWithoutGuessingPayloadBoundaries() {
        for header in ["ZZZZ", "-001", "00\n1", "000 "] {
            var decoder = ADBDeviceTrackFrameDecoder()
            XCTAssertThrowsError(try decoder.append(Data(header.utf8))) {
                XCTAssertEqual($0 as? ADBDeviceTrackingError, .invalidFrameLength)
            }
        }
    }

    func testEOFRejectsPartialHeadersAndPartialPayloads() throws {
        for value in ["00", "0005ab"] {
            var decoder = ADBDeviceTrackFrameDecoder()
            _ = try decoder.append(Data(value.utf8))
            XCTAssertThrowsError(try decoder.finish()) {
                XCTAssertEqual($0 as? ADBDeviceTrackingError, .incompleteFrame)
            }
        }
    }

    func testInvalidUTF8PayloadIsReported() {
        var decoder = ADBDeviceTrackFrameDecoder()
        var data = Data("0001".utf8)
        data.append(0xFF)
        XCTAssertThrowsError(try decoder.append(data)) {
            XCTAssertEqual($0 as? ADBDeviceTrackingError, .invalidUTF8)
        }
    }

    func testTopologyIgnoresOrderingAndDisplayMetadataButTracksConnectionChanges() {
        let usb = ADBTransport(serial: "PHONE", kind: .usb, state: .device, model: "Old_Model", transportID: "1")
        let wifi = ADBTransport(serial: "192.168.1.20:5555", kind: .wireless, state: .device, transportID: "2")
        let sameUSB = ADBTransport(serial: "PHONE", kind: .usb, state: .device, model: "New_Model", product: "new", transportID: "1")
        let topology = ADBDeviceTopology(transports: [usb, wifi])
        XCTAssertEqual(topology, ADBDeviceTopology(transports: [wifi, sameUSB]))
        XCTAssertNotEqual(topology, ADBDeviceTopology(transports: [usb]))
        XCTAssertNotEqual(topology, ADBDeviceTopology(transports: [
            usb, ADBTransport(serial: wifi.serial, kind: .wireless, state: .offline, transportID: "2")
        ]))
        XCTAssertNotEqual(topology, ADBDeviceTopology(transports: [
            usb, ADBTransport(serial: wifi.serial, kind: .wireless, state: .device, transportID: "3")
        ]))
        XCTAssertNotEqual(ADBDeviceTopology(transports: [usb]), ADBDeviceTopology(transports: [
            ADBTransport(serial: "PHONE", kind: .usb, state: .unauthorized, transportID: "1")
        ]))
    }

    /// 使用同一 PID 先发设备帧、再 exec sleep。取消订阅后该客户端必须实际退出，不能只让 UI 停等。
    func testCancellingSubscriptionTerminatesItsClientProcessAndFinishesConsumer() async throws {
        let executable = try makeExecutable("""
        payload="$$ device transport_id:123"
        printf '%04x' "${#payload}"
        printf '%s' "$payload"
        exec /bin/sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let observation = TrackerPIDObservation()
        let stream = ADBDeviceTracker().snapshots(executableURL: executable)
        let consumer = Task {
            for try await snapshot in stream {
                if let serial = snapshot.first?.serial, let identifier = Int32(serial) {
                    await observation.record(identifier)
                }
            }
        }
        var identifier: Int32?
        for _ in 0..<200 {
            identifier = await observation.identifier
            if identifier != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let identifier else {
            consumer.cancel()
            _ = await consumer.result
            return XCTFail("未收到测试客户端的首帧")
        }
        XCTAssertEqual(Darwin.kill(identifier, 0), 0)
        consumer.cancel()
        _ = await consumer.result
        var exited = false
        for _ in 0..<200 {
            if Darwin.kill(identifier, 0) != 0 && errno == ESRCH {
                exited = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(exited, "取消订阅必须回收本次直接启动的客户端")
    }

    func testAbnormalClientExitFinishesStreamWithBoundedDiagnostics() async throws {
        let executable = try makeExecutable("""
        printf '0000'
        printf 'tracker failed' >&2
        exit 7
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        do {
            for try await _ in ADBDeviceTracker().snapshots(executableURL: executable) {}
            XCTFail("非零退出码不能被当成正常订阅结束")
        } catch {
            guard let trackingError = error as? ADBDeviceTrackingError,
                  case .processExited(let code, let diagnostics) = trackingError else {
                return XCTFail("错误类型不正确：\(error)")
            }
            XCTAssertEqual(code, 7)
            XCTAssertTrue(diagnostics.contains("tracker failed"))
            XCTAssertLessThanOrEqual(diagnostics.utf8.count, 16_384)
        }
    }

    func testClientEOFInMiddleOfFrameFailsTheStream() async throws {
        let executable = try makeExecutable("printf '0005ab'\nexit 0")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        do {
            for try await _ in ADBDeviceTracker().snapshots(executableURL: executable) {}
            XCTFail("半帧 EOF 必须报错")
        } catch {
            XCTAssertEqual(error as? ADBDeviceTrackingError, .incompleteFrame)
        }
    }

    /// 消费者收到事件后仍在处理快照，尚未再次 await next；同步 cancelAll 仍必须停止客户端。
    func testCancelAllTerminatesClientWhileConsumerIsProcessingSnapshot() async throws {
        let executable = try makeLongRunningTrackerExecutable()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let tracker = ADBDeviceTracker()
        let observation = TrackerPIDObservation()
        let consumer = pausedConsumer(tracker: tracker, executable: executable, observation: observation)
        defer { consumer.cancel(); tracker.cancelAll() }
        guard let identifier = try await waitForIdentifier(observation) else {
            return XCTFail("未收到测试客户端的首帧")
        }
        XCTAssertFalse(consumer.isCancelled)
        tracker.cancelAll()
        let exited = try await waitForClientExit(identifier)
        XCTAssertTrue(exited, "消费者尚未再次读取流时，cancelAll 也必须直接结束客户端")
        XCTAssertFalse(consumer.isCancelled, "此回归不应依赖 Task.cancel 来触发流终止")
        consumer.cancel()
        _ = await consumer.result
    }

    /// cancelAll 只作用于当时的会话；新订阅保持可用，Tracker 的 struct 副本共享同一注册表。
    func testCancelAllAllowsNewSubscriptionsAndTrackerCopiesShareRegistry() async throws {
        let executable = try makeLongRunningTrackerExecutable()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let tracker = ADBDeviceTracker()
        let copiedTracker = tracker
        let firstObservation = TrackerPIDObservation()
        let firstConsumer = pausedConsumer(tracker: tracker, executable: executable, observation: firstObservation)
        defer { firstConsumer.cancel(); tracker.cancelAll() }
        guard let firstIdentifier = try await waitForIdentifier(firstObservation) else {
            return XCTFail("未收到第一个客户端的首帧")
        }
        tracker.cancelAll()
        let firstExited = try await waitForClientExit(firstIdentifier)
        XCTAssertTrue(firstExited)
        firstConsumer.cancel()
        _ = await firstConsumer.result

        let secondObservation = TrackerPIDObservation()
        let secondConsumer = pausedConsumer(tracker: tracker, executable: executable, observation: secondObservation)
        defer { secondConsumer.cancel(); copiedTracker.cancelAll() }
        guard let secondIdentifier = try await waitForIdentifier(secondObservation) else {
            return XCTFail("cancelAll 后的新订阅不应继承旧会话的取消标记")
        }
        XCTAssertEqual(Darwin.kill(secondIdentifier, 0), 0)
        copiedTracker.cancelAll()
        let secondExited = try await waitForClientExit(secondIdentifier)
        XCTAssertTrue(secondExited, "Tracker 副本必须能够取消同实例注册表中的新客户端")
        secondConsumer.cancel()
        _ = await secondConsumer.result
    }

    /// 首帧携带当前 shell PID，再 exec 替换成同 PID 的 sleep，便于确认客户端被实际回收。
    private func makeLongRunningTrackerExecutable() throws -> URL {
        try makeExecutable("""
        payload="$$ device transport_id:123"
        printf '%04x' "${#payload}"
        printf '%s' "$payload"
        exec /bin/sleep 30
        """)
    }

    /// 故意在处理快照阶段暂停，模拟主线程刷新设备详情或写代理而没有继续 await next。
    private func pausedConsumer(tracker: ADBDeviceTracker, executable: URL,
                                observation: TrackerPIDObservation) -> Task<Void, Error> {
        let stream = tracker.snapshots(executableURL: executable)
        return Task {
            for try await snapshot in stream {
                if let serial = snapshot.first?.serial, let identifier = Int32(serial) {
                    await observation.record(identifier)
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                }
            }
        }
    }

    private func waitForIdentifier(_ observation: TrackerPIDObservation) async throws -> Int32? {
        for _ in 0..<200 {
            if let identifier = await observation.identifier { return identifier }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func waitForClientExit(_ identifier: Int32) async throws -> Bool {
        for _ in 0..<200 {
            if Darwin.kill(identifier, 0) != 0 && errno == ESRCH { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// 测试脚本仅作为假 adb，可执行文件和参数仍由 Process 直接传递，不拼接运行时 shell 命令。
    private func makeExecutable(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdbManager-TrackerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-adb")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
}

/// 测试消费者与断言任务之间通过 actor 传递 PID，不引入非线程安全的共享变量。
private actor TrackerPIDObservation {
    private(set) var identifier: Int32?
    func record(_ identifier: Int32) { self.identifier = identifier }
}
