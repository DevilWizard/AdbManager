import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import WebKit

/// 将已核验的品牌官方原件准备成 AppKit 可直接显示的资源。
/// 用法：swift scripts/prepare-brand-assets.swift Assets/DeviceBrands
/// 该脚本不下载资源，不读取旧 Brand-*.svg/png；所有输入必须列于官方来源清单且通过 SHA-256 校验。
private let assetFiles = FileManager.default

/// 准备失败时明确退出；Runtime 采用临时目录组装，因而不会发布只完成一半的图标集合。
private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("品牌资源准备失败：\(message)\n").utf8))
    exit(1)
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// 统计实际绘制的 PDF 图形命令，而非仅检查文件里是否声明过图像资源。
/// 递归扫描 Form XObject，避免把只有背景矩形、Logo 却被整张栅格化的 PDF 误判为矢量。
private final class PDFStatistics {
    var pathMoves = 0
    var curves = 0
    var paintedImages = 0
    var recursionDepth = 0
}

private func recordMove(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    Unmanaged<PDFStatistics>.fromOpaque(info!).takeUnretainedValue().pathMoves += 1
}

private func recordCurve(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    Unmanaged<PDFStatistics>.fromOpaque(info!).takeUnretainedValue().curves += 1
}

private func recordXObject(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    let statistics = Unmanaged<PDFStatistics>.fromOpaque(info!).takeUnretainedValue()
    var name: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &name), let name,
          let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name) else { return }
    var stream: CGPDFStreamRef?
    guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
    var subtype: UnsafePointer<CChar>?
    guard let dictionary = CGPDFStreamGetDictionary(stream) else { return }
    guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
    switch String(cString: subtype) {
    case "Image": statistics.paintedImages += 1
    case "Form":
        // 官方静态 Logo 没有递归引用；设置上限让错误 PDF 无法无限嵌套。
        guard statistics.recursionDepth < 12 else { statistics.paintedImages += 1; return }
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        let content = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, CGPDFScannerGetContentStream(scanner))
        statistics.recursionDepth += 1
        scanPDF(content, statistics: statistics)
        statistics.recursionDepth -= 1
    default: break
    }
}

private func scanPDF(_ content: CGPDFContentStreamRef, statistics: PDFStatistics) {
    guard let table = CGPDFOperatorTableCreate() else { return }
    CGPDFOperatorTableSetCallback(table, "m", recordMove)
    for command in ["c", "v", "y"] { CGPDFOperatorTableSetCallback(table, command, recordCurve) }
    CGPDFOperatorTableSetCallback(table, "Do", recordXObject)
    let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(statistics).toOpaque())
    CGPDFScannerScan(scanner)
}

/// 所有矢量输出必须含真实轮廓，且不能含实际绘制的位图；AI 内的未绘制缩略图不会影响判定。
private func validateVectorPDF(_ data: Data) throws -> [String: Any] {
    guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
          document.numberOfPages == 1, let page = document.page(at: 1),
          let image = NSImage(data: data), image.representations.contains(where: { $0 is NSPDFImageRep }) else {
        throw NSError(domain: "BrandAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法作为单页矢量 PDF 解码"])
    }
    let statistics = PDFStatistics()
    scanPDF(CGPDFContentStreamCreateWithPage(page), statistics: statistics)
    guard statistics.paintedImages == 0, statistics.curves > 0 || statistics.pathMoves > 3 else {
        throw NSError(domain: "BrandAssets", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "PDF 缺少 Logo 路径或包含栅格化 Logo（moves=\(statistics.pathMoves), curves=\(statistics.curves), images=\(statistics.paintedImages)）"])
    }
    let bounds = page.getBoxRect(.mediaBox)
    return ["path_moves": statistics.pathMoves, "curves": statistics.curves,
            "painted_images": statistics.paintedImages, "page_points": [bounds.width, bounds.height]]
}

