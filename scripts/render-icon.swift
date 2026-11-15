import AppKit
import Foundation
import WebKit

/// 使用系统 WebKit 按 SVG 本身的渐变与路径生成透明 PNG，避免引入图像依赖或重画图标。
/// 用法：swift scripts/render-icon.swift Assets/android-head_3D.svg Assets
final class IconRenderer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// 输出目录中分别保存适用于界面的等比 PNG，以及生成 ICNS 所需的正方形母版。
    private let outputDirectory: URL

    /// 强持有隐藏的 WebView，使异步图片解码及 Canvas 渲染完成前对象不会被释放。
    private var webView: WKWebView?

    /// 原始 SVG 来自 Android 官方资源，数据直接作为图片载入，不注入可执行脚本。
    private let svgData: Data

    init(svgData: Data, outputDirectory: URL) {
        self.svgData = svgData
        self.outputDirectory = outputDirectory
    }

    /// 创建透明 Canvas；两个输出都保持原图宽高比，不添加背景或改变图形。
    func render() {
        let configuration = WKWebViewConfiguration()
        // 使用内存数据存储，不为一次性图标转换创建用户浏览缓存或站点数据。
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "rendered")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024), configuration: configuration)
        view.navigationDelegate = self
        webView = view

        let svgBase64 = svgData.base64EncodedString()
        let html = """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
        <script>
        const image = new Image();
        image.onload = () => {
            // Canvas 默认透明。等比图供界面使用；正方形图供 macOS 图标尺寸派生。
            function png(width, height, contentWidth) {
                const canvas = document.createElement('canvas');
                canvas.width = width;
                canvas.height = height;
                const scale = Math.min(contentWidth / image.naturalWidth, height / image.naturalHeight);
                const w = image.naturalWidth * scale;
                const h = image.naturalHeight * scale;
                canvas.getContext('2d').drawImage(image, (width - w) / 2, (height - h) / 2, w, h);
                return canvas.toDataURL('image/png').split(',')[1];
            }
            window.webkit.messageHandlers.rendered.postMessage({
                image: png(1024, 600, 1024),
                icon: png(1024, 1024, 896)
            });
        };
        image.onerror = () => window.webkit.messageHandlers.rendered.postMessage({error: 'SVG 解码失败'});
        image.src = 'data:image/svg+xml;base64,\(svgBase64)';
        </script></body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }

    /// 只接受固定字段的 PNG 数据；失败时返回明确错误，避免写出不完整资源。
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: String] else {
            fail("渲染器返回了无效数据")
        }
        if let error = payload["error"] { fail(error) }
        guard let imageValue = payload["image"], let iconValue = payload["icon"],
              let imageData = Data(base64Encoded: imageValue), let iconData = Data(base64Encoded: iconValue) else {
            fail("无法解码 PNG 数据")
        }
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try imageData.write(to: outputDirectory.appendingPathComponent("AndroidHead.png"), options: .atomic)
            try iconData.write(to: outputDirectory.appendingPathComponent("AppIcon1024.png"), options: .atomic)
            print("已生成透明 AndroidHead.png 与 1024px 图标母版")
            exit(0)
        } catch {
            fail("写入图标失败：\(error.localizedDescription)")
        }
    }

    /// WebKit 加载失败时及时退出，方便脚本或 CI 定位资源问题。
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("WebKit 渲染失败：\(error.localizedDescription)")
    }
}

/// 将命令行资源错误写入标准错误并以非零状态结束。
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("用法：swift render-icon.swift <源 SVG 路径> <输出目录>")
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let svgData = try? Data(contentsOf: sourceURL) else { fail("无法读取源 SVG") }

// 仅创建后台渲染上下文，不展示窗口、不激活应用，也不访问网络。
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let renderer = IconRenderer(svgData: svgData, outputDirectory: outputURL)
renderer.render()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { fail("WebKit 图标渲染超时") }
RunLoop.main.run()
