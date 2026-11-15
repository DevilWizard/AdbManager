import Foundation
import Darwin

/// 命令结果保留两个输出流，调用方可以区分成功输出与诊断信息。
public struct ADBCommandResult: Sendable, Equatable {
    public let standardOutput: String
    public let standardError: String
    public let exitCode: Int32

    public init(standardOutput: String = "", standardError: String = "", exitCode: Int32 = 0) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }

    public var combinedOutput: String {
        [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// 通过协议替换真实进程，测试无需连接或修改实际手机。
public protocol ADBCommandRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ADBCommandResult
}

/// 原生异步进程执行器：不经 shell 拼接，并发排空 stdout/stderr，支持超时与 Task 取消。
public struct ProcessCommandRunner: ADBCommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], timeout: TimeInterval = 12) async throws -> ADBCommandResult {
        let execution = ProcessExecution(executable: executable, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation: continuation)
            }
        } onCancel: {
            execution.stop(reason: .cancelled)
        }
    }
}

/// 单次执行的生命周期由锁保护。Process 属于这一实例，取消不会误杀共享的 adb server。
private final class ProcessExecution: @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var stopReason: ADBError?
    private var finished = false

    init(executable: URL, arguments: [String], timeout: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = max(0.05, timeout)
    }

    /// 阻塞式进程等待只放到 utility 队列，绝不占用主线程或 Swift 并发协作线程。
    func start(continuation: CheckedContinuation<ADBCommandResult, Error>) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let child = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            child.executableURL = executable
            child.arguments = arguments
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = outputPipe
            child.standardError = errorPipe

            // Finder 启动的 App 的 PATH 很短；adb 自身使用绝对路径，环境仅补充系统工具目录。
            var environment = ProcessInfo.processInfo.environment
            let inheritedPath = environment["PATH"] ?? ""
            environment["PATH"] = inheritedPath + ":/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
            child.environment = environment

            lock.lock()
            if let reason = stopReason {
                finished = true
                lock.unlock()
                continuation.resume(throwing: reason)
                return
            }
            process = child
            do {
                // 启动和取消状态切换保持原子性，避免取消先发生而进程随后仍被启动。
                try child.run()
            } catch {
                finished = true
                process = nil
                lock.unlock()
                continuation.resume(throwing: ADBError.commandFailed(error.localizedDescription))
                return
            }
            lock.unlock()

            // 使用非阻塞读取统一管理两个输出流。即使包装脚本已经退出，但它的后台后代仍
            // 持有写端，也不会无限等待 EOF；同一个截止时间覆盖进程执行和管道排空。
            let outputHandle = outputPipe.fileHandleForReading
            let errorHandle = errorPipe.fileHandleForReading
            defer {
                try? outputHandle.close()
                try? errorHandle.close()
            }
            let streams = captureStreams(from: child, output: outputHandle.fileDescriptor,
                                         error: errorHandle.fileDescriptor)

            // 超时/取消时 stop 已只向直接启动的客户端发送结束信号，并安排必要的 SIGKILL。
            // 此处不再等待任何后台后代，也不向进程组发送信号。
            child.waitUntilExit()

            lock.lock()
            finished = true
            process = nil
            let reason = stopReason
            lock.unlock()
            if let reason {
                continuation.resume(throwing: reason)
            } else {
                continuation.resume(returning: ADBCommandResult(
                    standardOutput: String(decoding: streams.output, as: UTF8.self),
                    standardError: String(decoding: streams.error, as: UTF8.self),
                    exitCode: child.terminationStatus
                ))
            }
        }
    }

    /// poll 同时观察两个非阻塞读端，每次最多等待 50ms，使 Task 取消及时生效。
    /// 输出设定独立容量上限，避免异常 adb 包装脚本无限输出耗尽 App 内存。
    private func captureStreams(from child: Process, output: Int32, error: Int32) -> (output: Data, error: Data) {
        let descriptors = [output, error]
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                stop(reason: .commandFailed("无法配置非阻塞命令输出。"))
                return (Data(), Data())
            }
        }
        var polling = descriptors.map {
            pollfd(fd: $0, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        }
        var captured = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let maximumOutputBytes = 4 * 1_024 * 1_024
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)

        while polling.contains(where: { $0.fd >= 0 }) || child.isRunning {
            lock.lock()
            let wasStopped = stopReason != nil
            lock.unlock()
            if wasStopped { break }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                stop(reason: .commandTimedOut(timeout))
                break
            }
            let remainingMilliseconds = Int32(min(50, max(1, (deadline - now) / 1_000_000)))
            let status = polling.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), remainingMilliseconds)
            }
            if status < 0 {
                if errno == EINTR { continue }
                stop(reason: .commandFailed("读取命令输出失败。"))
                break
            }
            for index in polling.indices where polling[index].fd >= 0 && polling[index].revents != 0 {
                if polling[index].revents & Int16(POLLNVAL) != 0 {
                    stop(reason: .commandFailed("命令输出管道失效。"))
                    polling[index].fd = -1
                    continue
                }
                // 单次读取后继续直到 EAGAIN，及时排空繁忙输出，避免 stdout/stderr 相互阻塞。
                while true {
                    let byteCount = buffer.withUnsafeMutableBytes {
                        Darwin.read(polling[index].fd, $0.baseAddress, $0.count)
                    }
                    if byteCount > 0 {
                        guard captured[index].count + byteCount <= maximumOutputBytes else {
                            stop(reason: .commandFailed("单个命令的输出超过 4 MB，已停止执行。"))
                            return (captured[0], captured[1])
                        }
                        captured[index].append(contentsOf: buffer.prefix(byteCount))
                    } else if byteCount == 0 {
                        polling[index].fd = -1
                        break
                    } else {
                        if errno == EINTR { continue }
                        if errno != EAGAIN && errno != EWOULDBLOCK {
                            stop(reason: .commandFailed("读取命令输出失败。"))
                        }
                        break
                    }
                }
            }
        }
        return (captured[0], captured[1])
    }

    /// 先温和结束单个客户端；若进程无响应，稍后升级为 SIGKILL，保证超时真的能够结束。
    func stop(reason: ADBError) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if stopReason == nil { stopReason = reason }
        let child = process
        lock.unlock()
        guard let child, child.isRunning else { return }
        let identifier = child.processIdentifier
        guard identifier > 0 else { return }
        Darwin.kill(identifier, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if child.isRunning { Darwin.kill(identifier, SIGKILL) }
        }
    }
}

/// 只检查明确的常见位置与 PATH；不会扫描用户磁盘，也不会自动安装或替换 SDK。
public enum ADBLocator {
    public static func locate(customPath: String? = nil) -> URL? {
        let manager = FileManager.default
        if let customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: customPath).expandingTildeInPath
            return manager.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        let environment = ProcessInfo.processInfo.environment
        let sdkLocations = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]]
            .compactMap { $0 }.map { $0 + "/platform-tools/adb" }
        let home = manager.homeDirectoryForCurrentUser.path
        let commonLocations = [home + "/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        let pathLocations = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/adb" }
        return (sdkLocations + commonLocations + pathLocations)
            .first { manager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