/// 从官方透明 PNG 中读取真实非透明边界；仅 Google 官方画布留白过大时裁透明区，不重采样图形。
/// 使用 ImageIO 的 CGImage 精确裁切像素；原始文件始终保留在 Originals 中。
private func preparePNG(_ data: Data, trimTransparentPadding: Bool) throws -> (Data, [String: Any]) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let bitmap = NSBitmapImageRep(data: data) else {
        throw NSError(domain: "BrandAssets", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法解码官方 PNG"])
    }
    var details: [String: Any] = ["original_pixels": [image.width, image.height], "resampled": false]
    guard trimTransparentPadding, bitmap.hasAlpha, bitmap.bitsPerSample == 8,
          !bitmap.isPlanar, let pixels = bitmap.bitmapData else { return (data, details) }
    let sampleCount = bitmap.samplesPerPixel
    let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : sampleCount - 1
    var left = image.width, top = image.height, right = -1, bottom = -1
    var opaquePixelCount = 0
    for row in 0..<image.height {
        for column in 0..<image.width where pixels[row * bitmap.bytesPerRow + column * sampleCount + alphaOffset] > 0 {
            left = min(left, column); right = max(right, column)
            top = min(top, row); bottom = max(bottom, row)
            opaquePixelCount += 1
        }
    }
    guard right >= left, bottom >= top else { throw NSError(domain: "BrandAssets", code: 4, userInfo: [NSLocalizedDescriptionKey: "官方 PNG 完全透明"] ) }
    // 只缩短远大于图形的透明画布；保留相当于图形最长边 12% 的透明安全边距。
    let padding = Int(ceil(Double(max(right - left + 1, bottom - top + 1)) * 0.12))
    let crop = CGRect(x: max(0, left - padding), y: max(0, top - padding),
                      width: min(image.width - 1, right + padding) - max(0, left - padding) + 1,
                      height: min(image.height - 1, bottom + padding) - max(0, top - padding) + 1)
    guard let cropped = image.cropping(to: crop), let output = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "BrandAssets", code: 5, userInfo: [NSLocalizedDescriptionKey: "PNG 透明留白裁切失败"])
    }
    CGImageDestinationAddImage(destination, cropped, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "BrandAssets", code: 6) }
    details["crop_pixels"] = [crop.minX, crop.minY, crop.width, crop.height]
    details["opaque_pixels"] = opaquePixelCount
    details["runtime_pixels"] = [cropped.width, cropped.height]
    return (output as Data, details)
}

/// 串行 WebKit 转换器仅供开发时准备资源；不显示窗口、不联网，也不执行 SVG 中的脚本。
private final class BrandAssetPreparer: NSObject, WKNavigationDelegate {
    private let directory: URL
    private let staging: URL
    private var brands: [[String: Any]]
    private var result: [[String: Any]] = []
    private var index = 0
    private var webView: WKWebView?
    private var pending: [String: Any]?

