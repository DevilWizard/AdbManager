import XCTest
@testable import AdbManagerCore

/// 真实子进程只运行系统工具，不启动 adb server，也不连接设备。
final class ProcessCommandRunnerTests: XCTestCase {
    func testArgumentsArePassedLiterallyInsteadOfEvaluatedByShell() async throws {
        let payload = "$(touch /tmp/adbmanager-should-not-exist); echo hi"
        let result = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", payload], timeout: 3
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, payload)
    }

    func testBothOutputStreamsCanExceedPipeCapacityWithoutDeadlock() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("该机器未安装系统 Python，跳过管道容量测试。")
        }
        let script = "import sys; sys.stdout.write('a' * 131072); sys.stdout.flush(); sys.stderr.write('b' * 131072); sys.stderr.flush()"
        let result = try await ProcessCommandRunner().run(executable: python, arguments: ["-c", script], timeout: 8)
        XCTAssertEqual(result.standardOutput.utf8.count, 131072)
        XCTAssertEqual(result.standardError.utf8.count, 131072)
    }

    func testTimeoutTerminatesOnlyTheClientProcess() async {
        let started = Date()
        do {
            _ = try await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 0.1)
            XCTFail("sleep 应超时")
        } catch {
            XCTAssertEqual(error as? ADBError, .commandTimedOut(0.1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testTaskCancellationTerminatesTheClientProcess() async throws {
        let task = Task {
            try await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: 30)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("已取消的进程不应返回成功")
        } catch {
            XCTAssertEqual(error as? ADBError, .cancelled)
        }
    }

    /// 包装脚本退出后，后台后代仍可能持有 stdout/stderr。deadline 必须覆盖管道排空，
    /// 同时只停止本次直接启动的客户端，不能为等待 EOF 而误杀无关进程组。
    func testTimeoutAlsoBoundsPipeDrainAfterParentProcessHasExited() async {
        let started = Date()
        do {
            _ = try await ProcessCommandRunner().run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 3 & exit 0"], timeout: 0.15
            )
            XCTFail("后台后代持有管道时应在 deadline 返回，而非等待它结束")
        } catch {
            XCTAssertEqual(error as? ADBError, .commandTimedOut(0.15))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }
}
