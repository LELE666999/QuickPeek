import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO
import PDFKit
import AVFoundation
import AVKit
import Quartz
import QuickLookThumbnailing
import WebKit
import Vision
import Translation
import NaturalLanguage
import SDWebImage
import SDWebImageWebPCoder

extension Notification.Name {
    static let quickPeekStopPlayback = Notification.Name("QuickPeekStopPlayback")
}

struct MetaItem: Identifiable { let id = UUID(); let label: String; let value: String }
enum FileCategory { case image, pdf, document, media, code, web, folder, other }

private struct RecognizedTextBlock: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let confidence: Double
    let normalizedBoundingBox: CGRect
}

private struct RecognizedCodeItem: Identifiable, Hashable {
    let id = UUID()
    let payload: String
    let symbology: String
}

private enum TranslationTargetChoice: String, CaseIterable, Identifiable {
    case simplifiedChinese
    case english
    case japanese
    case korean
    case french
    case german
    case spanish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simplifiedChinese: return "翻成中文"
        case .english: return "Translate to English"
        case .japanese: return "日本語に翻訳"
        case .korean: return "한국어로 번역"
        case .french: return "Traduire en français"
        case .german: return "Auf Deutsch übersetzen"
        case .spanish: return "Traducir al español"
        }
    }

    var language: Locale.Language {
        switch self {
        case .simplifiedChinese:
            return Locale.Language(identifier: "zh-Hans")
        case .english:
            return Locale.Language(identifier: "en")
        case .japanese:
            return Locale.Language(identifier: "ja")
        case .korean:
            return Locale.Language(identifier: "ko")
        case .french:
            return Locale.Language(identifier: "fr")
        case .german:
            return Locale.Language(identifier: "de")
        case .spanish:
            return Locale.Language(identifier: "es")
        }
    }

    var shortTitle: String {
        switch self {
        case .simplifiedChinese: return "中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        }
    }
}

private struct OCRHighlightOverlay: View {
    let highlights: [CGRect]
    let accentColor: Color

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(highlights.enumerated()), id: \.offset) { _, rect in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accentColor.opacity(0.14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(accentColor.opacity(0.92), lineWidth: 1.6)
                        }
                        .frame(
                            width: max(2, geo.size.width * rect.width),
                            height: max(2, geo.size.height * rect.height)
                        )
                        .position(
                            x: geo.size.width * rect.midX,
                            y: geo.size.height * (1 - rect.midY)
                        )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct OCRRegionSelectionOverlay: View {
    let isActive: Bool
    let selectionRect: CGRect?
    let onSelectionChanged: (CGRect?) -> Void
    let onSelectionCommitted: (CGRect) -> Void
    @State private var dragStartPoint: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let selectionRect {
                    let rect = denormalize(selectionRect, in: geo.size)
                    Rectangle()
                        .fill(Color.cyan.opacity(0.16))
                        .overlay {
                            Rectangle()
                                .strokeBorder(Color.cyan.opacity(0.95), style: StrokeStyle(lineWidth: 1.8, dash: [8, 6]))
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isActive ? Color.white.opacity(0.001) : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isActive else { return }
                        if dragStartPoint == nil {
                            dragStartPoint = clampedPoint(value.startLocation, in: geo.size)
                        }
                        let start = dragStartPoint ?? clampedPoint(value.startLocation, in: geo.size)
                        let current = clampedPoint(value.location, in: geo.size)
                        onSelectionChanged(normalize(start: start, end: current, in: geo.size))
                    }
                    .onEnded { value in
                        guard isActive else { return }
                        let start = dragStartPoint ?? clampedPoint(value.startLocation, in: geo.size)
                        let end = clampedPoint(value.location, in: geo.size)
                        let rect = normalize(start: start, end: end, in: geo.size)
                        dragStartPoint = nil
                        onSelectionChanged(rect)
                        if rect.width > 0.02, rect.height > 0.02 {
                            onSelectionCommitted(rect)
                        }
                    }
            )
            .allowsHitTesting(isActive)
        }
    }

    private func clampedPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(0, point.x), size.width),
            y: min(max(0, point.y), size.height)
        )
    }

    private func normalize(start: CGPoint, end: CGPoint, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let minX = min(start.x, end.x) / size.width
        let maxX = max(start.x, end.x) / size.width
        let topY = min(start.y, end.y) / size.height
        let bottomY = max(start.y, end.y) / size.height
        let normalizedY = 1 - bottomY
        return CGRect(x: minX, y: normalizedY, width: maxX - minX, height: bottomY - topY)
    }

    private func denormalize(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * size.width,
            y: (1 - rect.maxY) * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }
}

private final class SelectableOCRTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags.contains(.command), chars == "c" {
            copy(self)
            return true
        }

        if flags.contains(.command), chars == "a" {
            selectAll(self)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "全选", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }
}

private struct OCRSelectableTextBlockView: NSViewRepresentable {
    let text: String
    let isInteractive: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        let textView = SelectableOCRTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor.clear
        textView.insertionPointColor = .clear
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.52),
            .foregroundColor: NSColor.white
        ]
        textView.font = .systemFont(ofSize: 14, weight: .medium)
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.string = text
        textView.autoresizingMask = [.width, .height]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let textView = nsView.subviews.first as? SelectableOCRTextView else { return }
        textView.string = text
        textView.isSelectable = isInteractive
        textView.alphaValue = isInteractive ? 1 : 0.001
    }
}

private struct OCRSelectableTextOverlay: View {
    let blocks: [RecognizedTextBlock]
    let isInteractive: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(blocks) { block in
                    let rect = denormalize(block.normalizedBoundingBox, in: geo.size)
                    OCRSelectableTextBlockView(text: block.text, isInteractive: isInteractive)
                        .frame(width: max(rect.width, 28), height: max(rect.height, 22))
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .allowsHitTesting(isInteractive)
    }

    private func denormalize(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * size.width,
            y: (1 - rect.maxY) * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }
}

private struct SaveStatus: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let iconName: String
    let tint: Color

    static func success(_ title: String) -> SaveStatus {
        SaveStatus(title: title, iconName: "checkmark.circle.fill", tint: .green)
    }

    static func error(_ title: String) -> SaveStatus {
        SaveStatus(title: title, iconName: "exclamationmark.triangle.fill", tint: .orange)
    }
}

@MainActor
final class PDFDocumentController: ObservableObject {
    @Published var document: PDFDocument?
    @Published var currentPageIndex = 0
    @Published var pageImages: [NSImage] = []
    @Published var isRendering = false

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.document = PDFDocument(url: fileURL)
        Task { await renderPages() }
    }

    var pageCount: Int { document?.pageCount ?? 0 }

    func setCurrentPage(_ index: Int) {
        guard pageImages.indices.contains(index) else { return }
        currentPageIndex = index
    }

    private func renderPages() async {
        guard document != nil else {
            pageImages = []
            return
        }
        isRendering = true
        let fileURL = self.fileURL
        let currentIndex = currentPageIndex
        let rendered = await Task.detached(priority: .userInitiated) { () -> [NSImage] in
            guard let document = PDFDocument(url: fileURL) else { return [] }
            var rendered: [NSImage] = []
            rendered.reserveCapacity(document.pageCount)

            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let aspectRatio = max(bounds.height / max(bounds.width, 1), 1)
                let targetWidth: CGFloat = 1200
                let targetSize = CGSize(
                    width: targetWidth,
                    height: max(1600, targetWidth * aspectRatio)
                )
                rendered.append(page.thumbnail(of: targetSize, for: .mediaBox))
            }
            return rendered
        }.value
        pageImages = rendered
        currentPageIndex = min(currentIndex, max(0, rendered.count - 1))
        isRendering = false
    }

    func copyCurrentPage() {
        guard pageImages.indices.contains(currentPageIndex) else { return }
        let image = pageImages[currentPageIndex]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    func copyDocument() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([fileURL as NSURL])
    }

    func copyPage(at index: Int) {
        guard pageImages.indices.contains(index) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([pageImages[index]])
    }

    func exportPage(at index: Int) {
        guard pageImages.indices.contains(index) else { return }
        exportPageImage(pageImages[index], sourceURL: fileURL, pageIndex: index)
    }

    func deleteCurrentPage() {
        guard let document, document.pageCount > 1 else { return }
        document.removePage(at: currentPageIndex)
        document.write(to: fileURL)
        self.document = PDFDocument(url: fileURL)
        Task { await renderPages() }
        let newIndex = min(currentPageIndex, max(0, document.pageCount - 1))
        currentPageIndex = newIndex
    }
}

@MainActor
final class PresentationDocumentController: ObservableObject {
    @Published var currentPageIndex = 0
    @Published var pageImages: [NSImage] = []
    @Published var isRendering = false
    @Published var renderErrorMessage: String?

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var pageCount: Int { pageImages.count }
    var didFail: Bool { renderErrorMessage != nil && pageImages.isEmpty && !isRendering }

    func setCurrentPage(_ index: Int) {
        guard pageImages.indices.contains(index) else { return }
        currentPageIndex = index
    }

    func copyCurrentPage() {
        copyPage(at: currentPageIndex)
    }

    func copyPage(at index: Int) {
        guard pageImages.indices.contains(index) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([pageImages[index]])
    }

    func copyDocument() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([fileURL as NSURL])
    }

    func exportCurrentPage() {
        exportPage(at: currentPageIndex)
    }

    func exportPage(at index: Int) {
        guard pageImages.indices.contains(index) else { return }
        exportPageImage(pageImages[index], sourceURL: fileURL, pageIndex: index)
    }

    func renderPages() async {
        guard pageImages.isEmpty else { return }
        isRendering = true
        renderErrorMessage = nil
        do {
            let images = try await NativePresentationRenderer().render(fileURL)
            try Task.checkCancellation()
            pageImages = images
            currentPageIndex = min(currentPageIndex, max(0,pageImages.count-1))
        } catch is CancellationError {
            pageImages = []
        } catch {
            pageImages = []
            renderErrorMessage = error.localizedDescription
        }
        isRendering = false
    }
}

/// Uses only macOS Quick Look and embedded WebKit; never launches a presentation app.
@MainActor
final class NativePresentationRenderer: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var webView: WKWebView?
    private var timeout: Task<Void, Never>?

    func render(_ source: URL) async throws -> [NSImage] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickPeekSlides-"+UUID().uuidString,isDirectory:true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { webView?.stopLoading(); webView?.navigationDelegate=nil; webView=nil; timeout?.cancel(); try? FileManager.default.removeItem(at:directory) }
        let worker = Task.detached {
            runProcess(executableURL:URL(fileURLWithPath:"/usr/bin/qlmanage"),arguments:["-p","-o",directory.path,source.path],timeout:45)
        }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        guard result.exitCode == 0 else { throw failure("系统未能生成这份演示文稿的页面预览。") }
        let enumerator = FileManager.default.enumerator(at:directory,includingPropertiesForKeys:nil)
        let files = (enumerator?.allObjects as? [URL]) ?? []
        if let pdf = files.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            return renderPDFPageImages(from:pdf)
        }
        guard let html = files.first(where: { $0.lastPathComponent == "Preview.html" }) else { throw failure("系统没有提供可分页的文档内容。") }
        let configuration=WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web=WKWebView(frame:NSRect(x:0,y:0,width:1440,height:1000),configuration:configuration)
        web.navigationDelegate=self
        webView=web
        try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            continuation=pending
            web.loadFileURL(html.resolvingSymlinksInPath(),allowingReadAccessTo:directory)
            timeout=Task { [weak self] in
                try? await Task.sleep(for:.seconds(30))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(self?.failure("生成页面超时，请重新预览。") ?? NSError(domain:"QuickPeek",code:1)))
            }
        }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                self?.webView?.stopLoading()
                self?.finish(.failure(CancellationError()))
            }
        })
        try Task.checkCancellation()
        let values=try await web.callAsyncJavaScript("""
            await document.fonts.ready;
            await Promise.all(Array.from(document.images).map(i => i.decode().catch(() => {})));
            const slides=Array.from(document.querySelectorAll('div.slide'));
            return slides.map(s => {const r=s.getBoundingClientRect();return {x:r.x+scrollX,y:r.y+scrollY,w:r.width,h:r.height};});
            """,arguments:[:],in:nil,contentWorld:.page)
        guard let pages=values as? [[String:Double]], !pages.isEmpty else { throw failure("此文档没有可识别的幻灯片页面。") }
        var images:[NSImage]=[]
        for page in pages {
            try Task.checkCancellation()
            guard let x=page["x"],let y=page["y"],let width=page["w"],let height=page["h"],width>0,height>0 else { throw failure("幻灯片尺寸无效。") }
            let config=WKPDFConfiguration()
            config.rect=CGRect(x:x,y:y,width:width,height:height)
            let data=try await web.pdf(configuration:config)
            guard let document=PDFDocument(data:data),let slide=document.page(at:0) else { throw failure("无法绘制幻灯片。") }
            images.append(slide.thumbnail(of:CGSize(width:1600,height:1600*height/width),for:.mediaBox))
        }
        return images
    }
    private func failure(_ message:String) -> NSError { NSError(domain:"QuickPeek.Presentation",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    private func finish(_ result:Result<Void,Error>) { timeout?.cancel();let pending=continuation;continuation=nil;pending?.resume(with:result) }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { finish(.success(())) }
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) { finish(.failure(error)) }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) { finish(.failure(failure("页面渲染进程已退出，请重新预览。"))) }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

private func renderPDFPageImages(from pdfURL: URL) -> [NSImage] {
    guard let document = PDFDocument(url: pdfURL) else { return [] }
    var rendered: [NSImage] = []
    rendered.reserveCapacity(document.pageCount)

    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else { continue }
        let bounds = page.bounds(for: .mediaBox)
        let aspectRatio = max(bounds.height / max(bounds.width, 1), 1)
        let targetWidth: CGFloat = 1200
        let targetSize = CGSize(
            width: targetWidth,
            height: max(1600, targetWidth * aspectRatio)
        )
        rendered.append(page.thumbnail(of: targetSize, for: .mediaBox))
    }

    return rendered
}

private func exportPageImage(_ image: NSImage, sourceURL: URL, pageIndex: Int) {
    let panel = NSSavePanel()
    let baseName = sourceURL.deletingPathExtension().lastPathComponent
    panel.nameFieldStringValue = "\(baseName)_page_\(pageIndex + 1).png"
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true

    guard panel.runModal() == .OK, let outputURL = panel.url else { return }
    guard let data = pngData(from: image) else { return }
    try? data.write(to: outputURL)
}

private func pngData(from image: NSImage) -> Data? {
    guard let cgImage = image.quickPeekCGImage else { return nil }
    return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
}

private func runProcess(executableURL: URL, arguments: [String], timeout: TimeInterval) -> (exitCode: Int32, text: String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            waitGroup.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while waitGroup.wait(timeout: .now() + 0.1) == .timedOut {
            if Task.isCancelled || Date() >= deadline {
                if process.isRunning { process.terminate() }
                _ = waitGroup.wait(timeout: .now()+2)
                return (1, Task.isCancelled ? "转换已取消。" : "转换超时。")
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    } catch {
        return (1, error.localizedDescription)
    }
}

struct PDFDocumentBrowserView: View {
    @ObservedObject var controller: PDFDocumentController

    var body: some View {
        HStack(spacing: 12) {
            thumbnailRail
                .frame(width: 132)

            ZoomableView(passesClicksThrough: true) {
                pageCanvas
            }
            .environment(\.previewNavigation, nil)
        }
    }

    private var thumbnailRail: some View {
        ScrollView {
            Group {
                if controller.pageImages.isEmpty && controller.isRendering {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在加载页面…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(controller.pageImages.enumerated()), id: \.offset) { index, image in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    controller.setCurrentPage(index)
                                }
                            } label: {
                                PDFThumbnailCell(image: image, index: index, isCurrentPage: index == controller.currentPageIndex)
                            }
                            .contextMenu {
                                Button("复制这一页") {
                                    controller.copyPage(at: index)
                                }
                                Button("导出这一页 PNG…") {
                                    controller.exportPage(at: index)
                                }
                                Divider()
                                Button("复制原文件") {
                                    controller.copyDocument()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                }
        )
    }

    private var pageCanvas: some View {
        GeometryReader { geo in
            let contentWidth = max(320, min(geo.size.width - 28, 980))

            ScrollViewReader { proxy in
                Group {
                    if controller.pageImages.isEmpty && controller.isRendering {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text("PDF 页面加载中…")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 18) {
                                ForEach(Array(controller.pageImages.enumerated()), id: \.offset) { index, image in
                                    Image(nsImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: contentWidth)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(.white.opacity(0.14), lineWidth: 1)
                                        }
                                        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
                                        .contextMenu {
                                            Button("复制这一页") {
                                                controller.copyPage(at: index)
                                            }
                                            Button("导出这一页 PNG…") {
                                                controller.exportPage(at: index)
                                            }
                                            Divider()
                                            Button("复制原文件") {
                                                controller.copyDocument()
                                            }
                                        }
                                        .id(index)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(12)
                        }
                        .onChange(of: controller.currentPageIndex) { _, newValue in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(newValue, anchor: .top)
                            }
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.white.opacity(0.06), lineWidth: 1)
                        }
                )
            }
        }
    }
}

private struct PDFThumbnailCell: View {
    let image: NSImage
    let index: Int
    let isCurrentPage: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(isCurrentPage ? 0.34 : 0.12), lineWidth: 1)
                )
            Text("第 \(index + 1) 页")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCurrentPage ? Color.white.opacity(0.10) : Color.black.opacity(0.12))
        )
    }
}

struct PresentationDocumentBrowserView: View {
    @ObservedObject var controller: PresentationDocumentController

