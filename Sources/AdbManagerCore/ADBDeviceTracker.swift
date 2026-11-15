import Foundation
import Darwin

/// 只比较设备连接拓扑：型号等展示元数据变化不会触发设备列表重新加载。
public struct ADBDeviceTopology: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let serial: String
        let state: ADBDeviceState
        let transportID: String?

        /// 未知状态也保留原值，使新增授权/在线状态仍然能够触发事件。
        var stateSortKey: String {
            switch state {
            case .device: return "0"
            case .offline: return "1"
            case .unauthorized: return "2"
            case .unknown(let value): return "3:" + value
            }
        }
    }

    private let entries: [Entry]

    public init(transports: [ADBTransport]) {
        entries = transports.map { Entry(serial: $0.serial, state: $0.state, transportID: $0.transportID) }
            .sorted { left, right in
                if left.serial != right.serial { return left.serial < right.serial }
                if left.stateSortKey != right.stateSortKey { return left.stateSortKey < right.stateSortKey }
                // nil 与空字符串也采用稳定排序，不依赖原始输出顺序。
                let leftID = left.transportID.map { "1:" + $0 } ?? "0:"
                let rightID = right.transportID.map { "1:" + $0 } ?? "0:"
                return leftID < rightID
            }
    }
}

/// 长期设备事件订阅。每条流只启动一个独立客户端，既不轮询也不自动重连。
public struct ADBDeviceTracker: Sendable {
    /// 引用型注册表使同一个 Tracker 的 struct 副本共享会话，方便 AppDelegate 同步清理。
    private let registry: ADBDeviceTrackingRegistry

    public init() { registry = ADBDeviceTrackingRegistry() }

    /// 应用退出时不能仅取消 Swift Task；消费者可能仍在处理快照，尚未再次 await next。
    /// 此方法直接同步取消当前已注册客户端，同时允许之后重新创建新的订阅。
    public func cancelAll() {
        registry.cancelAll()
    }

    /// adb track-devices -l 返回完整设备快照；只缓冲最新一份，避免界面忙时无限积压。
    /// 消费任务取消或流终止时，只结束本次客户端，保留共享 adb server 和其他设备会话。
    public func snapshots(executableURL: URL) -> AsyncThrowingStream<[ADBTransport], Error> {
        let registry = self.registry
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let identifier = UUID()
            let session = ADBDeviceTrackingSession(executableURL: executableURL) { [weak registry] in
                registry?.remove(identifier)
            }
            // 必须先注册再排队启动：cancelAll 即使遇到尚未 launch 的会话，也能阻止后续启动。
            registry.register(session, identifier: identifier)
            continuation.onTermination = { @Sendable [weak session, weak registry] _ in
                registry?.remove(identifier)
                session?.cancel()
            }
            session.start(continuation: continuation)
        }
    }
}

/// 以短锁保护注册表；调用 Process.cancel 时不持锁，避免生命周期回调发生锁重入。
private final class ADBDeviceTrackingRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [UUID: ADBDeviceTrackingSession] = [:]

    func register(_ session: ADBDeviceTrackingSession, identifier: UUID) {
        lock.lock()
        sessions[identifier] = session
        lock.unlock()
    }

    func remove(_ identifier: UUID) {
        lock.lock()
        sessions.removeValue(forKey: identifier)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let currentSessions = Array(sessions.values)
        sessions.removeAll(keepingCapacity: true)
        lock.unlock()
        // 只取消本次摘取的会话；并发或后续的新订阅不会被永久的“已取消”标记污染。
        for session in currentSessions { session.cancel() }
    }
}

/// 协议错误与进程错误明确区分，便于上层显示原因并自行决定重订阅退避。
public enum ADBDeviceTrackingError: LocalizedError, Equatable, Sendable {
    case invalidFrameLength
    case invalidUTF8
    case incompleteFrame
    case launchFailed(String)
    case readFailed
    case channelClosed
    case processExited(code: Int32, diagnostics: String)