    init(directory: URL, brands: [[String: Any]]) throws {
        self.directory = directory
        // 相同品牌的基础图与主题图分别准备；稳定排序便于核对来源和生成结果。
        self.brands = brands.sorted {
            let left = "\($0["id"] as! String)-\($0["appearance"] as? String ?? "base")"
            let right = "\($1["id"] as! String)-\($1["appearance"] as? String ?? "base")"
            return left < right
        }
        self.staging = directory.appendingPathComponent(".Runtime.\(UUID().uuidString)", isDirectory: true)
        super.init()
        try assetFiles.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    /// 每份输入必须位于 Originals，且与来源清单的 SHA-256 一致；不通过目录通配猜测官方素材。
    func next() {
        do {
            guard index < brands.count else { try finish(); return }
            var brand = brands[index]
            let identifier = brand["id"] as! String
            guard let sourcePath = brand["render_input"] as? String else {
                brand["status"] = "unavailable"
                brand["runtime_file"] = NSNull()
                result.append(brand); index += 1; next(); return
            }
            let sourceURL = directory.appendingPathComponent(sourcePath).standardizedFileURL
            let originalsPrefix = directory.appendingPathComponent("Originals", isDirectory: true).standardizedFileURL.path + "/"
            guard sourceURL.path.hasPrefix(originalsPrefix), let expectedDigest = brand["sha256"] as? String else {
                fail("\(identifier) 缺少可信原件路径或摘要")
            }
            let data = try Data(contentsOf: sourceURL)
            guard digest(data) == expectedDigest else { fail("\(identifier) 官方源摘要不匹配") }
            // 官网通过 CSS 或字体呈现反白标志时，运行 SVG 是精确组合后的派生文件；同时核验
            // 原轮廓与官方样式证据，来源链不能只剩一个已改色的 SVG 而失去原始规则依据。
            for (pathKey, digestKey) in [("source_input", "source_sha256"),
                                         ("style_evidence_file", "style_evidence_sha256")] {
                guard let evidencePath = brand[pathKey] as? String else { continue }
                let evidenceURL = directory.appendingPathComponent(evidencePath).standardizedFileURL
                guard evidenceURL.path.hasPrefix(originalsPrefix),
                      let evidenceDigest = brand[digestKey] as? String,
                      digest(try Data(contentsOf: evidenceURL)) == evidenceDigest else {
                    fail("\(identifier) 的官方轮廓或主题样式证据摘要不匹配")
                }
            }
            switch brand["format"] as? String {
            case "pdf":
                brand["conversion"] = "官方 PDF-compatible AI 原字节复制，仅更换扩展名"
                brand["vector_validation"] = try validateVectorPDF(data)
                try save(data, brand: brand, extension: "pdf")
                index += 1; next()
            case "png":
                let trimsPadding = identifier == "google" || brand["trim_transparent_padding"] as? Bool == true
                let (output, details) = try preparePNG(data, trimTransparentPadding: trimsPadding)
                brand["conversion"] = trimsPadding ? "只裁透明留白并保留 12% 安全边距；图形像素未重采样" : "官方 PNG 原字节复制，无转码"
                brand["bitmap_validation"] = details
                try save(output, brand: brand, extension: "png")
                index += 1; next()
            case "svg":
                pending = brand
                try renderSVG(data)
            default: fail("\(identifier) 的官方源格式尚未支持")
            }
        } catch { fail(error.localizedDescription) }
    }

    private func save(_ data: Data, brand: [String: Any], extension suffix: String) throws {
        var updated = brand
        // 基础文件名保持兼容；主题文件使用明确后缀，UI 仅按当前 colorScheme 选择原图。
        let appearance = brand["appearance"] as? String ?? "base"
        let variantSuffix = appearance == "base" ? "" : "-\(appearance)"
        let name = "Brand-\(brand["id"]!)\(variantSuffix).\(suffix)"
        try data.write(to: staging.appendingPathComponent(name), options: .atomic)
        updated["runtime_file"] = name
        updated["runtime_sha256"] = digest(data)
        updated["source_status"] = brand["status"] ?? "official"
        updated["status"] = "official"
        result.append(updated)
        print("已准备 \(name)")
    }

    /// 直接将 SVG 路径内联进页面，避免经 Canvas 或图片截图中转造成固定分辨率栅格化。
    private func renderSVG(_ data: Data) throws {
        guard var svg = String(data: data, encoding: .utf8), let start = svg.range(of: "<svg"),
              let end = svg.range(of: "</svg>", options: .backwards) else { fail("无法读取 SVG 根元素") }
        svg = String(svg[start.lowerBound..<end.upperBound])
        guard !svg.lowercased().contains("<script"), !svg.lowercased().contains("<image") else { fail("SVG 包含不支持的动态内容") }
        let expression = try NSRegularExpression(pattern: #"viewBox\s*=\s*["']([^"']+)["']"#)
        var values: [Double]
        if let match = expression.firstMatch(in: svg, range: NSRange(svg.startIndex..., in: svg)),
           let range = Range(match.range(at: 1), in: svg) {
            values = svg[range].split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
        } else {
            // Motorola 官方 24×24 SVG 使用固定 viewport，未声明 viewBox。按原始 width/height
            // 建立等价坐标范围后才放大导出，路径数据和原件均不修改，避免将 24px 图形放进 512px 空画布。
            guard let rootEnd = svg.firstIndex(of: ">") else { fail("SVG 根元素无效") }
            let root = String(svg[...rootEnd])
            func dimension(_ name: String) throws -> Double? {
                let pattern = #"\b"# + name + #"\s*=\s*["']([0-9]+(?:\.[0-9]+)?)(?:px)?["']"#
                let matcher = try NSRegularExpression(pattern: pattern)
                guard let match = matcher.firstMatch(in: root, range: NSRange(root.startIndex..., in: root)),
                      let range = Range(match.range(at: 1), in: root) else { return nil }
                return Double(root[range])
            }
            guard let sourceWidth = try dimension("width"), let sourceHeight = try dimension("height"),
                  sourceWidth > 0, sourceHeight > 0 else { fail("SVG 缺少可核验的 viewBox 或固定像素尺寸") }
            values = [0, 0, sourceWidth, sourceHeight]
            svg.insert(contentsOf: " viewBox=\"0 0 \(sourceWidth) \(sourceHeight)\"", at: rootEnd)
            pending?["viewport_preparation"] = "原 SVG 无 viewBox；按原 width/height 的等价坐标范围补充渲染 viewBox，路径未改动"
        }
        guard values.count == 4, values[2] > 0, values[3] > 0 else { fail("SVG viewBox 无效") }
        let width = 512.0
        let height = width * values[3] / values[2]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:"><style>
        html,body { margin:0; width:\(width)px; height:\(height)px; background:transparent; }
        body>svg { display:block; width:100%; height:100%; }
        </style></head><body>\(svg)</body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKPDFConfiguration()
        configuration.rect = webView.bounds
        configuration.allowTransparentBackground = true
        webView.createPDF(configuration: configuration) { [self] output in
            do {
                let data = try output.get()
                guard var brand = pending else { fail("PDF 转换缺少品牌上下文") }
                brand["conversion"] = "官方 SVG 原路径经 WebKit 导出透明矢量 PDF；未经过 Canvas 或截图"
                brand["vector_validation"] = try validateVectorPDF(data)
                try save(data, brand: brand, extension: "pdf")
                pending = nil
                self.webView = nil
                index += 1
                next()
            } catch { fail(error.localizedDescription) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }

    private func finish() throws {
        let manifest: [String: Any] = ["schema_version": 3, "retrieved_on": "2026-11-15",
            "description": "品牌官方基础/深浅主题原件及无损准备记录；商标与素材权利属于各品牌，未获来源的品牌使用 Android 兜底。", "brands": result]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        // 仅在全部品牌完成并验证后替换 Runtime；保留旧目录直至新目录已就位。
        let runtime = directory.appendingPathComponent("Runtime", isDirectory: true)
        let backup = directory.appendingPathComponent(".Runtime.previous.\(UUID().uuidString)", isDirectory: true)
        if assetFiles.fileExists(atPath: runtime.path) { try assetFiles.moveItem(at: runtime, to: backup) }
        do { try assetFiles.moveItem(at: staging, to: runtime) }
        catch {
            if assetFiles.fileExists(atPath: backup.path) { try? assetFiles.moveItem(at: backup, to: runtime) }
            throw error
        }
        if assetFiles.fileExists(atPath: backup.path) { try assetFiles.removeItem(at: backup) }
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        let officialBaseCount = result.filter { $0["status"] as? String == "official" && ($0["appearance"] as? String ?? "base") == "base" }.count
        let officialVariantCount = result.filter { $0["status"] as? String == "official" && ($0["appearance"] as? String ?? "base") != "base" }.count
        print("官方 Runtime 准备完成：\(officialBaseCount) 个品牌、\(officialVariantCount) 个主题版本；未知来源保持 Android 兜底")
        exit(0)
    }
}

guard CommandLine.arguments.count == 2 else { fail("用法：swift scripts/prepare-brand-assets.swift <Assets/DeviceBrands>") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
do {
    // 清单由来源采集任务生成；字典形式的 Samsung/Google 清单显式选择官方 AI 与 PNG 原件。
    let samsungGoogle = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("official-samsung-google.json"))) as! [String: Any]
    var brands: [[String: Any]] = []
    for (identifier, value) in samsungGoogle["brands"] as! [String: [String: Any]] {
        var brand = value
        let artifacts = brand["artifacts"] as! [[String: Any]]
        let selected = artifacts.first { ($0["path"] as! String).hasSuffix(identifier == "samsung" ? ".ai" : ".png") }!
        brand["id"] = identifier
        brand["render_input"] = selected["path"]
        brand["sha256"] = selected["sha256"]
        brand["format"] = identifier == "samsung" ? "pdf" : "png"
        brands.append(brand)
    }
    for name in ["official-china.json", "official-other.json"] {
        let fragment = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name))) as! [String: Any]
        brands.append(contentsOf: fragment["brands"] as! [[String: Any]])
    }
    let expected = Set(["samsung", "google", "xiaomi", "huawei", "honor", "oppo", "vivo", "oneplus", "motorola", "lenovo", "sony", "asus", "nokia"])
    guard brands.count == expected.count, Set(brands.compactMap { $0["id"] as? String }) == expected else { fail("官方品牌清单缺项或重复") }
    // 基础原件保持原有来源；官方深浅变体放在独立片段中，避免反白处理被误记为原始素材。
    for index in brands.indices {
        brands[index]["appearance"] = "base"
        // 旧来源片段中未声明背景的黑色/彩色基础图，统一明确为浅底安全兜底。
        if brands[index]["backing"] == nil { brands[index]["backing"] = "white" }
    }
    var variantKeys: Set<String> = []
    for name in ["official-dark-a.json", "official-dark-b.json"] {
        let fragment = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name))) as! [String: Any]
        guard let variants = fragment["brands"] as? [[String: Any]] else { fail("\(name) 缺少主题来源记录") }
        for var variant in variants {
            guard let identifier = variant["id"] as? String, expected.contains(identifier),
                  let appearance = variant["appearance"] as? String,
                  ["light", "dark", "shared"].contains(appearance) else { fail("\(name) 的品牌或主题无效") }
            let key = "\(identifier)-\(appearance)"
            guard variantKeys.insert(key).inserted else { fail("主题来源重复：\(key)") }
            if appearance == "shared" {
                // 共享表示官方同一彩色图可在浅深背景使用；只切换应用底色，不改原图像素。
                guard let index = brands.firstIndex(where: { $0["id"] as? String == identifier }) else { fail("共享主题缺少基础品牌") }
                brands[index]["backing"] = "adaptive"
                brands[index]["shared_appearance_evidence"] = variant
            } else {
                variant["backing"] = appearance == "dark" ? "black" : "white"
                brands.append(variant)
            }
        }
    }
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let preparer = try BrandAssetPreparer(directory: directory, brands: brands)
    preparer.next()
    // 超时只结束本次离线准备，不触碰运行中的 AdbManager 或已存在的 Runtime。
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) { fail("WebKit 矢量导出超时") }
    withExtendedLifetime(preparer) { RunLoop.main.run() }
} catch { fail(error.localizedDescription) }