    var body: some View {
        Group {
            if controller.didFail {
                ZoomableView(passesClicksThrough: true) {
                    QuickLookDocumentView(fileURL: controller.fileURL)
                }
                .environment(\.previewNavigation, nil)
            } else {
                HStack(spacing: 12) {
                    thumbnailRail
                        .frame(width: 132)

                    Group {
                        if controller.pageImages.isEmpty {
                            pageCanvas
                        } else {
                            ContinuousPresentationPages(controller: controller)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private var thumbnailRail: some View {
        ScrollView {
            Group {
                if controller.pageImages.isEmpty && controller.isRendering {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在生成页面…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(controller.pageImages.enumerated()), id: \.offset) { index, image in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    controller.setCurrentPage(index)
                                }
                            } label: {
                                PDFThumbnailCell(image: image, index: index, isCurrentPage: index == controller.currentPageIndex)
                            }
                            .contextMenu {
                                Button("复制这一页") {
                                    controller.copyPage(at: index)
                                }
                                Button("导出这一页 PNG…") {
                                    controller.exportPage(at: index)
                                }
                                Divider()
                                Button("复制原文件") {
                                    controller.copyDocument()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                }
        )
    }

    private var pageCanvas: some View {
        GeometryReader { geo in
            let contentWidth = max(320, min(geo.size.width - 28, 980))

            ScrollViewReader { proxy in
                Group {
                    if controller.pageImages.isEmpty && controller.isRendering {
                        ZStack(alignment: .bottom) {
                            QuickLookDocumentView(fileURL: controller.fileURL)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在生成左侧页面预览…")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(Color.black.opacity(0.52))
                                    .overlay {
                                        Capsule(style: .continuous)
                                            .stroke(.white.opacity(0.14), lineWidth: 1)
                                    }
                            }
                            .foregroundStyle(.white)
                            .padding(.bottom, 14)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 18) {
                                ForEach(Array(controller.pageImages.enumerated()), id: \.offset) { index, image in
                                    Image(nsImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: contentWidth)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(.white.opacity(0.14), lineWidth: 1)
                                        }
                                        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
                                        .contextMenu {
                                            Button("复制这一页") {
                                                controller.copyPage(at: index)
                                            }
                                            Button("导出这一页 PNG…") {
                                                controller.exportPage(at: index)
                                            }
                                            Divider()
                                            Button("复制原文件") {
                                                controller.copyDocument()
                                            }
                                        }
                                        .id(index)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(12)
                        }
                        .onChange(of: controller.currentPageIndex) { _, newValue in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(newValue, anchor: .top)
                            }
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.white.opacity(0.06), lineWidth: 1)
                        }
                )
            }
        }
    }
}

// PDFKit supplies a real continuous document viewport: native pinch and two-axis
// scrolling move document coordinates rather than scaling a SwiftUI ScrollView.
private final class PresentationPagesPDFView: PDFView {
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            autoScales = false
            scaleFactor = min(maxScaleFactor, max(minScaleFactor,
                scaleFactor * exp(event.scrollingDeltaY * 0.006)))
        } else {
            super.scrollWheel(with: event)
        }
    }
}

private struct ContinuousPresentationPages: NSViewRepresentable {
    @ObservedObject var controller: PresentationDocumentController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> PresentationPagesPDFView {
        let view = PresentationPagesPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.backgroundColor = .clear
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 10
        let document = PDFDocument()
        for image in controller.pageImages {
            if let page = PDFPage(image: image) { document.insert(page, at: document.pageCount) }
        }
        view.document = document
        view.autoScales = true
        context.coordinator.view = view
        NotificationCenter.default.addObserver(context.coordinator,
            selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateNSView(_ view: PresentationPagesPDFView, context: Context) {
        let coordinator = context.coordinator
        let index = controller.currentPageIndex
        guard index != coordinator.currentIndex, let page = view.document?.page(at: index) else { return }
        coordinator.currentIndex = index
        view.go(to: page)
    }

    static func dismantleNSView(_ view: PresentationPagesPDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.view = nil
    }

    @MainActor final class Coordinator: NSObject {
        let controller: PresentationDocumentController
        weak var view: PDFView?
        var currentIndex = 0
        init(controller: PresentationDocumentController) { self.controller = controller }
        @objc func pageChanged() {
            guard let view, let page = view.currentPage, let document = view.document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound, index != currentIndex else { return }
            currentIndex = index
            // Do not publish inside an NSViewRepresentable update or turn ordinary
            // scrolling into a go(to:) request on the next SwiftUI update.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentIndex == index, self.view != nil else { return }
                self.controller.setCurrentPage(index)
            }
        }
    }
}

private struct PresentationPreview: View {
    let fileURL: URL
    var body: some View { PresentationPageHost(fileURL:fileURL).id(fileURL) }
}

private struct PresentationPageHost: View {
    let fileURL: URL
    @StateObject private var controller: PresentationDocumentController
    init(fileURL:URL) {
        self.fileURL=fileURL
        _controller=StateObject(wrappedValue:PresentationDocumentController(fileURL:fileURL))
    }
    var body: some View { PresentationDocumentBrowserView(controller:controller).task { await controller.renderPages() } }
}

struct QuickLookDocumentView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> NSView {
        if let view = QLPreviewView(frame: .zero, style: .normal) {
            view.autostarts = true
            view.previewItem = fileURL as NSURL
            return view
        }

        let fallback = NSTextField(labelWithString: "当前系统不支持此文档的内嵌预览")
        fallback.alignment = .center
        fallback.textColor = .secondaryLabelColor
        fallback.font = .systemFont(ofSize: 13)
        let container = NSView()
        fallback.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fallback)
        NSLayoutConstraint.activate([
            fallback.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            fallback.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let preview = nsView as? QLPreviewView {
            preview.previewItem = fileURL as NSURL
        }
    }
}

final class AnimatedImageContainerView: NSView {
    let imageView = SDAnimatedImageView()

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        imageView.wantsLayer = true
        imageView.layer?.contentsGravity = .resizeAspect
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct AnimatedImagePreview: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> AnimatedImageContainerView {
        let container = AnimatedImageContainerView()
        apply(to: container.imageView)
        return container
    }

    func updateNSView(_ nsView: AnimatedImageContainerView, context: Context) {
        apply(to: nsView.imageView)
    }

    private func apply(to imageView: SDAnimatedImageView) {
        guard let image = resolvedAnimatedImage(for: fileURL) else {
            imageView.image = nil
            return
        }
        imageView.image = image
    }
}

final class HoverPlayerView: AVPlayerView {
    private let zoomedVideoLayer = AVPlayerLayer()
    var previewScale: CGFloat = 1
    var previewOffset: CGSize = .zero

    override func layout() {
        super.layout()
        updateZoomedVideo()
    }

    func updateZoomedVideo() {
        guard let overlay = contentOverlayView else { return }
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = true
        let zoomed = abs(previewScale - 1) > 0.001
        overlay.layer?.backgroundColor = zoomed ? NSColor.black.cgColor : NSColor.clear.cgColor
        if zoomedVideoLayer.superlayer == nil { overlay.layer?.addSublayer(zoomedVideoLayer) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomedVideoLayer.player = zoomed ? player : nil
        zoomedVideoLayer.isHidden = !zoomed
        zoomedVideoLayer.videoGravity = .resizeAspect
        let size = overlay.bounds.size
        zoomedVideoLayer.frame = NSRect(
            x: (size.width - size.width * previewScale) / 2 + previewOffset.width,
            y: (size.height - size.height * previewScale) / 2 - previewOffset.height,
            width: size.width * previewScale, height: size.height * previewScale)
        CATransaction.commit()
    }

    func clearZoomedVideo() { zoomedVideoLayer.player = nil }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Keep AVKit's control hierarchy alive. Replacing it on every hover can
        // leave a detached visual-effect surface behind on macOS 26.
        controlsStyle = .floating
        showsFullScreenToggleButton = true
        videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct DecodedImageAsset {
    let image: NSImage
    let aspectRatio: CGFloat
    let isAnimated: Bool
    let frameCount: Int
}

private struct AsyncImagePreviewPayload {
    let image: NSImage?
    let animatedImage: NSImage?
    let aspectRatio: CGFloat?
    let pixelSize: CGSize?
    let isAnimated: Bool
}

private struct SVGMetadata {
    let title: String?
    let viewBox: CGRect?
    let canvasSize: CGSize?
    let widthAttribute: String?
    let heightAttribute: String?
}

private func parseSVGMetadata(from content: String) -> SVGMetadata {
    func extractAttribute(_ attribute: String) -> String? {
        guard let range = content.range(of: #"\#(attribute)\s*=\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let raw = String(content[range])
        return raw
            .replacingOccurrences(of: #"\#(attribute)\s*=\s*""#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func numericValue(from raw: String?) -> CGFloat? {
        guard let raw else { return nil }
        let numeric = raw.replacingOccurrences(of: #"[^0-9.\-]+"#, with: "", options: .regularExpression)
        guard let parsed = Double(numeric), parsed > 0 else { return nil }
        return CGFloat(parsed)
    }

    let title: String? = {
        guard let titleStart = content.range(of: "<title>", options: .caseInsensitive),
              let titleEnd = content.range(of: "</title>", options: .caseInsensitive, range: titleStart.upperBound..<content.endIndex) else {
            return nil
        }
        let value = String(content[titleStart.upperBound..<titleEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }()

    let viewBox: CGRect? = {
        guard let viewBoxRange = content.range(of: #"viewBox\s*=\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let raw = String(content[viewBoxRange])
        let value = raw
            .replacingOccurrences(of: #"viewBox\s*=\s*""#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\"", with: "")
        let parts = value.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }()

    let widthAttribute = extractAttribute("width")
    let heightAttribute = extractAttribute("height")
    let canvasSize: CGSize? = {
        if let viewBox {
            return CGSize(width: viewBox.width, height: viewBox.height)
        }
        guard let width = numericValue(from: widthAttribute),
              let height = numericValue(from: heightAttribute),
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }()

    return SVGMetadata(
        title: title,
        viewBox: viewBox,
        canvasSize: canvasSize,
        widthAttribute: widthAttribute,
        heightAttribute: heightAttribute
    )
}

private func systemSVGImage(from fileURL: URL) -> NSImage? {
    guard let image = NSImage(contentsOf: fileURL) else { return nil }
    let measuredSize = bestImageSize(for: image)
    if measuredSize.width > 0, measuredSize.height > 0 {
        image.size = measuredSize
    }
    return image
}

private func resolvedAnimatedImage(for fileURL: URL) -> SDAnimatedImage? {
    if let animated = SDAnimatedImage(contentsOfFile: fileURL.path) {
        return animated
    }

    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return SDAnimatedImage(data: data)
}

private func decodeImageAsset(from fileURL: URL) -> DecodedImageAsset? {
    if fileURL.pathExtension.lowercased() == "svg",
       let svgImage = systemSVGImage(from: fileURL) {
        let size = bestImageSize(for: svgImage)
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        return DecodedImageAsset(
            image: svgImage,
            aspectRatio: width / height,
            isAnimated: false,
            frameCount: 1
        )
    }

    if let animated = resolvedAnimatedImage(for: fileURL) {
        let size = bestImageSize(for: animated)
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let frameCount = Int(animated.sd_imageFrameCount)
        return DecodedImageAsset(
            image: animated,
            aspectRatio: width / height,
            isAnimated: frameCount > 1,
            frameCount: frameCount
        )
    }

    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    let decoded = SDImageCodersManager.shared.decodedImage(with: data, options: nil) ?? NSImage(data: data)
    guard let decoded else { return nil }

    let size = bestImageSize(for: decoded)
    let width = max(size.width, 1)
    let height = max(size.height, 1)
    return DecodedImageAsset(
        image: decoded,
        aspectRatio: width / height,
        isAnimated: false,
        frameCount: 1
    )
}

private func bestImageSize(for image: NSImage) -> CGSize {
    for representation in image.representations {
        if let bitmap = representation as? NSBitmapImageRep, bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 {
            return CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        }
    }
    return image.size
}

private extension NSImage {
    var quickPeekCGImage: CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        if let cgImage = cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            return cgImage
        }

        guard let data = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let cgImage = bitmap.cgImage else {
            return nil
        }
        return cgImage
    }
}

private func animatedFramesPayload(from image: NSImage) -> (frames: [SDImageFrame], loopCount: UInt)? {
    guard let animatedImage = image as? SDAnimatedImage else { return nil }
    let frameCount = Int(animatedImage.animatedImageFrameCount)
    guard frameCount > 1 else { return nil }

    var frames: [SDImageFrame] = []
    frames.reserveCapacity(frameCount)

    for index in 0..<frameCount {
        guard let frameImage = animatedImage.animatedImageFrame(at: UInt(index)) else { continue }
        let duration = max(animatedImage.animatedImageDuration(at: UInt(index)), 0.02)
        frames.append(SDImageFrame(image: frameImage, duration: duration))
    }

    guard !frames.isEmpty else { return nil }
    return (frames, UInt(animatedImage.animatedImageLoopCount))
}

private func fittedPreviewSize(in available: CGSize, aspectRatio: CGFloat) -> CGSize {
    guard available.width > 0, available.height > 0, aspectRatio > 0 else { return .zero }

    let availableRatio = available.width / available.height
    if availableRatio > aspectRatio {
        let height = available.height
        return CGSize(width: height * aspectRatio, height: height)
    } else {
        let width = available.width
        return CGSize(width: width, height: width / aspectRatio)
    }
}

private func comfortableImagePreviewSize(in available: CGSize, aspectRatio: CGFloat) -> CGSize {
    guard available.width > 0, available.height > 0, aspectRatio > 0 else { return .zero }
    let insetScale: CGFloat = 0.72
    return fittedPreviewSize(
        in: CGSize(width: available.width * insetScale, height: available.height * insetScale),
        aspectRatio: aspectRatio
    )
}

private func decodedTextContent(from data: Data) -> (text: String, encodingName: String)? {
    let candidates: [(String.Encoding, String)] = [
        (.utf8, "UTF-8"),
        (.utf16, "UTF-16"),
        (.utf16LittleEndian, "UTF-16 LE"),
        (.utf16BigEndian, "UTF-16 BE"),
        (.isoLatin1, "ISO Latin 1"),
        (.macOSRoman, "Mac OS Roman"),
        (.ascii, "ASCII")
    ]

    for (encoding, name) in candidates {
        if let text = String(data: data, encoding: encoding), !text.isEmpty {
            return (text, name)
        }
    }
    return nil
}

private func isLikelyTextData(_ data: Data) -> Bool {
    guard !data.isEmpty else { return true }
    let sample = data.prefix(min(data.count, 4096))
    if sample.contains(0) { return false }
    let printable = sample.reduce(into: 0) { count, byte in
        if byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte < 127) || byte >= 128 {
            count += 1
        }
    }
    return Double(printable) / Double(sample.count) > 0.88
}

private func canPreviewAsText(_ fileURL: URL) -> Bool {
    guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return false }
    guard isLikelyTextData(data) else { return false }
    return decodedTextContent(from: data) != nil
}

private func requestQuickLookThumbnail(for fileURL: URL, size: CGSize = CGSize(width: 500, height: 500), completion: @escaping @MainActor (NSImage?) -> Void) {
    let request = QLThumbnailGenerator.Request(fileAt: fileURL, size: size, scale: 2.0, representationTypes: .all)
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
        let image = rep?.nsImage
        DispatchQueue.main.async {
            completion(image)
        }
    }
}

private func loadImagePreviewPayload(for fileURL: URL, maxPixelSize: Int = 3200) async -> AsyncImagePreviewPayload {
    if fileURL.pathExtension.lowercased() == "svg" {
        return await Task.detached(priority: .userInitiated) {
            let svgImage = systemSVGImage(from: fileURL)
            let size = svgImage.map(bestImageSize(for:))
            let aspectRatio: CGFloat? = {
                guard let size, size.width > 0, size.height > 0 else { return nil }
                return size.width / size.height
            }()
            return AsyncImagePreviewPayload(
                image: svgImage,
                animatedImage: nil,
                aspectRatio: aspectRatio,
                pixelSize: size,
                isAnimated: false
            )
        }.value
    }

    return await Task.detached(priority: .userInitiated) {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return AsyncImagePreviewPayload(image: nil, animatedImage: nil, aspectRatio: nil, pixelSize: nil, isAnimated: false)
        }

        let frameCount = CGImageSourceGetCount(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? CGFloat
        let height = properties?[kCGImagePropertyPixelHeight] as? CGFloat
        let pixelSize: CGSize? = {
            guard let width, let height, width > 0, height > 0 else { return nil }
            return CGSize(width: width, height: height)
        }()
        let aspectRatio: CGFloat? = {
            guard let width, let height, width > 0, height > 0 else { return nil }
            return width / height
        }()

        if frameCount > 1 {
            return AsyncImagePreviewPayload(
                image: nil,
                animatedImage: nil,
                aspectRatio: aspectRatio,
                pixelSize: pixelSize,
                isAnimated: true
            )
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        if let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            let image = NSImage(cgImage: cgThumbnail, size: .zero)
            return AsyncImagePreviewPayload(
                image: image,
                animatedImage: nil,
                aspectRatio: aspectRatio,
                pixelSize: pixelSize,
                isAnimated: false
            )
        }

        return AsyncImagePreviewPayload(image: nil, animatedImage: nil, aspectRatio: aspectRatio, pixelSize: pixelSize, isAnimated: false)
    }.value
}

struct AspectFittedPreview<Content: View>: View {
    let aspectRatio: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let available = CGSize(width: max(0, geo.size.width - 20), height: max(0, geo.size.height - 20))
            let fitted = fittedPreviewSize(in: available, aspectRatio: aspectRatio)

            ZStack {
                Color.clear

                content()
                    .frame(width: fitted.width, height: fitted.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
final class FFmpegSupport {
    static let shared = FFmpegSupport()

    let ffmpegURL: URL?
    let versionOutput: String
    let encodersOutput: String
    let muxersOutput: String

    private init() {
        let candidates = [
            "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/opt/ffmpeg-full/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        let detectedFFmpegs = candidates.compactMap { path -> (url: URL, version: String, encoders: String, muxers: String)? in
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }

            let url = URL(fileURLWithPath: path)
            let version = FFmpegSupport.run(ffmpegURL: url, arguments: ["-hide_banner", "-version"])
            guard !version.isEmpty else { return nil }

            return (
                url,
                version,
                FFmpegSupport.run(ffmpegURL: url, arguments: ["-hide_banner", "-encoders"]),
                FFmpegSupport.run(ffmpegURL: url, arguments: ["-hide_banner", "-muxers"])
            )
        }

        let selectedFFmpeg = detectedFFmpegs.first { ffmpeg in
            ffmpeg.version.contains("--enable-libwebp") &&
            (ffmpeg.encoders.contains("libwebp_anim") || ffmpeg.encoders.contains("libwebp"))
        } ?? detectedFFmpegs.first

        if let selectedFFmpeg {
            ffmpegURL = selectedFFmpeg.url
            versionOutput = selectedFFmpeg.version
            encodersOutput = selectedFFmpeg.encoders
            muxersOutput = selectedFFmpeg.muxers
        } else {
            ffmpegURL = nil
            versionOutput = ""
            encodersOutput = ""
            muxersOutput = ""
        }
    }

    var isInstalled: Bool { ffmpegURL != nil }

    func supportsEncoder(_ encoder: String) -> Bool {
        encodersOutput.contains(encoder)
    }

    func supportsMuxer(_ muxer: String) -> Bool {
        muxersOutput.contains(" \(muxer)")
    }

    var supportsAnimatedWebP: Bool {
        versionOutput.contains("--enable-libwebp") &&
        (supportsEncoder("libwebp_anim") || supportsEncoder("libwebp"))
    }

    private static func run(ffmpegURL: URL, arguments: [String], timeout: TimeInterval = 3) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = ffmpegURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let waitGroup = DispatchGroup()
            waitGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                waitGroup.leave()
            }

            if waitGroup.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                return ""
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

/// NSViewRepresentable wrapper for WKWebView to render HTML files
struct WebFileView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct TransparentPreviewBackdrop: View {
    var body: some View {
        GeometryReader { geo in
            let tile: CGFloat = 18
            let columns = max(Int(ceil(geo.size.width / tile)), 1)
            let rows = max(Int(ceil(geo.size.height / tile)), 1)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.035))

                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<columns, id: \.self) { column in
                                Rectangle()
                                    .fill((row + column).isMultiple(of: 2) ? Color.white.opacity(0.045) : Color.black.opacity(0.045))
                                    .frame(width: tile, height: tile)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .allowsHitTesting(false)
    }
}

/// NSViewRepresentable wrapper for AVPlayerView — safe lifecycle management
struct StableVideoPlayer: View {
    let player: AVPlayer
    var showsPlaybackControls: Bool = true
    @StateObject private var zoom = ZoomState()
    @Environment(\.previewNavigation) private var navigate

    var body: some View {
        GeometryReader { geo in
            NativeStableVideoPlayer(player: player, scale: zoom.scale, offset: zoom.offset,
                                    showsPlaybackControls: showsPlaybackControls)
                .overlay {
                    ZoomGestureOverlay(zoomState: zoom, onNavigate: navigate, passesClicksThrough: true)
                }
                .onAppear { zoom.containerSize = geo.size }
                .onChange(of: geo.size) { _, size in
                    zoom.containerSize = size
                    zoom.clampOffset()
                }
        }
    }
}

struct NativeStableVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    let scale: CGFloat
    let offset: CGSize
    var showsPlaybackControls: Bool = true

    func makeNSView(context: Context) -> HoverPlayerView {
        let view = HoverPlayerView()
        view.player = player
        view.videoGravity = .resizeAspect
        view.controlsStyle = showsPlaybackControls ? .floating : .none
        view.showsFullScreenToggleButton = showsPlaybackControls
        return view
    }

    func updateNSView(_ nsView: HoverPlayerView, context: Context) {
        let style: AVPlayerViewControlsStyle = showsPlaybackControls ? .floating : .none
        if nsView.controlsStyle != style { nsView.controlsStyle = style }
        nsView.showsFullScreenToggleButton = showsPlaybackControls
        if nsView.player !== player {
            nsView.player = player
        }
        nsView.previewScale = scale
        nsView.previewOffset = offset
        nsView.updateZoomedVideo()
    }

    static func dismantleNSView(_ nsView: HoverPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.clearZoomedVideo()
        nsView.player = nil
    }
}

struct WebMVideoPreview: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.currentURL = fileURL
        loadVideo(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.currentURL != fileURL else { return }
        context.coordinator.currentURL = fileURL
        loadVideo(in: webView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func loadVideo(in webView: WKWebView) {
        let fileName = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileURL.lastPathComponent
        let html = """
        <!doctype html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                html, body {
                    width: 100%;
                    height: 100%;
                    margin: 0;
                    overflow: hidden;
                    background: transparent;
                }
                body {
                    display: grid;
                    place-items: center;
                }
                video {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                    background:
                        linear-gradient(45deg, rgba(255,255,255,.10) 25%, transparent 25%),
                        linear-gradient(-45deg, rgba(255,255,255,.10) 25%, transparent 25%),
                        linear-gradient(45deg, transparent 75%, rgba(255,255,255,.10) 75%),
                        linear-gradient(-45deg, transparent 75%, rgba(255,255,255,.10) 75%);
                    background-size: 24px 24px;
                    background-position: 0 0, 0 12px, 12px -12px, -12px 0;
                    border-radius: 12px;
                }
            </style>
        </head>
        <body>
            <video src="\(fileName)" autoplay muted loop controls playsinline></video>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: fileURL.deletingLastPathComponent())
        webView.allowsBackForwardNavigationGestures = false
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var currentURL: URL?
    }
}

final class CodeEditorTextView: NSTextView {
    var onSave: (() -> Void)?
    var onTextChange: ((String) -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if chars == "s", flags.contains(.command) || flags.contains(.control) {
            onSave?()
            return
        }

        if chars == "f", flags.contains(.command), flags.contains(.control) {
            let sender = NSMenuItem()
            sender.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            performFindPanelAction(sender)
            return
        }

        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?(string)
    }
}

final class CodeLineNumberView: NSView {
    weak var textView: NSTextView?
    let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    init(textView: NSTextView?) {
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: 48, height: 100))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let text = textView.string as NSString
        var lineNumber = 1
        var index = 0

        while index < characterRange.location {
            lineNumber += 1
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
        }

        var lineIndex = characterRange.location
        while lineIndex < NSMaxRange(characterRange) {
            let lineRange = text.lineRange(for: NSRange(location: lineIndex, length: 0))
            let glyphRangeForLine = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRangeForLine, in: textContainer)
            lineRect.origin.y += textView.textContainerOrigin.y - visibleRect.origin.y

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let label = "\(lineNumber)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            let x = bounds.width - labelSize.width - 10
            let y = lineRect.minY + max(0, (lineRect.height - labelSize.height) / 2)
            label.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)

            lineNumber += 1
            lineIndex = NSMaxRange(lineRange)
        }
    }
}

enum CodeSyntaxHighlighter {
    static func highlight(_ text: String, language: String, isDark: Bool) -> NSAttributedString {
        func color(_ dark: UInt32, _ light: UInt32) -> NSColor {
            let value = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        let foreground = color(0xDCE3EF, 0x24292F)
        let keyword = color(0xFF6B97, 0xA626A4)
        let string = color(0xB6DE78, 0x3B701A)
        let number = color(0xC5A3FF, 0x795E26)
        let attribute = color(0xFFD078, 0x986801)
        let punctuation = color(0x82CCE5, 0x007F99)
        let comment = color(0x8896AE, 0x647383)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.defaultTabInterval = 32
        paragraph.tabStops = []
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: foreground, .paragraphStyle: paragraph
        ])
        let full = NSRange(location: 0, length: result.length)
        let ext = language.lowercased()
        let markup = ["xml", "html", "htm", "svg", "xhtml", "vue", "svelte"].contains(ext)
        func paint(_ pattern: String, _ color: NSColor, group: Int = 0) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: text, range: full) {
                let range = match.range(at: group)
                if range.location != NSNotFound { result.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
        paint(#"\b(?:0x[\da-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, number)
        if markup {
            paint(#"</?|/?>|<\?|\?>"#, punctuation)
            paint(#"(?<=<)[!?]?[A-Za-z_][\w:.-]*|(?<=</)[A-Za-z_][\w:.-]*"#, keyword)
            paint(#"[A-Za-z_:][\w:.-]*(?=\s*=)"#, attribute)
        } else {
            paint(#"\b(?:import|from|as|class|struct|enum|extension|func|function|def|return|if|else|elif|for|while|do|switch|case|break|continue|try|catch|throw|throws|async|await|let|var|const|static|public|private|protected|internal|final|override|new|delete|in|of|is|not|and|or|true|false|null|nil|None|True|False|self|this|super|guard|defer|protocol|interface|type|export|default|package|use|fn|impl|mut|pub|match|SELECT|FROM|WHERE|JOIN|INSERT|UPDATE|CREATE|TABLE)\b"#, keyword)
            paint(#"\b[A-Za-z_$][\w$]*(?=\s*\()"#, punctuation)
            paint(#"[A-Za-z_$][\w$-]*(?=\s*:)"#, attribute)
        }
        // One alternation keeps comment markers inside strings, and quotes inside comments, inert.
        var protectedPattern = #"\"(?:\\[\s\S]|[^\"\\])*\"|'(?:\\[\s\S]|[^'\\])*'|`(?:\\[\s\S]|[^`\\])*`"#
        if markup {
            protectedPattern = #"<!--[\s\S]*?(?:-->|$)|<!\[CDATA\[[\s\S]*?(?:\]\]>|$)|"# + protectedPattern
        } else {
            let hashComments = ["py", "rb", "sh", "bash", "zsh", "yaml", "yml", "toml", "conf", "env", "r"].contains(ext)
            protectedPattern = #"/\*[\s\S]*?(?:\*/|$)|//[^\r\n]*|"# + (hashComments ? #"#[^\r\n]*|"# : "") + protectedPattern
            if ["sql", "lua"].contains(ext) { protectedPattern = #"--[^\r\n]*|"# + protectedPattern }
        }
        if let regex = try? NSRegularExpression(pattern: protectedPattern) {
            let nsText = text as NSString
            for match in regex.matches(in: text, range: full) {
                let token = nsText.substring(with: match.range)
                let isComment = ["<!--", "/*", "//", "#", "--"].contains { token.hasPrefix($0) }
                result.addAttribute(.foregroundColor, value: isComment ? comment : string, range: match.range)
            }
        }
        return result
    }
}

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var isDark: Bool
    var language: String = "xml"
    let onSave: () -> Void

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: CodeEditorTextView?
        weak var lineNumberView: CodeLineNumberView?
        var isUpdatingProgrammatically = false
        var lastHighlightedText: String?
        var lastHighlightedStyle = ""
        var boundsObservation: NSObjectProtocol?
        var textObservation: NSObjectProtocol?

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingProgrammatically, let textView else { return }
            parent.text = textView.string
            highlight()
            lineNumberView?.needsDisplay = true
        }

        func highlight() {
            guard let textView else { return }
            let style = "\(parent.language)-\(parent.isDark)"
            guard lastHighlightedText != textView.string || lastHighlightedStyle != style else { return }
            lastHighlightedText = textView.string
            lastHighlightedStyle = style
            let attributed = CodeSyntaxHighlighter.highlight(textView.string, language: parent.language, isDark: parent.isDark)
            // Apply presentation attributes only: never replace characters or touch undo history.
            guard let storage = textView.textStorage else { return }
            isUpdatingProgrammatically = true
            storage.beginEditing()
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
                storage.setAttributes(attributes, range: range)
            }
            storage.endEditing()
            isUpdatingProgrammatically = false
        }

        @MainActor
        func layoutTextView(in scrollView: NSScrollView) {
            guard let textView, let textContainer = textView.textContainer else { return }
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.layoutManager?.ensureLayout(for: textContainer)
            let usedWidth = textView.layoutManager?.usedRect(for: textContainer).width ?? 0
            let width = max(scrollView.contentView.bounds.width, usedWidth + 28)
            textView.frame.size.width = width
            textView.frame.size.height = max(scrollView.contentView.bounds.height, textView.frame.height)

            textView.layoutManager?.ensureLayout(for: textContainer)
            textView.needsDisplay = true
            lineNumberView?.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = CodeEditorTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 14, height: 16)
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = isDark ? .white : .black
        textView.string = text
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.onSave = onSave
        textView.onTextChange = { [weak coordinator = context.coordinator] value in
            guard let coordinator, !coordinator.isUpdatingProgrammatically else { return }
            coordinator.parent.text = value
            coordinator.lineNumberView?.needsDisplay = true
        }

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        context.coordinator.textView = textView
        context.coordinator.lineNumberView = nil
        context.coordinator.highlight()
        context.coordinator.boundsObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak scrollView, weak coordinator = context.coordinator] _ in
            guard let scrollView, let coordinator else { return }
            coordinator.layoutTextView(in: scrollView)
        }
        context.coordinator.textObservation = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification,
            object: textView,
            queue: .main
        ) { _ in }

        DispatchQueue.main.async {
            context.coordinator.layoutTextView(in: scrollView)
        }

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.onSave = onSave
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = isDark ? .white : .black

        if textView.string != text {
            context.coordinator.isUpdatingProgrammatically = true
            textView.string = text
            context.coordinator.isUpdatingProgrammatically = false
            context.coordinator.lineNumberView?.needsDisplay = true
        }
        context.coordinator.highlight()
        if let scrollView = textView.enclosingScrollView {
            context.coordinator.layoutTextView(in: scrollView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let boundsObservation = coordinator.boundsObservation {
            NotificationCenter.default.removeObserver(boundsObservation)
        }
        if let textObservation = coordinator.textObservation {
            NotificationCenter.default.removeObserver(textObservation)
        }
    }
}

// MARK: - Zoomable Content Wrapper

private struct PreviewNavigationKey: EnvironmentKey {
    static var defaultValue: ((Int) -> Void)? { nil }
}

extension EnvironmentValues {
    var previewNavigation: ((Int) -> Void)? {
        get { self[PreviewNavigationKey.self] }
        set { self[PreviewNavigationKey.self] = newValue }
    }
}

struct PreviewScrollNavigation {
    private var accumulated: CGFloat = 0
    private var didNavigate = false
    private var lastEventTime: TimeInterval = 0

    mutating func direction(deltaX: CGFloat, deltaY: CGFloat, time: TimeInterval,
                            began: Bool, momentum: Bool) -> Int? {
        if began || time - lastEventTime > 0.25 {
            accumulated = 0
            didNavigate = false
        }
        lastEventTime = time
        guard !momentum, !didNavigate, abs(deltaY) > abs(deltaX) else { return nil }
        accumulated += deltaY
        guard abs(accumulated) >= 36 else { return nil }
        didNavigate = true
        return accumulated < 0 ? 1 : -1
    }
}

private final class PreviewScrollSession: NSObject {
    var navigation = PreviewScrollNavigation()
}

/// Shared zoom state — uses CALayer transform for GPU-accelerated, smooth rendering
@MainActor
final class ZoomState: ObservableObject {
    @Published var scale: CGFloat = 1.0
    @Published var offset: CGSize = .zero

    let minScale: CGFloat = 0.1
    let maxScale: CGFloat = 10.0

    /// Container size (set by GeometryReader)
    var containerSize: CGSize = .zero

    func reset(animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                scale = 1.0
                offset = .zero
            }
        } else {
            scale = 1.0
            offset = .zero
        }
    }

    func zoom(to targetScale: CGFloat, anchor: CGPoint) {
        let targetScale = targetScale.clamped(to: minScale...maxScale)
        guard scale > 0 else {
            scale = targetScale
            clampOffset()
            return
        }
        zoom(by: targetScale / scale, anchor: anchor)
    }

    func clampOffset() {
        guard scale > 1.0 else { offset = .zero; return }
        // Allow panning proportional to how much the content overflows
        let maxX = containerSize.width * (scale - 1) / 2
        let maxY = containerSize.height * (scale - 1) / 2
        offset.width = offset.width.clamped(to: -maxX...maxX)
        offset.height = offset.height.clamped(to: -maxY...maxY)
    }

    /// Zoom toward a specific point (in container coordinates)
    func zoom(by factor: CGFloat, anchor: CGPoint) {
        let oldScale = scale
        let newScale = (scale * factor).clamped(to: minScale...maxScale)
        guard abs(newScale - oldScale) > 0.001 else { return }

        // Adjust offset so the anchor point stays fixed
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        let anchorDelta = CGSize(width: anchor.x - center.x, height: anchor.y - center.y)
        let scaleDelta = newScale / oldScale

        scale = newScale
        offset.width = (offset.width - anchorDelta.width) * scaleDelta + anchorDelta.width
        offset.height = (offset.height - anchorDelta.height) * scaleDelta + anchorDelta.height

        if newScale < oldScale, oldScale > 1.001 {
            let centerPull = max(0, (newScale - 1) / max(oldScale - 1, 0.001))
            offset.width *= centerPull
            offset.height *= centerPull
        }

        if newScale <= minScale + 0.001 {
            scale = minScale
            offset = .zero
        } else if abs(newScale - 1.0) < 0.015 {
            scale = 1.0
            offset = .zero
        } else {
            clampOffset()
        }
    }
}

/// Transparent NSView overlay that captures magnify, scroll, and drag events
final class ZoomableNSView: NSView, NSGestureRecognizerDelegate {
    private static let scrollSessions = NSMapTable<NSWindow, PreviewScrollSession>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    var zoomState: ZoomState?
    var onNavigate: ((Int) -> Void)?
    var passesClicksThrough = false
    private var eventMonitor: Any?
    private var navigation = PreviewScrollNavigation()
    private var lastDragPoint: NSPoint?
    private var isMagnifying = false
    private var pinchRecognizer: NSMagnificationGestureRecognizer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let pinchRecognizer { pinchRecognizer.view?.removeGestureRecognizer(pinchRecognizer) }
        pinchRecognizer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        guard window != nil else { return }
        window?.acceptsMouseMovedEvents = true
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        // Attach to the common ancestor so native video/Quick Look children cannot
        // take the gesture away from a transparent, click-through overlay.
        (window?.contentView ?? self).addGestureRecognizer(pinch)
        pinchRecognizer = pinch
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .endGesture]) { [weak self] event in
            guard let self else { return event }
            return self.routePreviewEvent(event)
        }
    }

    func routePreviewEvent(_ event:NSEvent) -> NSEvent? {
            guard let window = self.window, event.window === window,
                  !self.isHiddenOrHasHiddenAncestor,
                  self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            // Magnification belongs to AppKit's recognizer/responder delivery.
            // A local monitor must not swallow it before recognition.
            if event.type == .magnify { return event }
            if event.type == .endGesture {
                self.isMagnifying = false
                return event
            } else {
                if !event.modifierFlags.contains(.command), (self.zoomState?.scale ?? 1) <= 1.001 && self.onNavigate == nil { return event }
                self.scrollWheel(with: event)
            }
            return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicksThrough ? nil : super.hitTest(point)
    }

    func stopMonitoring() {
        if let pinchRecognizer { pinchRecognizer.view?.removeGestureRecognizer(pinchRecognizer) }
        pinchRecognizer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        return visibleRect.contains(convert(event.locationInWindow, from: nil))
    }

    @objc private func handlePinch(_ recognizer: NSMagnificationGestureRecognizer) {
        guard let state = zoomState else { return }
        isMagnifying = recognizer.state == .began || recognizer.state == .changed
        state.zoom(by: max(0.1, 1 + recognizer.magnification), anchor: CGPoint(x: bounds.midX, y: bounds.midY))
        recognizer.magnification = 0
    }

    // MARK: - Trackpad pinch-to-zoom
    override func magnify(with event: NSEvent) {
        guard let state = zoomState else { return }
        isMagnifying = event.phase != .ended && event.phase != .cancelled
        let point = convert(event.locationInWindow,from:nil)
        let locationInView = CGPoint(x:point.x,y:isFlipped ? point.y : bounds.height-point.y)
        let factor = max(0.1,1.0 + event.magnification)
        state.zoom(by: factor, anchor: locationInView)
    }

    override func endGesture(with event: NSEvent) {
        isMagnifying = false
        super.endGesture(with: event)
    }

    // Two-finger scrolling pans only above the fitted size; otherwise it pages.
    override func scrollWheel(with event: NSEvent) {
        guard let state = zoomState else { super.scrollWheel(with: event); return }

        if event.modifierFlags.contains(.command) {
            let delta = event.scrollingDeltaY == 0 ? -event.scrollingDeltaX : event.scrollingDeltaY
            let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.006 : 0.025
            state.zoom(by: exp(delta * sensitivity).clamped(to: 0.35...2.8),
                       anchor: CGPoint(x: bounds.midX, y: bounds.midY))
            return
        }

        // During a pinch gesture, ignore scroll events (they're part of the magnify)
        if isMagnifying { return }

        if state.scale > 1.001 {
            state.offset.width += event.scrollingDeltaX
            state.offset.height += event.scrollingDeltaY
            state.clampOffset()
        } else {
            // A page change creates a new view; retain the gesture latch for its window.
            let session: PreviewScrollSession?
            if let window {
                let existing = Self.scrollSessions.object(forKey: window) ?? PreviewScrollSession()
                Self.scrollSessions.setObject(existing, forKey: window)
                session = existing
            } else {
                session = nil
            }
            var current = session?.navigation ?? navigation
            let direction = current.direction(
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                time: event.timestamp, began: event.phase == .began,
                momentum: !event.momentumPhase.isEmpty)
            navigation = current
            session?.navigation = current
            if let direction { onNavigate?(direction) }
        }
    }

    // MARK: - Drag to pan when zoomed
    override func mouseDown(with event: NSEvent) {
        guard let state = zoomState, state.scale > 1.0 else {
            super.mouseDown(with: event)
            return
        }
        lastDragPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let state = zoomState, state.scale > 1.0, let last = lastDragPoint else { return }
        let current = event.locationInWindow
        state.offset.width += current.x - last.x
        state.offset.height -= (current.y - last.y) // flip Y for SwiftUI coords
        state.clampOffset()
        lastDragPoint = current
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        if event.clickCount == 2 {
            zoomState?.reset()
        }
    }
}

/// NSViewRepresentable wrapper for the gesture overlay
struct ZoomGestureOverlay: NSViewRepresentable {
    let zoomState: ZoomState
    var onNavigate: ((Int) -> Void)? = nil
    var passesClicksThrough = false

    func makeNSView(context: Context) -> ZoomableNSView {
        let v = ZoomableNSView()
        v.zoomState = zoomState
        v.onNavigate = onNavigate
        v.passesClicksThrough = passesClicksThrough
        v.wantsLayer = true
        v.layer?.backgroundColor = .clear
        return v
    }

    func updateNSView(_ nsView: ZoomableNSView, context: Context) {
        nsView.zoomState = zoomState
        nsView.onNavigate = onNavigate
        nsView.passesClicksThrough = passesClicksThrough
    }

    static func dismantleNSView(_ nsView: ZoomableNSView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

private final class ZoomPercentDragNSView: NSView {
    weak var coordinator: ZoomPercentDragCapture.Coordinator?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        coordinator?.beginDrag(at: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        coordinator?.updateDrag(to: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        coordinator?.endDrag()
    }
}

private struct ZoomPercentDragCapture: NSViewRepresentable {
    let currentScale: CGFloat
    let minScale: CGFloat
    let maxScale: CGFloat
    let onScaleChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> ZoomPercentDragNSView {
        let view = ZoomPercentDragNSView()
        view.coordinator = context.coordinator
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: ZoomPercentDragNSView, context: Context) {
        context.coordinator.parent = self
        nsView.coordinator = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator {
        var parent: ZoomPercentDragCapture
        private var startPoint: NSPoint?
        private var startScale: CGFloat = 1.0

        init(parent: ZoomPercentDragCapture) {
            self.parent = parent
        }

        func beginDrag(at point: NSPoint) {
            startPoint = point
            startScale = parent.currentScale
        }

        func updateDrag(to point: NSPoint) {
            guard let startPoint else { return }
            let dragAmount = (point.x - startPoint.x) - (point.y - startPoint.y)
            let targetScale = (startScale * pow(1.0045, dragAmount)).clamped(to: parent.minScale...parent.maxScale)
            parent.onScaleChanged(targetScale)
        }

        func endDrag() {
            startPoint = nil
            parent.onDragEnded()
        }
    }
}

/// A wrapper that adds smooth pinch-to-zoom, scroll-to-zoom, and drag-to-pan
struct ZoomableView<Content: View>: View {
    @StateObject private var zoomState = ZoomState()
    @Environment(\.previewNavigation) private var navigate
    var showsControls: Bool = true
    var passesClicksThrough = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ZStack {
                content()
                    .scaleEffect(zoomState.scale)
                    .offset(zoomState.offset)

                ZoomGestureOverlay(zoomState: zoomState, onNavigate: navigate, passesClicksThrough: passesClicksThrough)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { zoomState.containerSize = geo.size }
            .onChange(of: geo.size) { _, newSize in
                zoomState.containerSize = newSize
                zoomState.clampOffset()
            }
            .overlay(alignment: .bottomLeading) {
                if showsControls {
                    zoomControls
                }
            }
        }
    }

    @ViewBuilder
    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button {
                let center = CGPoint(x: zoomState.containerSize.width / 2, y: zoomState.containerSize.height / 2)
                withAnimation(.easeOut(duration: 0.2)) {
                    zoomState.zoom(by: 0.7, anchor: center)
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                Circle()
                    .fill(Color.black.opacity(0.44))
                    .overlay {
                        Circle().stroke(.white.opacity(0.12), lineWidth: 1)
                    }
            }

            Text("\(Int(zoomState.scale * 100))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(minWidth: 52, minHeight: 30)
                .contentShape(Capsule())
                .overlay {
                    ZoomPercentDragCapture(
                        currentScale: zoomState.scale,
                        minScale: zoomState.minScale,
                        maxScale: zoomState.maxScale,
                        onScaleChanged: { targetScale in
                            let center = CGPoint(
                                x: zoomState.containerSize.width / 2,
                                y: zoomState.containerSize.height / 2
                            )
                            zoomState.zoom(to: targetScale, anchor: center)
                        },
                        onDragEnded: {}
                    )
                }
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.44))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(.white.opacity(0.12), lineWidth: 1)
                        }
                }

            Button {
                let center = CGPoint(x: zoomState.containerSize.width / 2, y: zoomState.containerSize.height / 2)
                withAnimation(.easeOut(duration: 0.2)) {
                    zoomState.zoom(by: 1.5, anchor: center)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                Circle()
                    .fill(Color.black.opacity(0.44))
                    .overlay {
                        Circle().stroke(.white.opacity(0.12), lineWidth: 1)
                    }
            }

            if zoomState.scale > 1.01 {
                Button {
                    zoomState.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    Circle()
                        .fill(Color.black.opacity(0.44))
                        .overlay {
                            Circle().stroke(.white.opacity(0.12), lineWidth: 1)
                        }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(8)
    }
}

struct FolderEntry: Identifiable {
    let id = UUID(); let name: String; let isDirectory: Bool; let size: UInt64
    var sizeStr: String {
        let kb = Double(size)/1024
        if kb < 1 { return "\(size) B" }
        return kb < 1024 ? String(format: "%.1f KB", kb) : String(format: "%.1f MB", kb/1024)
    }
}

private final class LongImageScrollViewHost: NSScrollView {
    var onViewportChanged: (() -> Void)?
    var onMagnificationChanged: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installPinchRecognizer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installPinchRecognizer()
    }

    private func notifyViewportChanged() {
        onViewportChanged?()
        onMagnificationChanged?(magnification)
    }

    private func installPinchRecognizer() {
        let recognizer = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
        addGestureRecognizer(recognizer)
    }

    @objc private func handlePinchGesture(_ recognizer: NSMagnificationGestureRecognizer) {
        let factor = max(0.1, 1.0 + recognizer.magnification)
        let next = (magnification * factor).clamped(to: minMagnification...maxMagnification)
        setMagnification(next, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY))
        recognizer.magnification = 0
    }

    override func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint) {
        super.setMagnification(magnification, centeredAt: point)
        notifyViewportChanged()
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        notifyViewportChanged()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = event.scrollingDeltaY == 0 ? -event.scrollingDeltaX : event.scrollingDeltaY
            guard abs(delta) > 0.2 else { return }
            let factor = 1.0 + delta * 0.01
            let next = (magnification * factor).clamped(to: minMagnification...maxMagnification)
            setMagnification(next, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY))
        } else {
            super.scrollWheel(with: event)
        }
    }
}

private enum NativeZoomAction: Equatable {
    case zoom(CGFloat)
    case reset
}

private struct NativeZoomCommand: Equatable {
    let id = UUID()
    let action: NativeZoomAction
}

private struct LongImageScrollPreview: NSViewRepresentable {
    let image: NSImage
    @Binding var magnificationValue: CGFloat
    let zoomCommand: NativeZoomCommand?

    func makeNSView(context: Context) -> LongImageScrollViewHost {
        let scrollView = LongImageScrollViewHost()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8.0
        scrollView.magnification = 1.0
        scrollView.contentView.postsBoundsChangedNotifications = true
        let magnificationBinding = $magnificationValue

        let containerView = NSView(frame: .zero)
        containerView.wantsLayer = true

        let imageView = NSImageView(frame: .zero)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 14
        imageView.layer?.masksToBounds = true

        containerView.addSubview(imageView)
        scrollView.documentView = containerView
        context.coordinator.containerView = containerView
        context.coordinator.imageView = imageView
        scrollView.onViewportChanged = { [weak scrollView, weak coordinator = context.coordinator] in
            guard let scrollView, let coordinator else { return }
            coordinator.layoutImage(in: scrollView)
        }
        scrollView.onMagnificationChanged = { value in
            magnificationBinding.wrappedValue = value
        }
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak scrollView, weak coordinator = context.coordinator] _ in
            guard let scrollView, let coordinator else { return }
            coordinator.layoutImage(in: scrollView)
        }
        context.coordinator.layoutImage(in: scrollView)
        DispatchQueue.main.async {
            context.coordinator.layoutImage(in: scrollView, keepTop: true)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: LongImageScrollViewHost, context: Context) {
        let magnificationBinding = $magnificationValue
        scrollView.onMagnificationChanged = { value in
            magnificationBinding.wrappedValue = value
        }
        context.coordinator.imageView?.image = image
        if let zoomCommand, context.coordinator.lastZoomCommandID != zoomCommand.id {
            context.coordinator.lastZoomCommandID = zoomCommand.id
            let center = NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY)
            switch zoomCommand.action {
            case .zoom(let factor):
                let next = (scrollView.magnification * factor).clamped(to: scrollView.minMagnification...scrollView.maxMagnification)
                scrollView.setMagnification(next, centeredAt: center)
            case .reset:
                scrollView.setMagnification(1.0, centeredAt: center)
            }
        }
        context.coordinator.layoutImage(in: scrollView, keepTop: false)
    }

    static func dismantleNSView(_ scrollView: LongImageScrollViewHost, coordinator: Coordinator) {
        if let observer = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var containerView: NSView?
        weak var imageView: NSImageView?
        var boundsObserver: NSObjectProtocol?
        var lastZoomCommandID: UUID?

        func layoutImage(in scrollView: NSScrollView, keepTop: Bool = false) {
            guard let containerView, let imageView, let image = imageView.image else { return }
            let viewportWidth = max(scrollView.bounds.width - 18, 240)
            let viewportHeight = max(scrollView.bounds.height, 240)
            let size = bestImageSize(for: image)
            let aspect = size.width > 0 && size.height > 0 ? size.width / size.height : 1
            let magnification = max(scrollView.magnification, 0.01)
            let imageWidth = viewportWidth
            let imageHeight = imageWidth / max(aspect, 0.01)
            let containerWidth = max(imageWidth, viewportWidth / magnification)
            let containerHeight = max(imageHeight, viewportHeight / magnification)
            let imageX = max((containerWidth - imageWidth) / 2, 0)
            let imageY = max((containerHeight - imageHeight) / 2, 0)

            containerView.frame = NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight)
            imageView.frame = NSRect(x: imageX, y: imageY, width: imageWidth, height: imageHeight)

            if keepTop || scrollView.contentView.bounds.origin == .zero {
                let visibleWidth = viewportWidth / magnification
                let visibleHeight = viewportHeight / magnification
                let centeredX = max(0, (containerWidth - visibleWidth) / 2)
                let topY = max(0, containerHeight - visibleHeight)
                scrollView.contentView.scroll(to: NSPoint(x: centeredX, y: topY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }
}

struct LiquidGlassCardModifier<S: Shape>: ViewModifier {
    let shape: S
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                shape
                    .fill(.clear)
                    .glassEffect(in: shape)
            }
            .overlay {
                shape
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
            }
    }
}

extension View {
    func liquidGlassCard<S: Shape>(in shape: S, padding: CGFloat = 0) -> some View {
        modifier(LiquidGlassCardModifier(shape: shape, padding: padding))
    }
}

struct SolidPanelModifier<S: Shape>: ViewModifier {
    let shape: S
    let fill: Color
    let stroke: Color
    let shadowOpacity: Double

    func body(content: Content) -> some View {
        content
            .background {
                shape
                    .fill(fill)
                    .overlay {
                        shape.stroke(stroke, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(shadowOpacity), radius: 20, y: 10)
            }
    }
}

extension View {
    func solidPanel<S: Shape>(
        in shape: S,
        fill: Color,
        stroke: Color,
        shadowOpacity: Double = 0.2
    ) -> some View {
        modifier(SolidPanelModifier(shape: shape, fill: fill, stroke: stroke, shadowOpacity: shadowOpacity))
    }
}

/// Manages AVPlayer lifecycle safely, preventing crashes from premature deallocation
@MainActor
class VideoPlayerManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isReady = false
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    private func startPlaybackIfPossible(_ player: AVPlayer?) {
        guard let player else { return }
        player.isMuted = false
        player.volume = 1
        player.play()
    }

    func loadVideo(url: URL) {
        cleanup()

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                // Pre-load essential properties to avoid synchronous blocking
                let _ = try await asset.load(.duration, .tracks, .isPlayable)

                // Verify asset is playable
                let isPlayable = try await asset.load(.isPlayable)
                guard isPlayable else {
                    self.isReady = false
                    return
                }

                let playerItem = AVPlayerItem(asset: asset)
                let newPlayer = AVPlayer(playerItem: playerItem)
                newPlayer.actionAtItemEnd = .pause

                // Observe player item status to know when it's truly ready
                self.statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if item.status == .readyToPlay {
                            self.isReady = true
                            self.startPlaybackIfPossible(newPlayer)
                        } else if item.status == .failed {
                            self.isReady = false
                        }
                    }
                }

                self.player = newPlayer

                // If already ready (cached), mark immediately
                if playerItem.status == .readyToPlay {
                    self.isReady = true
                    self.startPlaybackIfPossible(newPlayer)
                }
            } catch {
                self.isReady = false
            }
        }
    }

    func cleanup() {
        if let obs = timeObserver, let p = player {
            p.removeTimeObserver(obs)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isReady = false
    }

    deinit {
        // Note: deinit is nonisolated, but the properties will be cleaned up
        // via cleanup() called from onDisappear
    }
}

struct MultiFilePreviewContentView: View {
    let fileURLs: [URL]
    let onTogglePinned: (Bool) -> Void
    let onClose: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isKeyboardSelectionFocused: Bool
    @State private var selectedURL: URL
    @State private var isPinned: Bool
    @State private var openButtonLabel = "打开"

    init(
        fileURLs: [URL],
        isPinned: Bool,
        onTogglePinned: @escaping (Bool) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.fileURLs = fileURLs
        self.onTogglePinned = onTogglePinned
        self.onClose = onClose
        _selectedURL = State(initialValue: fileURLs.first ?? URL(fileURLWithPath: "/"))
        _isPinned = State(initialValue: isPinned)
    }

    private var isDark: Bool { colorScheme == .dark }
    private var fg: Color { isDark ? .white : .primary }
    private var fg2: Color { isDark ? .white.opacity(0.66) : .primary.opacity(0.62) }
    private var chromeFill: Color { isDark ? Color.black.opacity(0.42) : Color.white.opacity(0.82) }
    private var panelStroke: Color { isDark ? .white.opacity(0.10) : .black.opacity(0.06) }

    private var selectedFileURL: URL {
        fileURLs.contains(where: { $0.path == selectedURL.path }) ? selectedURL : (fileURLs.first ?? selectedURL)
    }

    private var selectedIndex: Int {
        fileURLs.firstIndex(where: { $0.path == selectedFileURL.path }) ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                GlassEffectContainer(spacing: 0) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.clear)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(isDark ? Color.black.opacity(0.10) : Color.white.opacity(0.06))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(.white.opacity(isDark ? 0.16 : 0.24), lineWidth: 1)
                        }
                        .padding(2)
                }
                .ignoresSafeArea()

                VStack(spacing: 14) {
                    toolbarRow

                    HStack(alignment: .top, spacing: 14) {
                        SelectionPreviewTile(
                            fileURL: selectedFileURL,
                            style: .stage,
                            showsMetadata: false,
                            isSelected: true
                        )
                        .id(selectedFileURL.path)
                        .environment(\.previewNavigation, { moveSelection(by: $0) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(fileURLs, id: \.path) { url in
                                        ZStack {
                                            SelectionPreviewTile(
                                                fileURL: url,
                                                style: .rail,
                                                showsMetadata: true,
                                                isSelected: url.path == selectedFileURL.path
                                            )
                                            .allowsHitTesting(false)
                                        }
                                        .id(url.path)
                                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .onTapGesture {
                                            select(url)
                                            isKeyboardSelectionFocused = true
                                        }
                                    }
                                }
                                .padding(14)
                            }
                            .onChange(of: selectedFileURL.path) { _, path in
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    proxy.scrollTo(path, anchor: .center)
                                }
                            }
                        }
                        .frame(width: min(360, max(300, geo.size.width * 0.28)))
                        .solidPanel(
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                            fill: chromeFill,
                            stroke: panelStroke,
                            shadowOpacity: 0.04
                        )
                    }
                }
                .padding(.top, max(geo.safeAreaInsets.top, 14))
                .padding(.horizontal, 16)
                .padding(.bottom, 22)
            }
        }
        .focusable(true)
        .focusEffectDisabled()
        .focused($isKeyboardSelectionFocused)
        .onAppear {
            isKeyboardSelectionFocused = true
        }
        .onMoveCommand { direction in
            switch direction {
            case .up:
                moveSelection(by: -1)
            case .down:
                moveSelection(by: 1)
            default:
                break
            }
        }
        .preferredColorScheme(settings.preferredColorScheme)
        .task(id: selectedFileURL.path) {
            await refreshOpenButtonLabel(for: selectedFileURL)
        }
        .onExitCommand { onClose() }
    }

    private func select(_ url: URL) {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedURL = url
        }
    }

    private func moveSelection(by delta: Int) {
        guard !fileURLs.isEmpty else { return }
        let nextIndex = (selectedIndex + delta).clamped(to: 0...(fileURLs.count - 1))
        guard nextIndex != selectedIndex else { return }
        select(fileURLs[nextIndex])
    }

    private var toolbarRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(fileURLs.count) 个项目")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(fg)
                    Text(selectedFileURL.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(fg2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    isPinned.toggle()
                    onTogglePinned(isPinned)
                } label: {
                    Label(isPinned ? "已钉住" : "钉住", systemImage: isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderedProminent)
                .tint(isPinned ? .orange : .gray.opacity(0.75))
                .controlSize(.large)

                Button {
                    NSWorkspace.shared.open(selectedFileURL)
                } label: {
                    Label(openButtonLabel, systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(16)
        .solidPanel(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            fill: chromeFill,
            stroke: panelStroke,
            shadowOpacity: 0.04
        )
    }

    private func pdfThumbnailCell(image: NSImage, index: Int, isCurrentPage: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(isCurrentPage ? 0.34 : 0.12), lineWidth: 1)
                )
            Text("第 \(index + 1) 页")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCurrentPage ? Color.white.opacity(0.10) : Color.black.opacity(0.12))
        )
    }

    private func refreshOpenButtonLabel(for url: URL) async {
        let path = url.path
        let label = await Task.detached(priority: .utility) {
            if let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url) {
                let name = defaultApp.deletingPathExtension().lastPathComponent
                return "用 \(name) 打开"
            }
            return "打开"
        }.value
        guard selectedFileURL.path == path else { return }
        openButtonLabel = label
    }
}

private enum SelectionPreviewTileStyle {
    case stage
    case rail
}

private struct SelectionPreviewTile: View {
    let fileURL: URL
    let style: SelectionPreviewTileStyle
    let showsMetadata: Bool
    let isSelected: Bool
    @StateObject private var videoManager = VideoPlayerManager()
    @State private var previewImage: NSImage?
    @State private var fileCategory: FileCategory = .other
    @State private var mediaAspectRatio: CGFloat = 1
    @State private var originalImagePixelSize: CGSize?
    @State private var isAnimatedImage = false
    @State private var codePreview = ""
    @State private var folderLabel = ""
    @State private var fileSizeText = ""
    @State private var formatText = ""
    @State private var detailRows: [MetaItem] = []
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Group {
            switch style {
            case .stage:
                stageBody
            case .rail:
                railBody
            }
        }
        .onAppear { loadPreview() }
        .onDisappear {
            videoManager.cleanup()
            previewImage = nil
            originalImagePixelSize = nil
            SDImageCache.shared.clearMemory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickPeekStopPlayback)) { _ in
            videoManager.cleanup()
        }
    }

    private var stageBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDark ? Color.black.opacity(0.34) : Color.white.opacity(0.88))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isDark ? .white.opacity(0.10) : .black.opacity(0.06), lineWidth: 1)
                }

            content
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var railBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(fileURL.lastPathComponent)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }

                content
                    .padding(10)
                    .frame(height: 160)
            }

            if showsMetadata {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if !fileSizeText.isEmpty {
                            Text(fileSizeText)
                                .font(.system(size: 11.5, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        if !formatText.isEmpty {
                            Text(formatText)
                                .font(.system(size: 10.5, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                    }

                    ForEach(detailRows.prefix(4)) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text(item.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.60))
                                .frame(width: 56, alignment: .leading)
                            Text(item.value)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.black.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isSelected ? .white.opacity(0.24) : .white.opacity(0.10), lineWidth: 1)
                }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch fileCategory {
        case .image:
            if isAnimatedImage {
                AspectFittedPreview(aspectRatio: mediaAspectRatio) {
                    ZoomableView(showsControls: style == .stage) {
                        AnimatedImagePreview(fileURL: fileURL)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if let image = previewImage {
                AspectFittedPreview(aspectRatio: mediaAspectRatio) {
                    ZoomableView(showsControls: style == .stage) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        case .media:
            if isWebMFile {
                ZoomableView(showsControls: style == .stage, passesClicksThrough: true) {
                    AspectFittedPreview(aspectRatio: mediaAspectRatio) {
                        WebMVideoPreview(fileURL: fileURL)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            } else if videoManager.isReady, let player = videoManager.player {
                StableVideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        case .code:
            ScrollView {
                Text(AttributedString(CodeSyntaxHighlighter.highlight(codePreview, language: fileURL.pathExtension, isDark: isDark)))
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        case .folder:
            VStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(Color.accentColor)
                Text(folderLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .pdf, .document, .web:
            if ["ppt", "pptx", "key"].contains(fileURL.pathExtension.lowercased()), style == .stage {
                PresentationPreview(fileURL: fileURL)
            } else {
                QuickLookDocumentView(fileURL: fileURL)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .other:
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iconName: String {
        switch fileCategory {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .media: return "play.rectangle.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .web: return "globe"
        case .folder: return "folder.fill"
        case .other: return "doc.fill"
        }
    }

    private func loadPreview() {
        var isDir: ObjCBool = false
        let ext = fileURL.pathExtension.lowercased()
        formatText = ext.uppercased()
        populateSharedDetails()

        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            fileCategory = .folder
            if let children = try? FileManager.default.contentsOfDirectory(atPath: fileURL.path) {
                folderLabel = "\(children.filter { !$0.hasPrefix(".") }.count) 项"
            }
            detailRows.append(MetaItem(label: "项目数", value: folderLabel))
            return
        }

        let webExts: Set<String> = ["html","htm","xhtml","shtml"]
        let svgExts: Set<String> = ["svg"]
        let codeExts: Set<String> = ["swift","py","js","ts","jsx","tsx","java","kt","c","cpp","h","m","mm","rs","go","rb","php","css","scss","json","xml","yaml","yml","toml","md","txt","text","log","out","err","trace","dump","sh","bash","zsh","sql","r","lua","dart","vue","svelte","ini","cfg","conf","config","properties","env","editorconfig","gitconfig"]
        let documentExts: Set<String> = ["pdf","doc","docx","ppt","pptx","xls","xlsx","numbers","key","pages","rtf","rtfd","odt","ods","odp","csv","tsv"]
        let mediaExts: Set<String> = ["webm", "mp4", "mov", "m4v", "avi", "mkv", "hevc"]

        if svgExts.contains(ext) {
            fileCategory = .image
            loadImage()
            return
        }

        if webExts.contains(ext) {
            fileCategory = .web
            return
        }

        if let ut = UTType(filenameExtension: ext) {
            if ut.conforms(to: .image) {
                fileCategory = .image
                loadImage()
            } else if ut.conforms(to: .pdf) {
                fileCategory = .pdf
            } else if documentExts.contains(ext) {
                fileCategory = .document
            } else if mediaExts.contains(ext) || ut.conforms(to: .audiovisualContent) {
                fileCategory = .media
                loadMedia()
            } else if codeExts.contains(ext) || ut.conforms(to: .sourceCode) || ut.conforms(to: .plainText) {
                fileCategory = .code
                loadCode()
            } else if canPreviewAsText(fileURL) {
                fileCategory = .code
                loadCode()
            } else {
                fileCategory = .other
                loadGeneratedThumbnail()
            }
        } else if mediaExts.contains(ext) {
            fileCategory = .media
            loadMedia()
        } else if codeExts.contains(ext) {
            fileCategory = .code
            loadCode()
        } else if canPreviewAsText(fileURL) {
            fileCategory = .code
            loadCode()
        } else {
            fileCategory = .other
            loadGeneratedThumbnail()
        }
    }

    private func loadImage() {
        if fileURL.pathExtension.lowercased() == "svg", let asset = decodeImageAsset(from: fileURL) {
            isAnimatedImage = false
            mediaAspectRatio = asset.aspectRatio
            originalImagePixelSize = bestImageSize(for: asset.image)
            let width = Int(originalImagePixelSize?.width.rounded() ?? asset.image.size.width.rounded())
            let height = Int(originalImagePixelSize?.height.rounded() ?? asset.image.size.height.rounded())
            detailRows.append(MetaItem(label: "尺寸", value: "\(width) × \(height) px"))
            previewImage = asset.image
            return
        }

        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return }
        isAnimatedImage = CGImageSourceGetCount(src) > 1
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int,
           w > 0, h > 0 {
            mediaAspectRatio = CGFloat(w) / CGFloat(h)
            originalImagePixelSize = CGSize(width: w, height: h)
            detailRows.append(MetaItem(label: "尺寸", value: "\(w) × \(h) px"))
        }
        if isAnimatedImage {
            detailRows.append(MetaItem(label: "预览", value: "动态图片"))
            return
        }

        Task { @MainActor in
            let path = fileURL.path
            let payload = await loadImagePreviewPayload(for: fileURL, maxPixelSize: 1400)
            guard fileURL.path == path else { return }
            if let aspectRatio = payload.aspectRatio, aspectRatio > 0 {
                mediaAspectRatio = aspectRatio
            }
            if let pixelSize = payload.pixelSize {
                originalImagePixelSize = pixelSize
            }
            previewImage = payload.image
        }
    }

    private func loadMedia() {
        if isWebMFile {
            videoManager.cleanup()
            loadWebMMediaInfoForSelection()
            return
        }

        videoManager.loadVideo(url: fileURL)
        let asset = AVURLAsset(url: fileURL)
        Task { @MainActor in
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                let naturalSize = try? await track.load(.naturalSize)
                let transform = try? await track.load(.preferredTransform)
                if let naturalSize, let transform {
                    let size = naturalSize.applying(transform)
                    let width = abs(size.width)
                    let height = abs(size.height)
                    if width > 0, height > 0 {
                        mediaAspectRatio = width / height
                        detailRows.append(MetaItem(label: "尺寸", value: "\(Int(width)) × \(Int(height))"))
                    }
                }
            }
        }
    }

    private var isWebMFile: Bool {
        fileURL.pathExtension.lowercased() == "webm"
    }

    private func loadWebMMediaInfoForSelection() {
        let url = fileURL
        Task.detached {
            guard let info = probeMediaInfo(for: url) else { return }
            await MainActor.run {
                if let width = info.width, let height = info.height, width > 0, height > 0 {
                    mediaAspectRatio = CGFloat(width) / CGFloat(height)
                    detailRows.append(MetaItem(label: "尺寸", value: "\(width) × \(height)"))
                }
                if let duration = info.duration, duration.isFinite, duration > 0 {
                    detailRows.append(MetaItem(label: "时长", value: formatDuration(duration)))
                }
            }
        }
    }

    private func loadCode() {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let decoded = decodedTextContent(from: data) else { return }
        let content = decoded.text
        codePreview = content
            .components(separatedBy: .newlines)
            .prefix(80)
            .joined(separator: "\n")
        detailRows.append(MetaItem(label: "总行数", value: "\(content.components(separatedBy: .newlines).count) 行"))
    }

    private func loadGeneratedThumbnail() {
        requestQuickLookThumbnail(for: fileURL) { image in
            previewImage = image
            if image == nil {
                previewImage = NSWorkspace.shared.icon(forFile: fileURL.path)
            }
        }
    }

    private func populateSharedDetails() {
        detailRows = []
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
            if let size = attrs[.size] as? UInt64 {
                fileSizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                detailRows.append(MetaItem(label: "大小", value: fileSizeText))
            }
            if let created = attrs[.creationDate] as? Date {
                detailRows.append(MetaItem(label: "创建", value: fmtDate(created)))
            }
            if let modified = attrs[.modificationDate] as? Date {
                detailRows.append(MetaItem(label: "修改", value: fmtDate(modified)))
            }
        }
    }

    private func fmtDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

@MainActor
private final class PreviewMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func perform(_ sender: Any?) { action() }
}

@MainActor
private func previewMenuItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
    let handler = PreviewMenuAction(action)
    let item = NSMenuItem(title: title, action: #selector(PreviewMenuAction.perform(_:)), keyEquivalent: "")
    item.target = handler
    item.representedObject = handler
    return item
}

struct SingleFilePreviewContentView: View {
    let fileURL: URL
    let isPinned: Bool
    let onTogglePinned: (Bool) -> Void
    let onClose: () -> Void
    @State private var selectedURL: URL?
    @State private var siblings: [URL] = []
    @State private var currentPinned: Bool?
    @FocusState private var isNavigationFocused: Bool

    var body: some View {
        let current = selectedURL ?? fileURL
        PreviewContentView(fileURL: current, isPinned: currentPinned ?? isPinned,
                           onTogglePinned: { pinned in
                               currentPinned = pinned
                               onTogglePinned(pinned)
                           }, onClose: onClose)
            .id(current)
            .environment(\.previewNavigation, { delta in moveSelection(by: delta, current: current) })
            .focusable(isNavigable(current))
            .focusEffectDisabled()
            .focused($isNavigationFocused)
            .onAppear { isNavigationFocused = isNavigable(current) }
            .onMoveCommand { direction in
                guard isNavigable(current) else { return }
                switch direction {
                case .up, .left: moveSelection(by: -1, current: current)
                case .down, .right: moveSelection(by: 1, current: current)
                default: break
                }
            }
            .task(id: fileURL) {
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                siblings = urls.filter { url in
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                          let type = UTType(filenameExtension: url.pathExtension) else { return false }
                    return type.conforms(to: .image) || type.conforms(to: .movie)
                }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
    }
    private func isNavigable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    private func moveSelection(by delta: Int, current: URL) {
        guard !TapSharedState.shared.timelineEditing else { return }
        guard let index = siblings.firstIndex(of: current),
              siblings.indices.contains(index + delta) else { return }
        selectedURL = siblings[index + delta]
    }
}

struct PreviewContentView: View {
    @State private var fullToolbarWidth: CGFloat = 900
    let fileURL: URL
    let onTogglePinned: (Bool) -> Void
    let onClose: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var videoManager = VideoPlayerManager()
    @StateObject private var pdfController: PDFDocumentController
    @State private var metadata: [MetaItem] = []
    @State private var heroSize = ""
    @State private var heroFileSize = ""
    @State private var heroFormat = ""
    @State private var previewImage: NSImage?
    @State private var fileCategory: FileCategory = .other
    @State private var mediaAspectRatio: CGFloat = 1
    @State private var originalImagePixelSize: CGSize?
    @State private var isAnimatedImage = false
    @State private var codeText = ""
    @State private var folderItems: [FolderEntry] = []
    @State private var isEdited = false
    @State private var isRefreshingCodeText = false
    @State private var isPinned: Bool
    @State private var showCrop = false
    @State private var showTrim = false
    @State private var showVideoCrop = false
    @State private var isConverting = false
    @State private var conversionStatus: ConversionStatus?
    @State private var textSaveStatus: SaveStatus?
    @State private var convertingTarget: ExportFormat?
    @State private var isLoadingPreview = true
    @State private var loadingMessage = "正在准备预览…"
    @State private var openButtonLabel = "打开"
    @State private var recognizedTextBlocks: [RecognizedTextBlock] = []
    @State private var recognizedCodeItems: [RecognizedCodeItem] = []
    @State private var translatedBlockTexts: [UUID: String] = [:]
    @State private var fullTranslatedText = ""
    @State private var selectedTranslationTarget: TranslationTargetChoice = .simplifiedChinese
    @State private var isRecognizingText = false
    @State private var isRecognizingCodes = false
    @State private var isTranslating = false
    @State private var recognitionStatusMessage = ""
    @State private var isSelectingOCRRegion = false
    @State private var selectedOCRRegion: CGRect?
    @State private var activeColorSampler: NSColorSampler?
    @State private var longImageMagnification: CGFloat = 1.0
    @State private var longImageZoomCommand: NativeZoomCommand?
    @Environment(\.colorScheme) private var colorScheme
    private let ffmpegSupport = FFmpegSupport.shared
    private var isDark: Bool { colorScheme == .dark }
    private var fg: Color { isDark ? .white : .primary }
    private var fg2: Color { isDark ? .white.opacity(0.66) : .primary.opacity(0.62) }
    private var divC: Color { isDark ? .white.opacity(0.12) : .white.opacity(0.2) }
    private var chromeFill: Color { isDark ? Color.black.opacity(0.42) : Color.white.opacity(0.82) }
    private var contentFill: Color { isDark ? Color.black.opacity(0.34) : Color.white.opacity(0.88) }
    private var secondaryFill: Color { isDark ? Color.black.opacity(0.22) : Color.white.opacity(0.76) }
    private var panelStroke: Color { isDark ? .white.opacity(0.10) : .black.opacity(0.06) }
    private var editorTextColor: Color { isDark ? .white.opacity(0.96) : .black.opacity(0.92) }
    private var neutralCapsuleTint: Color { isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10) }
    private var neutralCapsuleStroke: Color { isDark ? .white.opacity(0.12) : .black.opacity(0.08) }
    private var isSVGFile: Bool { fileURL.pathExtension.lowercased() == "svg" }

    init(
        fileURL: URL,
        isPinned: Bool,
        onTogglePinned: @escaping (Bool) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.fileURL = fileURL
        self.onTogglePinned = onTogglePinned
        self.onClose = onClose
        _isPinned = State(initialValue: isPinned)
        _pdfController = StateObject(wrappedValue: PDFDocumentController(fileURL: fileURL))
    }

    /// Resolve the configured app path for the current file's category
    private var configuredAppPath: String {
        let ext = fileURL.pathExtension.lowercased()
        let spreadsheetExts: Set<String> = ["xls","xlsx","csv","numbers","ods","xlsm","xlsb","tsv"]
        let documentExts: Set<String> = ["doc","docx","pages","odt","rtf","rtfd","ppt","pptx","key","odp"]
        let codeExts: Set<String> = ["swift","py","js","ts","jsx","tsx","java","kt","c","cpp","h","m","mm","rs","go","rb","php","css","scss","json","xml","yaml","yml","toml","md","txt","text","log","out","err","trace","dump","sh","bash","zsh","sql","r","lua","dart","vue","svelte","ini","cfg","conf","config","properties","env","editorconfig","gitconfig"]
        let musicExts: Set<String> = ["mp3","aac","flac","wav","aiff","m4a","ogg","wma","alac"]
        if spreadsheetExts.contains(ext) { return settings.openWithSpreadsheet }
        if documentExts.contains(ext) { return settings.openWithDocument }
        if codeExts.contains(ext) { return settings.openWithCode }
        if musicExts.contains(ext) { return settings.openWithMusic }
        return settings.openWithOther
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                bgView
                    .ignoresSafeArea()

                if showCrop, let img = previewExportImage() {
                    ImageCropView(image: img, fileURL: fileURL) {
                        showCrop = false
                        metadata = []; loadData()
                    }
                } else if showVideoCrop, fileCategory == .media {
                    VideoFrameCropView(fileURL: fileURL) {
                        showVideoCrop = false
                    }
                } else if showTrim {
                    TimelineEditorView(fileURL: fileURL) {
                        showTrim = false
                    }
                } else {
                    VStack(spacing: 14) {
                        toolbarRow(width: geo.size.width - 32)
                        HStack(alignment: .top, spacing: 14) {
                            contentArea.frame(maxWidth: .infinity, maxHeight: .infinity)
                            sidePanel.frame(width: 290)
                        }
                    }
                    .padding(.top, max(geo.safeAreaInsets.top, 14))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 22)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .preferredColorScheme(settings.preferredColorScheme)
        .onAppear { beginLoadingPreview() }
        .task(id: fileURL.path) {
            await refreshOpenButtonLabel()
        }
        .onDisappear {
            videoManager.cleanup()
            previewImage = nil
            originalImagePixelSize = nil
            SDImageCache.shared.clearMemory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickPeekStopPlayback)) { _ in
            videoManager.cleanup()
        }
        .onChange(of: pdfController.currentPageIndex) { _, _ in
            clearRecognitionResults(keepStatus: true)
        }
        .onExitCommand { onClose() }
    }

    @ViewBuilder private var bgView: some View {
        GlassEffectContainer(spacing: 0) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.clear)
                .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(isDark ? Color.black.opacity(0.10) : Color.white.opacity(0.06))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(isDark ? 0.16 : 0.24), lineWidth: 1)
                }
                .padding(2)
        }
    }

    private func toolbarRow(width: CGFloat) -> some View {
        let compact = fullToolbarWidth + 176 > width
        return HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: fileCategoryIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fileURL.path)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(fg2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(minWidth: 120, maxWidth: 240, alignment: .leading)
            .layoutPriority(-1)
            Spacer(minLength: 12)
            toolbarActions(isCompact: compact)
                .fixedSize()
                .animation(.easeInOut(duration: 0.22), value: compact)
                .background {
                    toolbarActions(isCompact: false)
                        .fixedSize()
                        .hidden()
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullToolbarWidth = $0 }
                }
        }
        .padding(16)
        .solidPanel(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            fill: chromeFill,
            stroke: panelStroke,
            shadowOpacity: 0.04
        )
    }

    private func toolbarActions(isCompact: Bool) -> some View {
            HStack(spacing: 8) {
                if fileCategory == .code { neutralToolButton("复制代码", icon: "doc.on.doc", compact: isCompact) { copyToPasteboard(codeText) } }
                if fileCategory == .code && isEdited { neutralToolButton("保存", icon: "square.and.arrow.down", compact: isCompact) { saveCode() } }
                if fileCategory == .image && !isSVGFile { neutralToolButton("图片裁剪", icon: "crop", compact: isCompact) { showCrop = true } }
                if canUseImageUnderstanding {
                    imageUnderstandingMenu(compact: isCompact)
                }
                if fileCategory == .pdf {
                    neutralToolButton("复制页", icon: "doc.on.doc", compact: isCompact) { pdfController.copyCurrentPage() }
                    neutralToolButton("复制文件", icon: "square.on.square", compact: isCompact) { pdfController.copyDocument() }
                    neutralToolButton("删当前页", icon: "trash", compact: isCompact) { pdfController.deleteCurrentPage() }
                }
                if fileCategory == .media {
                    neutralToolButton("画面裁剪", icon: "crop", compact: isCompact) { showVideoCrop = true }
                    neutralToolButton("片段剪辑", icon: "scissors", compact: isCompact) { showTrim = true }
                }
                if canConvertPreview {
                    conversionMenu(compact: isCompact)
                }
                toolsMenu(compact: isCompact)
                Button {
                    isPinned.toggle()
                    onTogglePinned(isPinned)
                } label: {
                    toolbarLabel(title: isPinned ? "已钉住" : "钉住", icon: isPinned ? "pin.fill" : "pin", compact: isCompact)
                }
                .buttonStyle(.plain)
                .foregroundStyle(fg)
                .background {
                    Capsule(style: .continuous)
                        .fill(neutralCapsuleTint)
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(isPinned ? Color.orange.opacity(0.55) : neutralCapsuleStroke, lineWidth: 1)
                        }
                }
                .controlSize(.large)
                Button {
                    openFileWithConfiguredApp()
                } label: {
                    toolbarLabel(title: openButtonLabel, icon: "arrow.up.forward.app", compact: isCompact)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
                .controlSize(.large)
            }
    }

    private func showToolbarMenu(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func imageUnderstandingMenu(compact: Bool) -> some View {
        neutralToolButton(isRecognizingText || isRecognizingCodes || isTranslating ? "处理中" : "识别", icon: "text.viewfinder", compact: compact) {
            let menu = NSMenu()
            menu.addItem(previewMenuItem("识别文字") { recognizeTextFromCurrentPreview() })
            if canUseInteractiveOCRSelection {
                menu.addItem(previewMenuItem(isSelectingOCRRegion ? "取消框选识别" : "框选识别") { toggleOCRRegionSelection() })
            }
            menu.addItem(previewMenuItem("识别二维码 / 条形码") { detectCodesFromCurrentPreview() })
            if hasRecognizedText {
                menu.addItem(previewMenuItem("复制识别文字") { copyRecognizedTextToPasteboard() })
                menu.addItem(previewMenuItem("网页搜索识别文字") { searchRecognizedText() })
                menu.addItem(.separator())
                let translations = NSMenu()
                for target in TranslationTargetChoice.allCases {
                    translations.addItem(previewMenuItem(target.title) {
                        selectedTranslationTarget = target
                        translateFullRecognizedText()
                    })
                }
                let item = NSMenuItem(title: "一键翻译", action: nil, keyEquivalent: "")
                item.submenu = translations
                menu.addItem(item)
            }
            if hasImageUnderstandingResults {
                menu.addItem(.separator())
                menu.addItem(previewMenuItem("清空识别结果") { clearRecognitionResults() })
            }
            showToolbarMenu(menu)
        }
    }

    private func neutralToolButton(_ t: String, icon: String, compact: Bool, a: @escaping () -> Void) -> some View {
        Button(action: a) {
            toolbarLabel(title: t, icon: icon, compact: compact)
                .background {
                    Capsule(style: .continuous)
                        .fill(neutralCapsuleTint)
                        .overlay {
                            Capsule(style: .continuous).stroke(neutralCapsuleStroke, lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(fg)
        .controlSize(.large)
    }

    private func exportMenu() -> NSMenu {
        let menu = NSMenu()
        if canResizeExport {
            menu.addItem(previewMenuItem("修改尺寸并导出…") { exportResizedMedia() })
            menu.addItem(.separator())
        }
        for format in availableExportFormats {
            let item = previewMenuItem("导出 \(format.menuLabel)") { exportWithFFmpeg(target: format) }
            item.isEnabled = !isConverting
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    private func conversionMenu(compact: Bool) -> some View {
        neutralToolButton(isConverting ? "转换中" : "转格式", icon: isConverting ? "hourglass" : "rectangle.2.swap", compact: compact) {
            showToolbarMenu(exportMenu())
        }
        .disabled(isConverting)
    }

    private func toolsMenu(compact: Bool) -> some View {
        neutralToolButton("工具", icon: "wrench.and.screwdriver", compact: compact) {
            let menu = NSMenu()
            menu.addItem(previewMenuItem("打印当前预览") { printCurrentPreview() })
            menu.addItem(previewMenuItem("AirDrop 分享") { shareViaAirDrop() })
            menu.addItem(previewMenuItem("系统分享…") { showSystemSharePicker() })
            menu.addItem(.separator())
            menu.addItem(previewMenuItem("复制文件") { copyFileToPasteboard() })
            menu.addItem(previewMenuItem("复制路径") { copyToPasteboard(fileURL.path) })
            menu.addItem(previewMenuItem("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) })
            menu.addItem(.separator())
            if canResizeExport {
                menu.addItem(previewMenuItem("修改尺寸并导出…") { exportResizedMedia() })
            }
            if fileCategory == .image {
                menu.addItem(previewMenuItem("导出 PNG…") { exportImageAsPNG() })
            }
            if canConvertPreview {
                let item = NSMenuItem(title: "导出 / 转格式", action: nil, keyEquivalent: "")
                item.submenu = exportMenu()
                menu.addItem(item)
            }
            menu.addItem(previewMenuItem("打开系统截图") { openSystemScreenshot() })
            showToolbarMenu(menu)
        }
    }

    private func toolbarLabel(title: String, icon: String, compact: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18, height: 18)
            if !compact {
                Text(title).lineLimit(1)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, compact ? 12 : 14)
        .frame(height: 36)
        .fixedSize()
        .contentShape(Rectangle())
        .accessibilityLabel(title)
        .help(title)
    }

    @ViewBuilder
    private var conversionOverlay: some View {
        if isConverting {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                    Text("正在转换\(convertingTarget?.displayName ?? "文件")")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }

                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.cyan.opacity(0.95))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: 460)
            .liquidGlassCard(in: RoundedRectangle(cornerRadius: 16, style: .continuous), padding: 0)
            .padding(.bottom, 20)
        } else if let conversionStatus {
            HStack(spacing: 10) {
                Image(systemName: conversionStatus.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(conversionStatus.isSuccess ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversionStatus.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(conversionStatus.message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if let fileURL = conversionStatus.outputURL, conversionStatus.isSuccess {
                    Button("打开文件夹") {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        self.conversionStatus = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button {
                    self.conversionStatus = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: 560)
            .liquidGlassCard(in: RoundedRectangle(cornerRadius: 16, style: .continuous), padding: 0)
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder private var contentArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(contentFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(panelStroke, lineWidth: 1)
                }
            switch fileCategory {
            case .image:
                if isAnimatedImage {
                    AspectFittedPreview(aspectRatio: mediaAspectRatio) {
                        ZoomableView {
                            AnimatedImagePreview(fileURL: fileURL)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else if let img = previewImage {
                    stillImagePreview(img)
                }
            case .pdf:
                PDFDocumentBrowserView(controller: pdfController)
                    .padding(8)
            case .document:
                if ["ppt", "pptx", "key"].contains(fileURL.pathExtension.lowercased()) {
                    PresentationPreview(fileURL: fileURL)
                        .id(fileURL)
                        .padding(8)
                } else {
                    QuickLookDocumentView(fileURL: fileURL)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(8)
                }
            case .media:
                if isWebMFile {
                    ZoomableView(passesClicksThrough: true) {
                        AspectFittedPreview(aspectRatio: mediaAspectRatio) {
                            WebMVideoPreview(fileURL: fileURL)
                        }
                    }
                } else if videoManager.isReady, let player = videoManager.player {
                    StableVideoPlayer(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("加载视频中…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            case .code:
                textEditorArea
            case .web:
                WebFileView(fileURL: fileURL)
            case .folder:
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(folderItems) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(item.isDirectory ? Color.accentColor : fg2)
                                    .frame(width: 18)
                                Text(item.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(fg)
                                    .lineLimit(1)
                                Spacer()
                                Text(item.sizeStr)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(fg2)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .solidPanel(
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                                fill: secondaryFill,
                                stroke: panelStroke,
                                shadowOpacity: 0.08
                            )
                        }
                    }
                    .padding(14)
                }
            case .other:
                if let img = previewImage {
                    stillImagePreview(img)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc")
                            .font(.system(size: 48))
                            .foregroundStyle(fg2)
                        Text(fileURL.lastPathComponent)
                            .font(.system(size: 13))
                            .foregroundStyle(fg2)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottom) {
            conversionOverlay
        }
        .overlay {
            if isLoadingPreview {
                previewLoadingOverlay
            }
        }
        .overlay(alignment: .topTrailing) {
            if let textSaveStatus, fileCategory == .code {
                Label(textSaveStatus.title, systemImage: textSaveStatus.iconName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(textSaveStatus.tint.opacity(0.92), in: Capsule())
                    .padding(14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    if !heroSize.isEmpty {
                        Text(heroSize)
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(fg)
                            .tracking(-0.6)
                    }
                    HStack(spacing: 8) {
                        if !heroFileSize.isEmpty {
                            Text(heroFileSize)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(fg)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .solidPanel(in: Capsule(), fill: secondaryFill, stroke: panelStroke, shadowOpacity: 0.06)
                        }
                        if !heroFormat.isEmpty {
                            Text(heroFormat)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(fg)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .solidPanel(in: Capsule(), fill: secondaryFill, stroke: panelStroke, shadowOpacity: 0.06)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 16)

                Rectangle()
                    .fill(divC)
                    .frame(height: 1)
                    .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(metadata) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(fg2)
                            Text(item.value)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(fg)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }

                if canUseImageUnderstanding || hasImageUnderstandingResults {
                    Rectangle()
                        .fill(divC)
                        .frame(height: 1)
                        .padding(.vertical, 12)

                    imageUnderstandingPanel
                }
            }
            .padding(16)
        }
        .solidPanel(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous),
            fill: chromeFill,
            stroke: panelStroke,
            shadowOpacity: 0.04
        )
    }

    private var imageUnderstandingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            targetCapsulePicker

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    actionCapsuleButton(title: "识别文字", icon: "text.viewfinder", disabled: isRecognizingText || isRecognizingCodes || isTranslating) {
                        recognizeTextFromCurrentPreview()
                    }
                    if canUseInteractiveOCRSelection {
                        actionCapsuleButton(title: isSelectingOCRRegion ? "取消框选" : "框选识别", icon: "selection.pin.in.out", disabled: isRecognizingText || isRecognizingCodes || isTranslating) {
                            toggleOCRRegionSelection()
                        }
                    }
                }

                HStack(spacing: 8) {
                    actionCapsuleButton(title: "识别码", icon: "qrcode.viewfinder", disabled: isRecognizingText || isRecognizingCodes || isTranslating) {
                        detectCodesFromCurrentPreview()
                    }
                    actionCapsuleButton(title: "取色", icon: "eyedropper.halffull", disabled: currentRecognitionImage() == nil) {
                        sampleColorFromPreview()
                    }
                }

                HStack(spacing: 8) {
                    actionCapsuleButton(title: "复制全部", icon: "doc.on.doc", disabled: !hasRecognizedText) {
                        copyRecognizedTextToPasteboard()
                    }
                    actionCapsuleButton(title: "导出 PNG", icon: "photo.badge.arrow.down", disabled: fileCategory != .image && previewImage == nil) {
                        exportImageAsPNG()
                    }
                }

                HStack(spacing: 8) {
                    actionCapsuleButton(title: "一键全翻", icon: "translate", disabled: !hasRecognizedText || isTranslating) {
                        translateFullRecognizedText()
                    }
                    actionCapsuleButton(title: "网页搜索", icon: "magnifyingglass", disabled: !hasRecognizedText) {
                        searchRecognizedText()
                    }
                }

                HStack(spacing: 8) {
                    actionCapsuleButton(title: "清空", icon: "trash", disabled: !hasImageUnderstandingResults) {
                        clearRecognitionResults()
                    }
                    Spacer(minLength: 0)
                }
            }

            if canUseInteractiveOCRSelection && isSelectingOCRRegion {
                Text("直接在左侧预览图上拖一个框，我会只识别这块区域，并把结果框高亮回显到原图上。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.cyan.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            if !recognitionStatusMessage.isEmpty {
                HStack(spacing: 8) {
                    if isRecognizingText || isRecognizingCodes || isTranslating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.cyan)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }
                    Text(recognitionStatusMessage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .solidPanel(in: RoundedRectangle(cornerRadius: 12, style: .continuous), fill: secondaryFill, stroke: panelStroke, shadowOpacity: 0.02)
            }

            if !recognizedCodeItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("识别到的码")
                    ForEach(recognizedCodeItems) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.symbology)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(fg2)
                            Text(item.payload)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(fg)
                                .textSelection(.enabled)
                                .lineLimit(nil)
                            HStack(spacing: 8) {
                                inlineTextActionButton("复制", icon: "doc.on.doc") {
                                    copyToPasteboard(item.payload)
                                }
                                inlineTextActionButton("打开", icon: "arrow.up.right.square") {
                                    openStringIfPossible(item.payload)
                                }
                            }
                        }
                        .padding(12)
                        .solidPanel(in: RoundedRectangle(cornerRadius: 12, style: .continuous), fill: secondaryFill, stroke: panelStroke, shadowOpacity: 0.03)
                    }
                }
            }

            if hasRecognizedText {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("识别文字")
                    ForEach(recognizedTextBlocks) { block in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(block.text)
                                .font(.system(size: 12.5))
                                .foregroundStyle(fg)
                                .textSelection(.enabled)
                                .lineLimit(nil)

                            HStack(spacing: 8) {
                                inlineTextActionButton("复制", icon: "doc.on.doc") {
                                    copyToPasteboard(block.text)
                                }
                                inlineTextActionButton("翻译", icon: "translate") {
                                    translateRecognizedBlock(block)
                                }
                                inlineTextActionButton("搜索", icon: "magnifyingglass") {
                                    searchRecognizedText(block.text)
                                }
                            }

                            if let translated = translatedBlockTexts[block.id], !translated.isEmpty {
                                Text(translated)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.cyan.opacity(0.95))
                                    .textSelection(.enabled)
                                    .padding(.top, 2)
                            }
                        }
                        .padding(12)
                        .solidPanel(in: RoundedRectangle(cornerRadius: 12, style: .continuous), fill: secondaryFill, stroke: panelStroke, shadowOpacity: 0.03)
                    }
                }
            }

            if !fullTranslatedText.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        sectionTitle("全文翻译")
                        Spacer()
                        inlineTextActionButton("复制译文", icon: "doc.on.doc") {
                            copyToPasteboard(fullTranslatedText)
                        }
                    }
                    Text(fullTranslatedText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.cyan.opacity(0.95))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .padding(12)
                        .solidPanel(in: RoundedRectangle(cornerRadius: 12, style: .continuous), fill: secondaryFill, stroke: panelStroke, shadowOpacity: 0.03)
                }
            }

            if !hasImageUnderstandingResults && recognitionStatusMessage.isEmpty {
                Text(isSVGFile ? "这里可以直接对 SVG 做 OCR、取色、导出 PNG，或把识别到的文字一键翻译。" : "这里可以直接识别图片或当前 PDF 页里的文字、二维码，再一键复制、搜索或翻译。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .solidPanel(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            fill: secondaryFill,
            stroke: panelStroke,
            shadowOpacity: 0.03
        )
    }

    private var targetCapsulePicker: some View {
        Menu {
            ForEach(TranslationTargetChoice.allCases) { target in
                Button {
                    selectedTranslationTarget = target
                } label: {
                    if selectedTranslationTarget == target {
                        Label(target.shortTitle, systemImage: "checkmark")
                    } else {
                        Text(target.shortTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedTranslationTarget.shortTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(fg)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(fg2)
            }
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Capsule())
        .solidPanel(in: Capsule(), fill: secondaryFill, stroke: panelStroke, shadowOpacity: 0.02)
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(fg2)
    }

    private func actionCapsuleButton(title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? fg2.opacity(0.7) : fg)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            Capsule(style: .continuous)
                .fill(isDark ? Color.white.opacity(disabled ? 0.06 : 0.10) : Color.black.opacity(disabled ? 0.04 : 0.07))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(disabled ? neutralCapsuleStroke.opacity(0.5) : neutralCapsuleStroke, lineWidth: 1)
                }
        }
        .disabled(disabled)
    }

    private func inlineTextActionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(fg)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(neutralCapsuleTint)
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(neutralCapsuleStroke, lineWidth: 1)
                }
        }
    }

    private var canUseImageUnderstanding: Bool {
        switch fileCategory {
        case .image, .pdf:
            return fileCategory == .pdf || !isAnimatedImage
        case .other:
            return previewImage != nil
        default:
            return false
        }
    }

    private var hasRecognizedText: Bool {
        !recognizedTextBlocks.isEmpty
    }

    private var hasImageUnderstandingResults: Bool {
        hasRecognizedText || !recognizedCodeItems.isEmpty || !fullTranslatedText.isEmpty || !translatedBlockTexts.isEmpty
    }

    private var canUseInteractiveOCRSelection: Bool {
        (fileCategory == .image || fileCategory == .other) && !isAnimatedImage && currentRecognitionImage() != nil
    }

    private var recognizedHighlightRects: [CGRect] {
        recognizedTextBlocks.map(\.normalizedBoundingBox)
    }

    private var fileCategoryIcon: String {
        switch fileCategory {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .media: return "play.rectangle.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .web: return "globe"
        case .folder: return "folder.fill"
        case .other: return "doc.fill"
        }
    }

    private var canConvertPreview: Bool {
        !availableExportFormats.isEmpty
    }

    private var isWebMFile: Bool {
        fileURL.pathExtension.lowercased() == "webm"
    }

    private var canResizeExport: Bool {
        let ext = fileURL.pathExtension.lowercased()
        if fileCategory == .media {
            return ["mp4", "mov", "m4v", "webm", "avi", "mkv", "hevc"].contains(ext)
        }

        guard fileCategory == .image || previewImage != nil else { return false }
        return ["png", "apng", "jpg", "jpeg", "jfif", "heic", "heif", "tif", "tiff", "gif", "webp"].contains(ext)
    }

    private var availableExportFormats: [ExportFormat] {
        switch fileCategory {
        case .media:
            return ExportFormat.allCases.filter { format in
                switch format {
                case .png:
                    return false
                case .gif:
                    return true
                case .apng:
                    return ffmpegSupport.supportsEncoder("apng")
                case .mp4:
                    return ffmpegSupport.supportsEncoder("libx264") && ffmpegSupport.supportsMuxer("mp4")
                case .mov:
                    return ffmpegSupport.supportsEncoder("libx264") && ffmpegSupport.supportsMuxer("mov")
                case .webm:
                    return ffmpegSupport.supportsEncoder("libvpx-vp9") && ffmpegSupport.supportsMuxer("webm")
                case .mp3:
                    return ffmpegSupport.supportsEncoder("libmp3lame") && ffmpegSupport.supportsMuxer("mp3")
                case .wav:
                    return ffmpegSupport.supportsMuxer("wav")
                case .webp:
                    return ffmpegSupport.supportsAnimatedWebP
                }
            }
        case .image:
            return ExportFormat.allCases.filter { format in
                switch format {
                case .png:
                    return true
                case .gif:
                    return ffmpegSupport.isInstalled
                case .apng:
                    return ffmpegSupport.isInstalled && ffmpegSupport.supportsEncoder("apng")
                case .webp:
                    return true
                case .mp4, .mov, .webm, .mp3, .wav:
                    return false
                }
            }
        default:
            return []
        }
    }

    @ViewBuilder
    private func stillImagePreview(_ image: NSImage) -> some View {
            ZoomableView {
                GeometryReader { geo in
                    let available = CGSize(width: max(0, geo.size.width - 20), height: max(0, geo.size.height - 20))
                    let fitted = comfortableImagePreviewSize(in: available, aspectRatio: mediaAspectRatio)

                    ZStack {
                        ZStack {
                            if isSVGFile {
                                TransparentPreviewBackdrop()
                            }

                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .antialiased(true)
                                .aspectRatio(mediaAspectRatio, contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                            OCRHighlightOverlay(highlights: recognizedHighlightRects, accentColor: .cyan)

                            OCRSelectableTextOverlay(
                                blocks: recognizedTextBlocks,
                                isInteractive: !isSelectingOCRRegion
                            )

                            OCRRegionSelectionOverlay(
                                isActive: isSelectingOCRRegion,
                                selectionRect: selectedOCRRegion,
                                onSelectionChanged: { rect in
                                    selectedOCRRegion = rect
                                },
                                onSelectionCommitted: { rect in
                                    recognizeTextFromCurrentPreview(region: rect)
                                }
                            )
                        }
                        .frame(width: fitted.width, height: fitted.height)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }

    private func nativeZoomControls(
        scale: CGFloat,
        onZoom: @escaping (CGFloat) -> Void,
        onReset: @escaping () -> Void,
        onDragScale: @escaping (CGFloat) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                onZoom(0.7)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                Circle()
                    .fill(Color.black.opacity(0.44))
                    .overlay {
                        Circle().stroke(.white.opacity(0.12), lineWidth: 1)
                    }
            }

            Text("\(Int(scale * 100))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(minWidth: 52, minHeight: 30)
                .contentShape(Capsule())
                .overlay {
                    ZoomPercentDragCapture(
                        currentScale: scale,
                        minScale: 0.1,
                        maxScale: 8.0,
                        onScaleChanged: { targetScale in
                            onDragScale(targetScale)
                        },
                        onDragEnded: {}
                    )
                }
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.44))
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(.white.opacity(0.12), lineWidth: 1)
                        }
                }

            Button {
                onZoom(1.5)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                Circle()
                    .fill(Color.black.opacity(0.44))
                    .overlay {
                        Circle().stroke(.white.opacity(0.12), lineWidth: 1)
                    }
            }

            if abs(scale - 1.0) > 0.02 {
                Button {
                    onReset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    Circle()
                        .fill(Color.black.opacity(0.44))
                        .overlay {
                            Circle().stroke(.white.opacity(0.12), lineWidth: 1)
                        }
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var textEditorArea: some View {
        CodeEditorView(text: $codeText, isDark: isDark, language: fileURL.pathExtension) {
            saveCode()
        }
        .padding(6)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onChange(of: codeText) { _, _ in
            guard !isRefreshingCodeText else { return }
            isEdited = true
            textSaveStatus = nil
        }
    }

    @ViewBuilder
    private var previewLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(loadingMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .liquidGlassCard(in: RoundedRectangle(cornerRadius: 16, style: .continuous), padding: 0)
    }

    private func beginLoadingPreview() {
        loadingMessage = loadingMessage(for: fileURL)
        isLoadingPreview = true
        DispatchQueue.main.async {
            loadData()
        }
    }

    private func loadingMessage(for fileURL: URL) -> String {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "svg" {
            return "正在加载 SVG 预览…"
        }
        if ["mp4", "mov", "mkv", "webm"].contains(ext) {
            return "正在加载视频预览…"
        }
        if ["pdf"].contains(ext) {
            return "正在加载 PDF 预览…"
        }
        if ["ppt", "pptx", "doc", "docx", "xls", "xlsx"].contains(ext) {
            return "正在准备文档预览…"
        }
        if ["swift","py","js","ts","json","yaml","yml","md","ini","cfg","conf","env","sh"].contains(ext) {
            return "正在加载文本内容…"
        }
        return "正在准备预览…"
    }

    private func saveCode() {
        guard let data = codeText.data(using: .utf8) else {
            showSaveStatus(.error("保存失败"))
            return
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            isEdited = false
            showSaveStatus(.success("已保存"))
            metadata = []
            loadData()
        } catch {
            showSaveStatus(.error("保存失败"))
        }
    }

    private func showSaveStatus(_ status: SaveStatus) {
        withAnimation(.easeInOut(duration: 0.18)) {
            textSaveStatus = status
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.18)) {
                if textSaveStatus?.id == status.id {
                    textSaveStatus = nil
                }
            }
        }
    }

    private func openFileWithConfiguredApp() {
        let appPath = configuredAppPath
        if !appPath.isEmpty, FileManager.default.fileExists(atPath: appPath) {
            NSWorkspace.shared.open([fileURL], withApplicationAt: URL(fileURLWithPath: appPath), configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(fileURL)
        }
    }

    private func printCurrentPreview() {
        guard let image = currentRecognitionImage() ?? previewExportImage() else {
            NSWorkspace.shared.open(fileURL)
            return
        }

        let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36

        let pageSize = printInfo.paperSize
        let printView = NSView(frame: NSRect(origin: .zero, size: pageSize))
        let imageView = NSImageView(frame: printView.bounds.insetBy(dx: 36, dy: 36))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.autoresizingMask = [.width, .height]
        printView.addSubview(imageView)

        let operation = NSPrintOperation(view: printView, printInfo: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    private func shareViaAirDrop() {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            conversionStatus = ConversionStatus(title: "无法 AirDrop", message: "系统当前没有提供 AirDrop 分享服务。", outputURL: nil, isSuccess: false)
            return
        }
        service.perform(withItems: [fileURL])
    }

    private func showSystemSharePicker() {
        guard let contentView = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else {
            shareViaAirDrop()
            return
        }
        let picker = NSSharingServicePicker(items: [fileURL])
        let anchor = NSRect(x: contentView.bounds.midX, y: contentView.bounds.maxY - 1, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
    }

    private func copyFileToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([fileURL as NSURL])
        conversionStatus = ConversionStatus(title: "已复制文件", message: fileURL.lastPathComponent, outputURL: nil, isSuccess: true)
    }

    private func openSystemScreenshot() {
        let candidates = [
            "/System/Applications/Utilities/Screenshot.app",
            "/Applications/Utilities/Screenshot.app"
        ]
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func refreshOpenButtonLabel() async {
        let url = fileURL
        let appPath = configuredAppPath
        let label = await Task.detached(priority: .utility) {
            if !appPath.isEmpty, FileManager.default.fileExists(atPath: appPath) {
                let name = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
                return "用 \(name) 打开"
            }
            if let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url) {
                let name = defaultApp.deletingPathExtension().lastPathComponent
                return "用 \(name) 打开"
            }
            return "打开"
        }.value
        guard fileURL.path == url.path else { return }
        openButtonLabel = label
    }

    private func recognizeTextFromCurrentPreview(region: CGRect? = nil) {
        guard let baseImage = currentRecognitionCGImage() else {
            recognitionStatusMessage = "当前内容还没有准备好，暂时无法识别。"
            return
        }

        isRecognizingText = true
        recognitionStatusMessage = region == nil ? "正在识别当前预览里的文字…" : "正在识别框选区域里的文字…"
        fullTranslatedText = ""
        translatedBlockTexts = [:]

        let cgImage: CGImage
        let effectiveRegion: CGRect
        if let region, let cropped = cropCGImage(baseImage, toNormalizedRect: region) {
            cgImage = cropped
            effectiveRegion = region
        } else {
            cgImage = baseImage
            effectiveRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US", "ja-JP", "ko-KR"]

            let handler = VNImageRequestHandler(cgImage: cgImage)

            do {
                try handler.perform([request])
                let observations = (request.results ?? [])
                    .sorted {
                        if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.02 {
                            return $0.boundingBox.midY > $1.boundingBox.midY
                        }
                        return $0.boundingBox.minX < $1.boundingBox.minX
                    }

                let blocks = observations.compactMap { observation -> RecognizedTextBlock? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    let mappedBox = mapObservationRect(observation.boundingBox, fromRegion: effectiveRegion)
                    return RecognizedTextBlock(text: text, confidence: Double(candidate.confidence), normalizedBoundingBox: mappedBox)
                }

                await MainActor.run {
                    isRecognizingText = false
                    recognizedTextBlocks = blocks
                    selectedOCRRegion = region
                    if region != nil {
                        isSelectingOCRRegion = false
                    }
                    if blocks.isEmpty {
                        recognitionStatusMessage = "没有识别到可用文字。"
                    } else {
                        recognitionStatusMessage = "已识别 \(blocks.count) 段文字。"
                    }
                }
            } catch {
                await MainActor.run {
                    isRecognizingText = false
                    if region != nil {
                        isSelectingOCRRegion = false
                    }
                    recognitionStatusMessage = "文字识别失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func detectCodesFromCurrentPreview() {
        guard let cgImage = currentRecognitionCGImage() else {
            recognitionStatusMessage = "当前内容还没有准备好，暂时无法识别二维码。"
            return
        }

        isRecognizingCodes = true
        recognitionStatusMessage = "正在识别二维码 / 条形码…"

        Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage)

            do {
                try handler.perform([request])
                let items = (request.results ?? []).compactMap { observation -> RecognizedCodeItem? in
                    guard let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !payload.isEmpty else { return nil }
                    return RecognizedCodeItem(payload: payload, symbology: observation.symbology.rawValue)
                }

                await MainActor.run {
                    isRecognizingCodes = false
                    recognizedCodeItems = items
                    recognitionStatusMessage = items.isEmpty ? "没有识别到二维码或条形码。" : "已识别 \(items.count) 个码。"
                }
            } catch {
                await MainActor.run {
                    isRecognizingCodes = false
                    recognitionStatusMessage = "二维码识别失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func translateFullRecognizedText() {
        let text = recognizedTextBlocks.map(\.text).joined(separator: "\n")
        guard !text.isEmpty else {
            recognitionStatusMessage = "还没有可翻译的识别文字。"
            return
        }

        isTranslating = true
        recognitionStatusMessage = "正在调用系统翻译…"

        Task {
            do {
                let translated = try await translateText(text, target: selectedTranslationTarget)
                fullTranslatedText = translated
                isTranslating = false
                recognitionStatusMessage = "全文翻译完成。"
            } catch {
                isTranslating = false
                recognitionStatusMessage = "翻译失败：\(friendlyTranslationError(error))"
            }
        }
    }

    private func translateRecognizedBlock(_ block: RecognizedTextBlock) {
        isTranslating = true
        recognitionStatusMessage = "正在翻译选中的文字段落…"

        Task {
            do {
                let translated = try await translateText(block.text, target: selectedTranslationTarget)
                translatedBlockTexts[block.id] = translated
                isTranslating = false
                recognitionStatusMessage = "段落翻译完成。"
            } catch {
                isTranslating = false
                recognitionStatusMessage = "翻译失败：\(friendlyTranslationError(error))"
            }
        }
    }

    private func translateText(_ text: String, target: TranslationTargetChoice) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominantLanguage = recognizer.dominantLanguage else {
            throw TranslationError.unableToIdentifyLanguage
        }

        let sourceLanguage = Locale.Language(identifier: dominantLanguage.rawValue)
        let availability = LanguageAvailability()
        let status = await availability.status(from: sourceLanguage, to: target.language)
        guard status != .unsupported else {
            throw TranslationError.unsupportedTargetLanguage
        }

        let session = TranslationSession(installedSource: sourceLanguage, target: target.language)
        try await session.prepareTranslation()
        let response = try await session.translate(trimmed)
        return response.targetText
    }

    private func toggleOCRRegionSelection() {
        if isSelectingOCRRegion {
            isSelectingOCRRegion = false
            selectedOCRRegion = nil
            recognitionStatusMessage = ""
        } else {
            isSelectingOCRRegion = true
            selectedOCRRegion = nil
            recognitionStatusMessage = "在左侧预览图上拖一个框，我会只识别这块区域。"
        }
    }

    private func cropCGImage(_ image: CGImage, toNormalizedRect rect: CGRect) -> CGImage? {
        let normalized = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { return nil }

        let pixelRect = CGRect(
            x: normalized.minX * CGFloat(image.width),
            y: normalized.minY * CGFloat(image.height),
            width: normalized.width * CGFloat(image.width),
            height: normalized.height * CGFloat(image.height)
        ).integral

        guard let cropped = image.cropping(to: pixelRect) else { return nil }
        return cropped
    }

    private func mapObservationRect(_ rect: CGRect, fromRegion region: CGRect) -> CGRect {
        CGRect(
            x: region.minX + rect.minX * region.width,
            y: region.minY + rect.minY * region.height,
            width: rect.width * region.width,
            height: rect.height * region.height
        )
    }

    private func friendlyTranslationError(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    private func currentRecognitionCGImage() -> CGImage? {
        currentRecognitionImage()?.quickPeekCGImage
    }

    private func currentRecognitionImage() -> NSImage? {
        switch fileCategory {
        case .image, .other:
            if isSVGFile {
                return previewExportImage() ?? previewImage
            }
            return previewImage
        case .pdf:
            if pdfController.pageImages.indices.contains(pdfController.currentPageIndex) {
                return pdfController.pageImages[pdfController.currentPageIndex]
            }
            guard let document = pdfController.document,
                  let page = document.page(at: pdfController.currentPageIndex) else {
                return previewImage
            }
            let bounds = page.bounds(for: .mediaBox)
            let maxEdge: CGFloat = 1800
            let scale = maxEdge / max(bounds.width, bounds.height, 1)
            let size = NSSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
            return page.thumbnail(of: size, for: .mediaBox)
        default:
            return nil
        }
    }

    private func copyRecognizedTextToPasteboard() {
        copyToPasteboard(recognizedTextBlocks.map(\.text).joined(separator: "\n"))
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func searchRecognizedText(_ overrideText: String? = nil) {
        let query = (overrideText ?? recognizedTextBlocks.map(\.text).joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openStringIfPossible(_ string: String) {
        if let url = URL(string: string), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else {
            copyToPasteboard(string)
        }
    }

    private func clearRecognitionResults(keepStatus: Bool = false) {
        recognizedTextBlocks = []
        recognizedCodeItems = []
        translatedBlockTexts = [:]
        fullTranslatedText = ""
        selectedOCRRegion = nil
        isSelectingOCRRegion = false
        if !keepStatus {
            recognitionStatusMessage = ""
        }
    }

    private func exportWithFFmpeg(target: ExportFormat) {
        if target == .png {
            exportImageAsPNG()
            return
        }

        if target == .webp, fileCategory == .image {
            exportImageAsWebP()
            return
        }

        guard let ffmpegURL = ffmpegSupport.ffmpegURL else {
            conversionStatus = ConversionStatus(title: "没有检测到 ffmpeg", message: "这台 Mac 还没找到 ffmpeg，所以现在还不能直接导出 GIF / WebP。", outputURL: nil, isSuccess: false)
            return
        }

        if target == .webp && !ffmpegSupport.supportsAnimatedWebP {
            conversionStatus = ConversionStatus(
                title: "当前 ffmpeg 不支持 WebP 导出",
                message: "这台 Mac 上安装的 Homebrew ffmpeg 8.1_1 没有编进 libwebp，所以视频转 WebP 会失败。现在我已经把这个选项从菜单里隐藏了。",
                outputURL: nil,
                isSuccess: false
            )
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + "_preview." + target.fileExtension
        panel.allowedContentTypes = [target.contentType]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        isConverting = true
        convertingTarget = target
        conversionStatus = nil
        let args = ffmpegArguments(inputPath: fileURL.path, outputPath: outputURL.path, target: target)

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = ffmpegURL
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let outputMessage = String(data: outputData, encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    isConverting = false
                    convertingTarget = nil
                    if process.terminationStatus == 0 {
                        conversionStatus = ConversionStatus(title: "转换完成", message: outputURL.lastPathComponent, outputURL: outputURL, isSuccess: true)
                    } else {
                        conversionStatus = ConversionStatus(title: "转换失败", message: outputMessage.isEmpty ? "ffmpeg 执行失败。" : outputMessage, outputURL: nil, isSuccess: false)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isConverting = false
                    convertingTarget = nil
                    conversionStatus = ConversionStatus(title: "转换失败", message: error.localizedDescription, outputURL: nil, isSuccess: false)
                }
            }
        }
    }

    private func exportImageAsWebP() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + "_preview.webp"
        panel.allowedContentTypes = [UTType(filenameExtension: "webp") ?? .data]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        guard let sourceImage = previewExportImage() else {
            conversionStatus = ConversionStatus(title: "转换失败", message: "没有拿到可导出的图片内容。", outputURL: nil, isSuccess: false)
            return
        }

        isConverting = true
        convertingTarget = .webp
        conversionStatus = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let options: [SDImageCoderOption: Any] = [
                .encodeCompressionQuality: 0.92,
                .encodeFirstFrameOnly: false
            ]
            let data: Data?

            if let framesPayload = animatedFramesPayload(from: sourceImage) {
                data = SDImageWebPCoder.shared.encodedData(
                    with: framesPayload.frames,
                    loopCount: framesPayload.loopCount,
                    format: .webP,
                    options: options
                )
            } else {
                data = SDImageWebPCoder.shared.encodedData(with: sourceImage, format: .webP, options: options)
            }

            DispatchQueue.main.async {
                isConverting = false
                convertingTarget = nil

                guard let data else {
                    conversionStatus = ConversionStatus(title: "转换失败", message: "当前图片无法编码成 WebP。", outputURL: nil, isSuccess: false)
                    return
                }

                do {
                    try data.write(to: outputURL)
                    conversionStatus = ConversionStatus(title: "转换完成", message: outputURL.lastPathComponent, outputURL: outputURL, isSuccess: true)
                } catch {
                    conversionStatus = ConversionStatus(title: "转换失败", message: error.localizedDescription, outputURL: nil, isSuccess: false)
                }
            }
        }
    }

    private func exportImageAsPNG() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + "_preview.png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        guard let sourceImage = previewExportImage(),
              let cgImage = sourceImage.quickPeekCGImage else {
            conversionStatus = ConversionStatus(title: "导出失败", message: "当前预览还没有准备好 PNG 导出内容。", outputURL: nil, isSuccess: false)
            return
        }

        guard let bitmap = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            conversionStatus = ConversionStatus(title: "导出失败", message: "系统暂时没有生成 PNG 数据。", outputURL: nil, isSuccess: false)
            return
        }

        do {
            try bitmap.write(to: outputURL)
            conversionStatus = ConversionStatus(title: "导出完成", message: outputURL.lastPathComponent, outputURL: outputURL, isSuccess: true)
        } catch {
            conversionStatus = ConversionStatus(title: "导出失败", message: error.localizedDescription, outputURL: nil, isSuccess: false)
        }
    }

    private func exportResizedMedia() {
        guard let sourceSize = currentMediaPixelSize() else {
            conversionStatus = ConversionStatus(title: "无法修改尺寸", message: "当前文件没有可识别的图片或视频画面尺寸。", outputURL: nil, isSuccess: false)
            return
        }

        guard let request = promptResizeExportRequest(originalSize: sourceSize) else { return }
        let outputExtension = resizeOutputExtension()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + "_\(request.width)x\(request.height)." + outputExtension
        panel.allowedContentTypes = [resizeOutputContentType(for: outputExtension)]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        if shouldResizeWithFFmpeg(outputExtension: outputExtension) {
            exportResizedMediaWithFFmpeg(request: request, outputURL: outputURL, outputExtension: outputExtension)
        } else {
            exportResizedStaticImage(request: request, outputURL: outputURL, outputExtension: outputExtension)
        }
    }

    private func promptResizeExportRequest(originalSize: CGSize) -> ResizeExportRequest? {
        let accessoryView = ResizeExportAccessoryView(originalSize: originalSize)
        let alert = NSAlert()
        alert.messageText = "修改尺寸并导出"
        alert.informativeText = "输入新的宽高。这里不会裁剪，只会把图片、动图或视频缩放到目标尺寸。"
        alert.accessoryView = accessoryView
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? accessoryView.request : nil
    }

    private func currentMediaPixelSize() -> CGSize? {
        if fileCategory == .media {
            return videoPixelSize(for: fileURL)
        }

        if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
           width > 0,
           height > 0 {
            return CGSize(width: width, height: height)
        }

        if let image = previewExportImage() {
            let size = bestImageSize(for: image)
            if size.width > 0, size.height > 0 {
                return size
            }
        }

        return nil
    }

    private func videoPixelSize(for url: URL) -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let transformedSize = track.naturalSize.applying(track.preferredTransform)
        let width = abs(transformedSize.width)
        let height = abs(transformedSize.height)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private func resizeOutputExtension() -> String {
        let ext = fileURL.pathExtension.lowercased()
        if ["jpeg", "jfif"].contains(ext) { return "jpg" }
        if ["png", "jpg", "heic", "heif", "tif", "tiff", "gif", "webp", "mp4", "mov", "webm"].contains(ext) {
            return ext
        }
        if fileCategory == .media { return "mp4" }
        return "png"
    }

    private func resizeOutputContentType(for ext: String) -> UTType {
        switch ext {
        case "png": return .png
        case "jpg", "jpeg", "jfif": return .jpeg
        case "heic", "heif": return UTType(filenameExtension: ext) ?? .heic
        case "tif", "tiff": return .tiff
        case "gif": return .gif
        case "webp": return UTType(filenameExtension: "webp") ?? .data
        case "mov": return .quickTimeMovie
        case "webm": return UTType(filenameExtension: "webm") ?? .movie
        default: return .mpeg4Movie
        }
    }

    private func shouldResizeWithFFmpeg(outputExtension: String) -> Bool {
        fileCategory == .media || isAnimatedImage || ["gif", "webp"].contains(outputExtension)
    }

    private func exportResizedStaticImage(request: ResizeExportRequest, outputURL: URL, outputExtension: String) {
        guard let sourceImage = previewExportImage(),
              let sourceCGImage = sourceImage.quickPeekCGImage,
              let resizedCGImage = resizedCGImage(from: sourceCGImage, width: request.width, height: request.height) else {
            conversionStatus = ConversionStatus(title: "导出失败", message: "当前图片无法生成目标尺寸。", outputURL: nil, isSuccess: false)
            return
        }

        isConverting = true
        convertingTarget = nil
        conversionStatus = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let success = writeResizedStaticImage(resizedCGImage, to: outputURL, outputExtension: outputExtension, sourceURL: fileURL)

            DispatchQueue.main.async {
                isConverting = false
                if success {
                    conversionStatus = ConversionStatus(title: "尺寸修改完成", message: outputURL.lastPathComponent, outputURL: outputURL, isSuccess: true)
                } else {
                    conversionStatus = ConversionStatus(title: "导出失败", message: "系统没有成功写出这个图片格式，可以试试导出为 PNG 或 JPG。", outputURL: nil, isSuccess: false)
                }
            }
        }
    }

    private func resizedCGImage(from sourceImage: CGImage, width: Int, height: Int) -> CGImage? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sourceImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func writeResizedStaticImage(_ image: CGImage, to outputURL: URL, outputExtension: String, sourceURL: URL) -> Bool {
        if outputExtension == "webp" {
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            let options: [SDImageCoderOption: Any] = [.encodeCompressionQuality: 0.92]
            guard let data = SDImageWebPCoder.shared.encodedData(with: nsImage, format: .webP, options: options) else { return false }
            do {
                try data.write(to: outputURL)
                return true
            } catch {
                return false
            }
        }

        let outputType = resizeOutputContentType(for: outputExtension)
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, outputType.identifier as CFString, 1, nil) else {
            return false
        }

        var properties: CFDictionary?
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) {
            properties = sourceProperties
        }

        CGImageDestinationAddImage(destination, image, properties)
        return CGImageDestinationFinalize(destination)
    }

    private func exportResizedMediaWithFFmpeg(request: ResizeExportRequest, outputURL: URL, outputExtension: String) {
        guard let ffmpegURL = ffmpegSupport.ffmpegURL else {
            conversionStatus = ConversionStatus(title: "没有检测到 ffmpeg", message: "动图和视频修改尺寸需要 ffmpeg，当前这台 Mac 还没找到。", outputURL: nil, isSuccess: false)
            return
        }

        if outputExtension == "webp", !ffmpegSupport.supportsAnimatedWebP, isAnimatedImage {
            conversionStatus = ConversionStatus(title: "当前 ffmpeg 不支持 WebP 动图", message: "这个 WebP 动图需要 libwebp 才能在缩放后继续保持动画。", outputURL: nil, isSuccess: false)
            return
        }

        isConverting = true
        convertingTarget = nil
        conversionStatus = nil

        let args = ffmpegResizeArguments(inputPath: fileURL.path, outputPath: outputURL.path, request: request, outputExtension: outputExtension)

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = ffmpegURL
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let outputMessage = String(data: outputData, encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    isConverting = false
                    if process.terminationStatus == 0 {
                        conversionStatus = ConversionStatus(title: "尺寸修改完成", message: outputURL.lastPathComponent, outputURL: outputURL, isSuccess: true)
                    } else {
                        conversionStatus = ConversionStatus(title: "导出失败", message: outputMessage.isEmpty ? "ffmpeg 执行失败。" : outputMessage, outputURL: nil, isSuccess: false)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isConverting = false
                    conversionStatus = ConversionStatus(title: "导出失败", message: error.localizedDescription, outputURL: nil, isSuccess: false)
                }
            }
        }
    }

    private func ffmpegResizeArguments(inputPath: String, outputPath: String, request: ResizeExportRequest, outputExtension: String) -> [String] {
        let width = max(1, request.width)
        let height = max(1, request.height)
        let videoWidth = evenVideoDimension(width)
        let videoHeight = evenVideoDimension(height)
        let scaleFilter = "scale=\(width):\(height):flags=lanczos"
        let videoScaleFilter = "scale=\(videoWidth):\(videoHeight):flags=lanczos"

        if fileCategory == .media {
            switch outputExtension {
            case "webm":
                return ["-y", "-i", inputPath, "-map", "0:v:0", "-map", "0:a?", "-vf", videoScaleFilter, "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "28", "-c:a", "libopus", "-b:a", "128k", outputPath]
            case "mov":
                return ["-y", "-i", inputPath, "-map", "0:v:0", "-map", "0:a?", "-vf", videoScaleFilter, "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-c:a", "aac", "-b:a", "192k", outputPath]
            default:
                return ["-y", "-i", inputPath, "-map", "0:v:0", "-map", "0:a?", "-vf", videoScaleFilter, "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", outputPath]
            }
        }

        switch outputExtension {
        case "gif":
            return ["-y", "-i", inputPath, "-filter_complex", "\(scaleFilter),split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3", outputPath]
        case "webp":
            return ["-y", "-i", inputPath, "-vf", scaleFilter, "-loop", "0", "-c:v", "libwebp", "-quality", "92", "-compression_level", "4", "-preset", "picture", "-an", outputPath]
        default:
            return ["-y", "-i", inputPath, "-vf", scaleFilter, "-plays", "0", "-f", "apng", outputPath]
        }
    }

    private func evenVideoDimension(_ value: Int) -> Int {
        let safeValue = max(2, value)
        return safeValue.isMultiple(of: 2) ? safeValue : safeValue + 1
    }

    private func sampleColorFromPreview() {
        let sampler = NSColorSampler()
        activeColorSampler = sampler
        recognitionStatusMessage = "正在取色…"
        sampler.show { color in
            DispatchQueue.main.async {
                defer { activeColorSampler = nil }
                guard let color else {
                    if recognitionStatusMessage == "正在取色…" {
                        recognitionStatusMessage = "已取消取色。"
                    }
                    return
                }

                let hex = colorHexString(color)
                copyToPasteboard(hex)
                recognitionStatusMessage = "已取色 \(hex)，并复制到剪贴板。"
            }
        }
    }

    private func colorHexString(_ color: NSColor) -> String {
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        let r = Int(round(converted.redComponent * 255))
        let g = Int(round(converted.greenComponent * 255))
        let b = Int(round(converted.blueComponent * 255))
        let a = Int(round(converted.alphaComponent * 255))
        if a < 255 {
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func previewExportImage() -> NSImage? {
        if let animated = resolvedAnimatedImage(for: fileURL) {
            return animated
        }
        if isSVGFile, let svgImage = systemSVGImage(from: fileURL) {
            return svgImage
        }
        if let previewImage {
            return previewImage
        }
        return decodeImageAsset(from: fileURL)?.image
    }

    private func ffmpegArguments(inputPath: String, outputPath: String, target: ExportFormat) -> [String] {
        switch target {
        case .png:
            return [
                "-y",
                "-i", inputPath,
                "-frames:v", "1",
                outputPath
            ]
        case .gif:
            return [
                "-y",
                "-i", inputPath,
                "-vf", "fps=12,scale='min(1200,iw)':-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3",
                outputPath
            ]
        case .webp:
            return [
                "-y",
                "-i", inputPath,
                "-vf", "fps=15,scale='min(1600,iw)':-1:flags=lanczos",
                "-loop", "0",
                "-c:v", "libwebp",
                "-quality", "92",
                "-compression_level", "4",
                "-preset", "picture",
                "-an",
                outputPath
            ]
        case .apng:
            return [
                "-y",
                "-i", inputPath,
                "-vf", "fps=15,scale='min(1600,iw)':-1:flags=lanczos",
                "-plays", "0",
                "-f", "apng",
                outputPath
            ]
        case .mp4:
            return [
                "-y",
                "-i", inputPath,
                "-c:v", "libx264",
                "-preset", "medium",
                "-crf", "18",
                "-c:a", "aac",
                "-b:a", "192k",
                outputPath
            ]
        case .mov:
            return [
                "-y",
                "-i", inputPath,
                "-c:v", "libx264",
                "-preset", "medium",
                "-crf", "18",
                "-c:a", "aac",
                "-b:a", "192k",
                outputPath
            ]
        case .webm:
            return [
                "-y",
                "-i", inputPath,
                "-c:v", "libvpx-vp9",
                "-b:v", "0",
                "-crf", "30",
                "-c:a", "libopus",
                "-b:a", "128k",
                outputPath
            ]
        case .mp3:
            return [
                "-y",
                "-i", inputPath,
                "-vn",
                "-c:a", "libmp3lame",
                "-q:a", "2",
                outputPath
            ]
        case .wav:
            return [
                "-y",
                "-i", inputPath,
                "-vn",
                "-c:a", "pcm_s16le",
                outputPath
            ]
        }
    }


    private func loadData() {
        var items: [MetaItem] = []
        isAnimatedImage = false
        clearRecognitionResults()
        previewImage = nil
        originalImagePixelSize = nil
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            fileCategory = .folder; loadFolder(&items); metadata = items; finishLoadingPreview(); return
        }
        if let a = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
            if let sz = a[.size] as? UInt64 { heroFileSize = fmtSz(sz); if settings.showFileSize { items.append(MetaItem(label: "文件大小", value: fmtSz(sz))) } }
            if settings.showCreateDate, let d = a[.creationDate] as? Date { items.append(MetaItem(label: "创建日期", value: fmtDtFull(d))) }
            if settings.showModifyDate, let d = a[.modificationDate] as? Date { items.append(MetaItem(label: "修改日期", value: fmtDtFull(d))) }
        }
        let ext = fileURL.pathExtension.lowercased(); heroFormat = ext.uppercased()
        if settings.showFormat { items.append(MetaItem(label: "文件格式", value: ext.uppercased())) }
        let webExts: Set<String> = ["html","htm","xhtml","shtml"]
        let svgExts: Set<String> = ["svg"]
        let codeExts: Set<String> = ["swift","py","js","ts","jsx","tsx","java","kt","c","cpp","h","m","mm","rs","go","rb","php","css","scss","json","xml","yaml","yml","toml","md","txt","text","log","out","err","trace","dump","sh","bash","zsh","sql","r","lua","dart","vue","svelte","ini","cfg","conf","config","properties","env","editorconfig","gitconfig"]
        let documentExts: Set<String> = ["pdf","doc","docx","ppt","pptx","xls","xlsx","numbers","key","pages","rtf","rtfd","odt","ods","odp","csv","tsv"]
        let mediaExts: Set<String> = ["webm", "mp4", "mov", "m4v", "avi", "mkv", "hevc"]
        if svgExts.contains(ext) {
            fileCategory = .image
            loadSVGMeta(&items)
            loadSVGPreview()
            metadata = items
            return
        }
        if webExts.contains(ext) {
            fileCategory = .web; loadWebMeta(&items); metadata = items; finishLoadingPreview(); return
        }
        if let ut = UTType(filenameExtension: ext) {
            if ut.conforms(to: .image) {
                fileCategory = .image
                loadImg(&items)
            }
            else if ut.conforms(to: .pdf) { fileCategory = .pdf; loadPdf(&items); loadPdfImg(); finishLoadingPreview() }
            else if documentExts.contains(ext) { fileCategory = .document; loadDocument(&items); finishLoadingPreview() }
            else if mediaExts.contains(ext) || ut.conforms(to: .audiovisualContent) { fileCategory = .media; loadMedia(&items); finishLoadingPreview() }
            else if codeExts.contains(ext) || ut.conforms(to: .sourceCode) || ut.conforms(to: .plainText) || canPreviewAsText(fileURL) { fileCategory = .code; loadCode(&items); finishLoadingPreview() }
            else { fileCategory = .other; metadata = items; loadGenericThumbnail(); return }
        } else if documentExts.contains(ext) { fileCategory = .document; loadDocument(&items); finishLoadingPreview() }
        else if mediaExts.contains(ext) { fileCategory = .media; loadMedia(&items); finishLoadingPreview() }
        else if codeExts.contains(ext) { fileCategory = .code; loadCode(&items); finishLoadingPreview() }
        else if canPreviewAsText(fileURL) { fileCategory = .code; loadCode(&items); finishLoadingPreview() }
        else { fileCategory = .other; metadata = items; loadGenericThumbnail(); return }
        metadata = items
    }

    private func loadImg(_ items: inout [MetaItem]) {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return }
        let frameCount = CGImageSourceGetCount(src)
        isAnimatedImage = frameCount > 1
        if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            if w > 0, h > 0 {
                mediaAspectRatio = CGFloat(w) / CGFloat(h)
                originalImagePixelSize = CGSize(width: w, height: h)
            }
            heroSize = "\(w) × \(h)"; if settings.showDimensions { items.append(MetaItem(label: "尺寸", value: "\(w) × \(h) px")) }
        }
        if isAnimatedImage {
            items.append(MetaItem(label: "播放预览", value: "动态图片"))
        }
        if settings.showColorSpace, let cm = p[kCGImagePropertyColorModel] as? String { items.append(MetaItem(label: "色彩空间", value: cm)) }
        if settings.showDPI, let dpi = p[kCGImagePropertyDPIWidth] as? Double { items.append(MetaItem(label: "分辨率", value: "\(Int(dpi)) DPI")) }
        if let d = p[kCGImagePropertyDepth] as? Int { items.append(MetaItem(label: "位深度", value: "\(d) bit")) }
        guard settings.showEXIF else { return }
        if let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any], let m = tiff[kCGImagePropertyTIFFModel] as? String { items.append(MetaItem(label: "设备型号", value: m)) }
        if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let f = exif[kCGImagePropertyExifFocalLength] as? Double { items.append(MetaItem(label: "焦距", value: String(format: "%.1f mm", f))) }
            if let fn = exif[kCGImagePropertyExifFNumber] as? Double { items.append(MetaItem(label: "光圈", value: String(format: "f/%.1f", fn))) }
            if let e = exif[kCGImagePropertyExifExposureTime] as? Double { items.append(MetaItem(label: "快门速度", value: e >= 1 ? String(format: "%.1f s", e) : "1/\(Int(1.0/e)) s")) }
            if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let v = iso.first { items.append(MetaItem(label: "ISO", value: "\(v)")) }
        }
        metadata = items
        Task { @MainActor in
            let payload = await loadImagePreviewPayload(for: fileURL)
            if let aspectRatio = payload.aspectRatio, aspectRatio > 0 {
                mediaAspectRatio = aspectRatio
            }
            if let pixelSize = payload.pixelSize {
                originalImagePixelSize = pixelSize
            }
            isAnimatedImage = payload.isAnimated
            if payload.isAnimated {
                previewImage = nil
            } else {
                previewImage = payload.image
            }
            finishLoadingPreview()
        }
    }

    private func loadPdf(_ items: inout [MetaItem]) {
        guard let doc = PDFDocument(url: fileURL) else { return }
        heroSize = "\(doc.pageCount) 页"
        if settings.showPDFPages { items.append(MetaItem(label: "总页数", value: "\(doc.pageCount) 页")) }
        if let a = doc.documentAttributes {
            if let au = a[PDFDocumentAttribute.authorAttribute] as? String, !au.isEmpty { items.append(MetaItem(label: "作者", value: au)) }
            if let t = a[PDFDocumentAttribute.titleAttribute] as? String, !t.isEmpty { items.append(MetaItem(label: "文档标题", value: t)) }
        }
    }

    private func loadDocument(_ items: inout [MetaItem]) {
        let ext = fileURL.pathExtension.lowercased()
        let spreadsheetExts: Set<String> = ["xls","xlsx","numbers","ods","csv","tsv"]
        let presentationExts: Set<String> = ["ppt","pptx","key","odp"]
        if spreadsheetExts.contains(ext) {
            heroSize = "表格"
            items.append(MetaItem(label: "预览方式", value: "可滚动文档预览"))
        } else if presentationExts.contains(ext) {
            heroSize = "幻灯片"
            items.append(MetaItem(label: "预览方式", value: "可翻页文档预览"))
        } else {
            heroSize = "文档"
            items.append(MetaItem(label: "预览方式", value: "完整文档预览"))
        }
    }

    private func loadPdfImg() {
        guard let doc = PDFDocument(url: fileURL), let pg = doc.page(at: 0) else { return }
        let b = pg.bounds(for: .mediaBox); let s: CGFloat = 500 / max(b.width, b.height)
        previewImage = pg.thumbnail(of: NSSize(width: b.width * s, height: b.height * s), for: .mediaBox)
    }

    private func loadMedia(_ items: inout [MetaItem]) {
        if isWebMFile {
            videoManager.cleanup()
            mediaAspectRatio = 16 / 9
            loadWebMMediaInfo()
            return
        }

        // Use VideoPlayerManager for safe async loading
        videoManager.loadVideo(url: fileURL)
        mediaAspectRatio = 16 / 9

        // Load metadata separately without blocking
        let asset = AVURLAsset(url: fileURL)
        Task { @MainActor [weak videoManager] in
            _ = videoManager  // capture to keep alive
            do {
                let duration = try await asset.load(.duration)
                let d = CMTimeGetSeconds(duration)
                if settings.showMediaDuration, d.isFinite, d > 0 {
                    let h = Int(d)/3600; let m = (Int(d)%3600)/60; let s = Int(d)%60
                    let str = h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
                    heroSize = str
                    metadata.append(MetaItem(label: "时长", value: str))
                }

                // Load video track info for resolution
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                if let track = videoTracks.first {
                    let naturalSize = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let sz = naturalSize.applying(transform)
                    let w = Int(abs(sz.width)), h = Int(abs(sz.height))
                    if w > 0 && h > 0 {
                        mediaAspectRatio = CGFloat(w) / CGFloat(h)
                        metadata.append(MetaItem(label: "分辨率", value: "\(w) × \(h)"))
                    }
                }

                // Load audio info
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                if !audioTracks.isEmpty {
                    metadata.append(MetaItem(label: "音频轨道", value: "\(audioTracks.count) 条"))
                }
            } catch {
                // Metadata loading failed — video may still play fine
            }
        }
    }

    private func loadWebMMediaInfo() {
        let url = fileURL
        Task.detached {
            guard let info = probeMediaInfo(for: url) else { return }
            await MainActor.run {
                if let duration = info.duration, settings.showMediaDuration, duration.isFinite, duration > 0 {
                    let value = formatDuration(duration)
                    heroSize = value
                    metadata.append(MetaItem(label: "时长", value: value))
                }

                if let width = info.width, let height = info.height, width > 0, height > 0 {
                    mediaAspectRatio = CGFloat(width) / CGFloat(height)
                    metadata.append(MetaItem(label: "分辨率", value: "\(width) × \(height)"))
                }
            }
        }
    }

    private func loadCode(_ items: inout [MetaItem]) {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let decoded = decodedTextContent(from: data) else { return }
        let c = decoded.text
        isRefreshingCodeText = true
        codeText = c
        DispatchQueue.main.async {
            isRefreshingCodeText = false
        }
        if settings.showCodeLines { let n = c.components(separatedBy: .newlines).count; heroSize = "\(n) 行"; items.append(MetaItem(label: "总行数", value: "\(n) 行")) }
        if settings.showEncoding { items.append(MetaItem(label: "字符编码", value: decoded.encodingName)) }
    }

    private func loadWebMeta(_ items: inout [MetaItem]) {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let content = String(data: data, encoding: .utf8) else { return }
        let lineCount = content.components(separatedBy: .newlines).count
        heroSize = "\(lineCount) 行"
        items.append(MetaItem(label: "总行数", value: "\(lineCount) 行"))
        // Extract <title> if present
        if let titleStart = content.range(of: "<title>", options: .caseInsensitive),
           let titleEnd = content.range(of: "</title>", options: .caseInsensitive, range: titleStart.upperBound..<content.endIndex) {
            let title = String(content[titleStart.upperBound..<titleEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { items.append(MetaItem(label: "页面标题", value: title)) }
        }
        if settings.showEncoding { items.append(MetaItem(label: "字符编码", value: "UTF-8")) }
    }

    private func loadSVGMeta(_ items: inout [MetaItem]) {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let content = String(data: data, encoding: .utf8) else {
            heroSize = "SVG"
            return
        }

        let parsed = parseSVGMetadata(from: content)
        heroSize = "SVG"
        items.append(MetaItem(label: "预览方式", value: "系统 SVG 渲染"))

        if let title = parsed.title {
            items.append(MetaItem(label: "标题", value: title))
        }

        if let canvasSize = parsed.canvasSize, canvasSize.width > 0, canvasSize.height > 0 {
            let width = Int(canvasSize.width.rounded())
            let height = Int(canvasSize.height.rounded())
            heroSize = "\(width) × \(height)"
            mediaAspectRatio = canvasSize.width / canvasSize.height
            if settings.showDimensions {
                items.append(MetaItem(label: "画板尺寸", value: "\(width) × \(height)"))
            }
        }

        if let viewBox = parsed.viewBox {
            items.append(MetaItem(label: "viewBox", value: "\(Int(viewBox.minX.rounded())) \(Int(viewBox.minY.rounded())) \(Int(viewBox.width.rounded())) \(Int(viewBox.height.rounded()))"))
        }

        if let widthAttribute = parsed.widthAttribute, !widthAttribute.isEmpty,
           let heightAttribute = parsed.heightAttribute, !heightAttribute.isEmpty {
            items.append(MetaItem(label: "声明尺寸", value: "\(widthAttribute) × \(heightAttribute)"))
        }

        if settings.showEncoding {
            items.append(MetaItem(label: "字符编码", value: "UTF-8"))
        }
    }

    private func loadSVGPreview() {
        Task { @MainActor in
            let payload = await loadImagePreviewPayload(for: fileURL)
            if let aspectRatio = payload.aspectRatio, aspectRatio > 0 {
                mediaAspectRatio = aspectRatio
            }
            previewImage = payload.image
            finishLoadingPreview()
        }
    }

    private func loadFolder(_ items: inout [MetaItem]) {
        let ext = fileURL.pathExtension.lowercased()
        let isApp = ext == "app" || ext == "prefpane" || ext == "plugin" || ext == "bundle" || ext == "framework"
        heroFormat = isApp ? ext.uppercased() : "文件夹"
        let fm = FileManager.default

        let totalSize = directorySize(at: fileURL)
        heroFileSize = fmtSz(totalSize)
        items.append(MetaItem(label: isApp ? "应用大小" : "总大小", value: fmtSz(totalSize)))

        if let a = try? fm.attributesOfItem(atPath: fileURL.path) {
            if let d = a[.creationDate] as? Date { items.append(MetaItem(label: "创建日期", value: fmtDtFull(d))) }
            if let d = a[.modificationDate] as? Date { items.append(MetaItem(label: "修改日期", value: fmtDtFull(d))) }
        }

        guard let c = try? fm.contentsOfDirectory(atPath: fileURL.path) else { return }
        let f = c.filter { !$0.hasPrefix(".") }; heroSize = "\(f.count) 项"
        items.append(MetaItem(label: "项目数", value: "\(f.count) 项"))

        var entries: [FolderEntry] = []
        for name in f.sorted() {
            let childURL = fileURL.appendingPathComponent(name)
            var isSub: ObjCBool = false; fm.fileExists(atPath: childURL.path, isDirectory: &isSub)
            let sz: UInt64 = isSub.boolValue ? directorySize(at: childURL) : (try? fm.attributesOfItem(atPath: childURL.path))?[.size] as? UInt64 ?? 0
            entries.append(FolderEntry(name: name, isDirectory: isSub.boolValue, size: sz))
        }
        folderItems = entries
    }

    private func directorySize(at url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  !(values.isDirectory ?? false),
                  let size = values.fileSize else { continue }
            total += UInt64(size)
        }
        return total
    }

    private func loadGenericThumbnail() {
        requestQuickLookThumbnail(for: fileURL) { image in
            previewImage = image ?? NSWorkspace.shared.icon(forFile: fileURL.path)
            finishLoadingPreview()
        }
    }

    private func finishLoadingPreview() {
        withAnimation(.easeOut(duration: 0.18)) {
            isLoadingPreview = false
        }
    }

    private func fmtSz(_ b: UInt64) -> String {
        let kb = Double(b)/1024; if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb/1024; if mb < 1024 { return String(format: "%.2f MB", mb) }
        return String(format: "%.2f GB", mb/1024)
    }

    private func fmtDt(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: d) }

    private func fmtDtFull(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: d) }
}

private struct ConversionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct MediaProbeInfo {
    let width: Int?
    let height: Int?
    let duration: Double?
}

private func probeMediaInfo(for url: URL) -> MediaProbeInfo? {
    let candidates = [
        "/opt/homebrew/bin/ffprobe",
        "/usr/local/bin/ffprobe",
        "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe",
        "/usr/local/opt/ffmpeg-full/bin/ffprobe"
    ]

    guard let ffprobePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        return nil
    }

    let output = runProbe(
        executablePath: ffprobePath,
        arguments: [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height:format=duration",
            "-of", "default=noprint_wrappers=1",
            url.path
        ]
    )

    guard !output.isEmpty else { return nil }

    var width: Int?
    var height: Int?
    var duration: Double?
    output
        .split(separator: "\n")
        .map(String.init)
        .forEach { line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            switch parts[0] {
            case "width": width = Int(parts[1])
            case "height": height = Int(parts[1])
            case "duration": duration = Double(parts[1])
            default: break
            }
        }

    return MediaProbeInfo(width: width, height: height, duration: duration)
}

private func runProbe(executablePath: String, arguments: [String], timeout: TimeInterval = 3) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            waitGroup.leave()
        }

        if waitGroup.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return ""
    }
}

private func formatDuration(_ seconds: Double) -> String {
    let totalSeconds = max(0, Int(seconds.rounded()))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}

private struct ResizeExportRequest {
    let width: Int
    let height: Int
    let keepAspectRatio: Bool
}

private final class ResizeExportAccessoryView: NSView, NSTextFieldDelegate {
    let widthField = NSTextField()
    let heightField = NSTextField()
    let keepAspectRatioButton = NSButton(checkboxWithTitle: "保持比例", target: nil, action: nil)
    private let originalSize: CGSize
    private var isSyncing = false

    init(originalSize: CGSize) {
        self.originalSize = originalSize
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 112))

        widthField.stringValue = "\(max(1, Int(originalSize.width.rounded())))"
        heightField.stringValue = "\(max(1, Int(originalSize.height.rounded())))"
        widthField.placeholderString = "宽度"
        heightField.placeholderString = "高度"
        widthField.formatter = positiveIntegerFormatter()
        heightField.formatter = positiveIntegerFormatter()
        keepAspectRatioButton.state = .on

        let widthLabel = NSTextField(labelWithString: "宽")
        let heightLabel = NSTextField(labelWithString: "高")
        let note = NSTextField(wrappingLabelWithString: "不会裁剪内容，只缩放到指定尺寸。动图和视频会尽量保留动画、音频和透明信息。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)

        [widthLabel, heightLabel, widthField, heightField, keepAspectRatioButton, note].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        widthField.target = self
        widthField.action = #selector(widthChanged)
        widthField.delegate = self
        heightField.target = self
        heightField.action = #selector(heightChanged)
        heightField.delegate = self
        keepAspectRatioButton.target = self
        keepAspectRatioButton.action = #selector(aspectLockChanged)

        NSLayoutConstraint.activate([
            widthLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            widthLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            widthLabel.widthAnchor.constraint(equalToConstant: 28),
            widthField.leadingAnchor.constraint(equalTo: widthLabel.trailingAnchor, constant: 6),
            widthField.centerYAnchor.constraint(equalTo: widthLabel.centerYAnchor),
            widthField.widthAnchor.constraint(equalToConstant: 88),

            heightLabel.leadingAnchor.constraint(equalTo: widthField.trailingAnchor, constant: 14),
            heightLabel.centerYAnchor.constraint(equalTo: widthLabel.centerYAnchor),
            heightLabel.widthAnchor.constraint(equalToConstant: 28),
            heightField.leadingAnchor.constraint(equalTo: heightLabel.trailingAnchor, constant: 6),
            heightField.centerYAnchor.constraint(equalTo: widthLabel.centerYAnchor),
            heightField.widthAnchor.constraint(equalToConstant: 88),

            keepAspectRatioButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            keepAspectRatioButton.topAnchor.constraint(equalTo: widthField.bottomAnchor, constant: 12),

            note.leadingAnchor.constraint(equalTo: leadingAnchor),
            note.trailingAnchor.constraint(equalTo: trailingAnchor),
            note.topAnchor.constraint(equalTo: keepAspectRatioButton.bottomAnchor, constant: 8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var request: ResizeExportRequest? {
        let width = max(1, widthField.integerValue)
        let height = max(1, heightField.integerValue)
        guard width > 0, height > 0 else { return nil }
        return ResizeExportRequest(width: width, height: height, keepAspectRatio: keepAspectRatioButton.state == .on)
    }

    @objc private func widthChanged() {
        guard keepAspectRatioButton.state == .on else { return }
        syncHeightFromWidth()
    }

    @objc private func heightChanged() {
        guard keepAspectRatioButton.state == .on else { return }
        syncWidthFromHeight()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard keepAspectRatioButton.state == .on,
              let field = notification.object as? NSTextField else {
            return
        }

        if field === widthField {
            syncHeightFromWidth()
        } else if field === heightField {
            syncWidthFromHeight()
        }
    }

    @objc private func aspectLockChanged() {
        if keepAspectRatioButton.state == .on {
            syncHeightFromWidth()
        }
    }

    private func syncHeightFromWidth() {
        guard !isSyncing, originalSize.width > 0 else { return }
        isSyncing = true
        let height = max(1, Int((CGFloat(max(1, widthField.integerValue)) * originalSize.height / originalSize.width).rounded()))
        heightField.stringValue = "\(height)"
        isSyncing = false
    }

    private func syncWidthFromHeight() {
        guard !isSyncing, originalSize.height > 0 else { return }
        isSyncing = true
        let width = max(1, Int((CGFloat(max(1, heightField.integerValue)) * originalSize.width / originalSize.height).rounded()))
        widthField.stringValue = "\(width)"
        isSyncing = false
    }

    private func positiveIntegerFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 50000
        formatter.allowsFloats = false
        return formatter
    }
}

private enum ExportFormat: CaseIterable, Hashable {
    case png
    case gif
    case webp
    case apng
    case mp4
    case mov
    case webm
    case mp3
    case wav

    var displayName: String {
        switch self {
        case .png: return " PNG"
        case .gif: return " GIF"
        case .webp: return " WebP"
        case .apng: return " APNG"
        case .mp4: return " MP4"
        case .mov: return " MOV"
        case .webm: return " WebM"
        case .mp3: return " MP3"
        case .wav: return " WAV"
        }
    }

    var menuLabel: String {
        switch self {
        case .png: return "PNG"
        case .gif: return "GIF"
        case .webp: return "WebP"
        case .apng: return "APNG"
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .webm: return "WebM"
        case .mp3: return "MP3"
        case .wav: return "WAV"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .gif: return "gif"
        case .webp: return "webp"
        case .apng: return "png"
        case .mp4: return "mp4"
        case .mov: return "mov"
        case .webm: return "webm"
        case .mp3: return "mp3"
        case .wav: return "wav"
        }
    }

    var contentType: UTType {
        switch self {
        case .png:
            return .png
        case .gif:
            return .gif
        case .webp:
            return UTType(filenameExtension: "webp") ?? .data
        case .apng:
            return .png
        case .mp4:
            return .mpeg4Movie
        case .mov:
            return .movie
        case .webm:
            return UTType(filenameExtension: "webm") ?? .movie
        case .mp3:
            return .mp3
        case .wav:
            return .wav
        }
    }
}

private struct ConversionStatus {
    let title: String
    let message: String
    let outputURL: URL?
    let isSuccess: Bool
}