    public var errorDescription: String? {
        switch self {
        case .invalidFrameLength: return "ADB 设备事件帧的长度字段不是有效的四位十六进制。"
        case .invalidUTF8: return "ADB 设备事件包含无效的 UTF-8 文本。"
        case .incompleteFrame: return "ADB 设备事件在帧尚未接收完整时结束。"
        case .launchFailed(let reason): return "无法启动 ADB 设备事件订阅：\(reason)"
        case .readFailed: return "无法读取 ADB 设备事件管道。"
        case .channelClosed: return "ADB 设备事件输出已关闭，客户端未正常结束。"
        case .processExited(let code, let diagnostics):
            let detail = diagnostics.isEmpty ? "没有额外诊断信息。" : diagnostics
            return "ADB 设备事件客户端异常退出（\(code)）：\(detail)"
        }
    }
}

/// ADB CLI 原样输出四位 ASCII 十六进制长度及对应 payload；分包边界与帧边界无关。
/// 单帧最大 65535 字节，已完成的帧立即移出缓存，不随订阅时间持续增长。
struct ADBDeviceTrackFrameDecoder {
    private var buffer = Data()
    private var expectedPayloadLength: Int?

    mutating func append(_ data: Data) throws -> [String] {
        buffer.append(data)
        var snapshots: [String] = []
        while true {
            if expectedPayloadLength == nil {
                guard buffer.count >= 4 else { break }
                let header = buffer.prefix(4)
                guard header.allSatisfy({ byte in
                    (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
                }), let length = Int(String(decoding: header, as: UTF8.self), radix: 16) else {
                    throw ADBDeviceTrackingError.invalidFrameLength
                }
                buffer.removeFirst(4)
                expectedPayloadLength = length
            }
            guard let length = expectedPayloadLength, buffer.count >= length else { break }
            let payload = buffer.prefix(length)
            guard let text = String(data: payload, encoding: .utf8) else {
                throw ADBDeviceTrackingError.invalidUTF8
            }
            snapshots.append(text)
            buffer.removeFirst(length)
            expectedPayloadLength = nil
            if buffer.isEmpty { buffer = Data() }
        }
        return snapshots
    }

    /// EOF 不能悄悄丢弃半个长度字段或半个 payload，否则会把失效订阅误当成空设备列表。
    mutating func finish() throws {
        guard expectedPayloadLength == nil, buffer.isEmpty else { throw ADBDeviceTrackingError.incompleteFrame }
    }
}

/// 单次流订阅的进程与管道生命周期。只有这个对象拥有自己的 Process，取消不使用 kill-server。
private final class ADBDeviceTrackingSession: @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<[ADBTransport], Error>.Continuation
    private let executableURL: URL
    /// 完成回调只弱引用注册表，避免 registry → session → registry 的保留环。
    private let onFinish: @Sendable () -> Void
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false
    private var finished = false

    init(executableURL: URL, onFinish: @escaping @Sendable () -> Void) {
        self.executableURL = executableURL
        self.onFinish = onFinish
    }

