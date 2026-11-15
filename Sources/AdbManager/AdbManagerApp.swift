import AdbManagerCore
import AppKit
import SwiftUI

/// 单窗口原生 macOS 应用；设备功能通过 AppModel 与核心模块协调。
@main
struct AdbManagerApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AdbManagerApplicationDelegate.self) private var applicationDelegate

    /// 无窗口 smoke test 用于验证打包产物、图标与真实 ADB 只读访问。
    init() {
        if CommandLine.arguments.contains("--smoke-test") {
            Self.runSmokeTest()
        }
    }

    var body: some Scene {
        Window("AdbManager", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 940, minHeight: 680)
                .onAppear {
                    applicationDelegate.prepareForTermination = { [weak model = model] in
                        model?.prepareForApplicationTermination()
                    }
                }
                .task { await model.monitor() }
        }
        .defaultSize(width: 1120, height: 790)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .toolbar) {
                Button("刷新设备") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isRefreshing || model.isPerformingAction)
                Button("选择 ADB…") { model.chooseADB() }
                    .disabled(model.isPerformingAction)
            }
        }
    }

    /// 此入口只查询设备，不修改无线监听、手机代理或用户偏好。
    private static func runSmokeTest() -> Never {
        guard let executable = ADBLocator.locate() else {
            print("SMOKE_TEST_FAILED: 未找到 ADB")
            exit(2)
        }
        guard Bundle.main.url(forResource: "AndroidHead", withExtension: "png") != nil,
              Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil else {
            print("SMOKE_TEST_FAILED: 应用图标资源未打包")
            exit(3)
        }
        Task.detached {
            do {
                let service = ADBService(executableURL: executable)
                let devices = try await service.devices()
                print("ADB: \(executable.path)")
                print("DEVICES: \(devices.count)")
                for device in devices {
                    print("DEVICE: \(device.serial) \(device.name) TRANSPORTS: \(device.transports.count)")
                }
                print("SMOKE_TEST_OK")
                exit(0)
            } catch {
                print("SMOKE_TEST_FAILED: \(error.localizedDescription)")
                exit(4)
            }
        }
        dispatchMain()
    }
}

/// 在 macOS 的退出边界同步结束本 App 的长期 ADB 客户端，避免留下孤儿监听。
@MainActor
final class AdbManagerApplicationDelegate: NSObject, NSApplicationDelegate {
    /// 使用弱模型的闭包由窗口建立，不持有窗口或设备的额外生命周期。
    var prepareForTermination: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        prepareForTermination?()
        prepareForTermination = nil
    }
}