    func start(continuation: Continuation) {
        // 长期 poll/read 放在 utility 队列，不占主线程，也不阻塞 Swift 的协作线程池。
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { onFinish() }
            let child = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            child.executableURL = executableURL
            child.arguments = ["track-devices", "-l"]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = outputPipe
            child.standardError = errorPipe

            lock.lock()
            guard !cancellationRequested else {
                finished = true
                lock.unlock()
                continuation.finish()
                return
            }
            process = child
            do {
                // 启动与取消在锁内交接，避免“先取消、后启动”遗留无人管理的客户端。
                try child.run()
            } catch {
                finished = true
                process = nil
                lock.unlock()
                continuation.finish(throwing: ADBDeviceTrackingError.launchFailed(error.localizedDescription))
                return
            }
            lock.unlock()

            let output = outputPipe.fileHandleForReading
            let errors = errorPipe.fileHandleForReading
            defer {
                try? output.close()
                try? errors.close()
            }
            let result = readEvents(child: child, output: output.fileDescriptor,
                                    errors: errors.fileDescriptor, continuation: continuation)
            terminateClient(child)
            child.waitUntilExit()

            lock.lock()
            let wasCancelled = cancellationRequested
            finished = true
            process = nil
            lock.unlock()
            if wasCancelled {
                continuation.finish()
            } else if let failure = result.failure {
                continuation.finish(throwing: failure)
            } else if child.terminationStatus != 0 {
                continuation.finish(throwing: ADBDeviceTrackingError.processExited(
                    code: child.terminationStatus,
                    diagnostics: String(decoding: result.diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            } else {
                continuation.finish()
            }
        }
    }

    /// AsyncStream 终止可能发生在任意线程；只标记当前会话并结束其直接客户端。
    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        cancellationRequested = true
        let child = process
        lock.unlock()
        if let child { terminateClient(child) }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    /// 两条管道采用非阻塞读取。stderr 仅保留最后 16KB，stdout 则交给有界帧解码器。
    /// 客户端退出后最多再排空 250ms，避免后代继承写端导致永远等不到 EOF。
    private func readEvents(child: Process, output: Int32, errors: Int32,
                            continuation: Continuation) -> (diagnostics: Data, failure: ADBDeviceTrackingError?) {
        let descriptorValues = [output, errors]
        for descriptor in descriptorValues {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                return (Data(), .readFailed)
            }
        }
        var descriptors = descriptorValues.map {
            pollfd(fd: $0, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        }
        var decoder = ADBDeviceTrackFrameDecoder()
        var diagnostics = Data()
        var readBuffer = [UInt8](repeating: 0, count: 16_384)
        var exitObservedAt: UInt64?
        var outputClosedAt: UInt64?
        let finalDrainNanoseconds: UInt64 = 250_000_000

        while descriptors.contains(where: { $0.fd >= 0 }) || child.isRunning {
            if isCancelled { return (diagnostics, nil) }
            let now = DispatchTime.now().uptimeNanoseconds
            if !child.isRunning {
                if exitObservedAt == nil { exitObservedAt = now }
                if let exitObservedAt, now - exitObservedAt >= finalDrainNanoseconds { break }
            }
            if descriptors[0].fd < 0 {
                if outputClosedAt == nil { outputClosedAt = now }
                if child.isRunning, let outputClosedAt, now - outputClosedAt >= finalDrainNanoseconds {
                    return (diagnostics, .channelClosed)
                }
            }
            let status = descriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), 50)
            }
            if status < 0 {
                if errno == EINTR { continue }
                return (diagnostics, .readFailed)
            }
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                if descriptors[index].revents & Int16(POLLNVAL) != 0 { return (diagnostics, .readFailed) }
                // 每轮最多读取 256KB，持续输出也不能饿死取消和客户端退出检查。
                for _ in 0..<16 {
                    let count = readBuffer.withUnsafeMutableBytes {
                        Darwin.read(descriptors[index].fd, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        let chunk = Data(readBuffer.prefix(count))
                        if index == 0 {
                            do {
                                for payload in try decoder.append(chunk) {
                                    let snapshot = ADBOutputParser.transports(from: payload)
                                    if case .terminated = continuation.yield(snapshot) {
                                        cancel()
                                        return (diagnostics, nil)
                                    }
                                }
                            } catch let failure as ADBDeviceTrackingError {
                                return (diagnostics, failure)
                            } catch {
                                return (diagnostics, .readFailed)
                            }
                        } else {
                            diagnostics.append(chunk)
                            if diagnostics.count > 16_384 { diagnostics.removeFirst(diagnostics.count - 16_384) }
                        }
                    } else if count == 0 {
                        descriptors[index].fd = -1
                        break
                    } else {
                        if errno == EINTR { continue }
                        if errno != EAGAIN && errno != EWOULDBLOCK { return (diagnostics, .readFailed) }
                        break
                    }
                }
            }
        }
        do {
            try decoder.finish()
            return (diagnostics, nil)
        } catch let failure as ADBDeviceTrackingError {
            return (diagnostics, failure)
        } catch {
            return (diagnostics, .readFailed)
        }
    }

    /// 仅处理直接启动的 PID，不向共享 server 或进程组发送信号。
    /// SIGTERM 无响应时再结束该客户端，确保取消不会永久挂住等待过程。
    private func terminateClient(_ child: Process) {
        guard child.isRunning, child.processIdentifier > 0 else { return }
        let identifier = child.processIdentifier
        Darwin.kill(identifier, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if child.isRunning { Darwin.kill(identifier, SIGKILL) }
        }
    }
}
