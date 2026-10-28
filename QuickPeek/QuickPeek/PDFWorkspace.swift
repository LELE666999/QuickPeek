import SwiftUI
import AppKit
import PDFKit
import Vision
import AVFoundation
import UniformTypeIdentifiers

struct DocumentPageText: Codable, Sendable {
    let page: Int
    let text: String
}

struct DocumentToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Page numbers in the UI are one-based. Preserve the user's order, rejecting invalid input.
enum PDFPageRange {
    static func parse(_ input: String, count: Int) throws -> [Int] {
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Array(0..<count) }
        var result: [Int] = []
        for part in input.replacingOccurrences(of: "，", with: ",").split(separator: ",", omittingEmptySubsequences: false) {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(pair.count), let first = Int(pair[0]), first > 0, first <= count else {
                throw DocumentToolError("页码无效，请输入 1,3,5-8 这样的页码，范围为 1–\(count)。")
            }
            let last = pair.count == 2 ? Int(pair[1]) : first
            guard let last, last >= first, last <= count else { throw DocumentToolError("页码范围无效。") }
            for value in first...last where !result.contains(value - 1) { result.append(value - 1) }
        }
        return result
    }
}

@MainActor
final class PDFDocumentController: ObservableObject {
    @Published var document: PDFDocument?
    @Published var currentPageIndex = 0
    @Published var revision = 0
    @Published var isEdited = false
    @Published var message = ""
    @Published var isBusy = false
    @Published var usesCompatibilityRenderer = false
    @Published var showPrintOnlyStamps = false
    @Published var searchQuery = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var searchIndex = 0
    @Published var showTools = false
    @Published var showAI = false
    weak var pdfView: PDFView?
    let fileURL: URL
    private var undoStates: [Data] = []
    private var redoStates: [Data] = []
    private let thumbnails = NSCache<NSNumber, NSImage>()
    let speaker = AVSpeechSynthesizer()

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.document = fileURL.pathExtension.lowercased() == "pdf" ? PDFDocument(url: fileURL) : nil
        thumbnails.countLimit = 60
        if document == nil && fileURL.pathExtension.lowercased() == "pdf" { message = "无法读取这个 PDF，文件可能损坏。" }
    }
    var pageCount: Int { document?.pageCount ?? 0 }
    var canUndo: Bool { !undoStates.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }
    var canCopy: Bool { document?.allowsCopying == true }
    var isRendering: Bool { isBusy }
    var currentImage: NSImage? { document?.page(at: currentPageIndex).map { Self.render($0, width: 1600) } }
    var printOnlyAnnotationCount: Int {
        (0..<pageCount).reduce(0) { count, i in count + (document?.page(at: i)?.annotations.filter { !$0.shouldDisplay && $0.shouldPrint }.count ?? 0) }
    }
    func thumbnail(at index: Int) -> NSImage? {
        if let image = thumbnails.object(forKey: NSNumber(value: index)) { return image }
        guard let page = document?.page(at: index) else { return nil }
        let image = Self.render(page, width: 180)
        thumbnails.setObject(image, forKey: NSNumber(value: index))
        return image
    }
    /// Draw the actual page, including appearance streams, instead of a Quick Look file thumbnail.
    static func render(_ page: PDFPage, width: CGFloat = 1600) -> NSImage {
        page.displaysAnnotations = true
        let size = page.bounds(for: .cropBox).size
        let rotated = abs(page.rotation % 180) == 90
        let ratio = rotated ? size.width / max(1, size.height) : size.height / max(1, size.width)
        return page.thumbnail(of: CGSize(width: width, height: width * ratio), for: .cropBox)
    }
    func setCurrentPage(_ index: Int) {
        guard index >= 0, index < pageCount else { return }
        currentPageIndex = index
    }
    func copyCurrentPage() { copyPage(at: currentPageIndex) }
    func copyPage(at index: Int) {
        guard canCopy, let page = document?.page(at: index) else { message = "文档不允许复制内容。"; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([Self.render(page)])
    }
    func copyDocument() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([fileURL as NSURL])
    }
    func exportPage(at index: Int) { perform { try exportImages(indices: [index], jpeg: false) } }
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { message = error.localizedDescription }
    }
    func unlock(_ password: String) {
        guard document?.unlock(withPassword: password) == true else { message = "密码不正确。"; return }
        refresh()
    }
    private func checkpoint() throws {
        guard let document, !document.isLocked, let data = document.dataRepresentation() else { throw DocumentToolError("文档尚未解锁或无法读取。") }
        undoStates.append(data)
        while undoStates.count > 1 && (undoStates.count > 12 || undoStates.reduce(0, { $0 + $1.count }) > 64 * 1024 * 1024) { undoStates.removeFirst() }
        redoStates.removeAll()
    }
    func refresh(edited: Bool = false) {
        revision += 1; thumbnails.removeAllObjects(); searchResults = []
        currentPageIndex = min(currentPageIndex, max(0, pageCount - 1))
        if edited { isEdited = true; usesCompatibilityRenderer = false }
    }
    func undo() { restore(fromUndo: true) }
    func redo() { restore(fromUndo: false) }
    private func restore(fromUndo: Bool) {
        guard let current = document?.dataRepresentation(), let saved = fromUndo ? undoStates.popLast() : redoStates.popLast(), let restored = PDFDocument(data: saved) else { return }
        if fromUndo { redoStates.append(current) } else { undoStates.append(current) }
        document = restored; refresh(edited: true)
    }
    func requireCopy() throws {
        guard canCopy else { throw DocumentToolError("此 PDF 限制了内容复制，请先使用所有者密码解锁。") }
    }
    private func requireEditing() throws {
        guard document?.allowsDocumentChanges == true else { throw DocumentToolError("此 PDF 不允许修改页面。") }
    }
    func deleteCurrentPage() { perform { try deletePages([currentPageIndex]) } }
    func deletePages(_ indices: [Int]) throws {
        try requireEditing()
        guard !indices.isEmpty, indices.count < pageCount else { throw DocumentToolError("至少需要保留一页。") }
        try checkpoint()
        for i in Set(indices).sorted(by: >) { document?.removePage(at: i) }
        refresh(edited: true)
    }
    func rotatePages(_ indices: [Int]) throws {
        try requireEditing(); try checkpoint()
        for i in indices { if let page = document?.page(at: i) { page.rotation = (page.rotation + 90) % 360 } }
        refresh(edited: true)
    }
    func movePage(_ from: Int, by offset: Int) throws {
        let to = from + offset
        guard to >= 0, to < pageCount, let page = document?.page(at: from) else { return }
        try requireEditing(); try checkpoint()
        document?.removePage(at: from); document?.insert(page, at: to); currentPageIndex = to; refresh(edited: true)
    }
    func mergeFiles(images: Bool = false) throws {
        try requireEditing()
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = images ? [.png, .jpeg, .tiff, .heic] : [.pdf]
        guard panel.runModal() == .OK else { return }
        // Validate everything before changing the working document.
        var pages: [PDFPage] = []
        for url in panel.urls {
            if images {
                guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { throw DocumentToolError("无法读取图片：\(url.lastPathComponent)") }
                pages.append(page)
            } else {
                guard let other = PDFDocument(url: url), !other.isLocked else { throw DocumentToolError("合并文件无法读取或已加密：\(url.lastPathComponent)") }
                guard other.allowsCopying else { throw DocumentToolError("合并文件限制了复制。") }
                pages += (0..<other.pageCount).compactMap { other.page(at: $0)?.copy() as? PDFPage }
            }
        }
        try checkpoint()
        for page in pages { document?.insert(page, at: pageCount) }
        refresh(edited: true)
    }
    func search() {
        guard canCopy, !searchQuery.isEmpty else { searchResults = []; pdfView?.highlightedSelections = []; return }
        searchResults = document?.findString(searchQuery, withOptions: [.caseInsensitive]) ?? []
        searchIndex = 0; goToSearch()
    }
    func goToSearch(_ delta: Int = 0) {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + delta + searchResults.count) % searchResults.count
        let result = searchResults[searchIndex]; result.color = .systemYellow.withAlphaComponent(0.4)
        pdfView?.highlightedSelections = searchResults; pdfView?.setCurrentSelection(result, animate: true)
        pdfView?.go(to: result)
    }
    func annotate(_ kind: PDFAnnotationSubtype) throws {
        guard document?.allowsCommenting == true else { throw DocumentToolError("此 PDF 不允许批注。") }
        guard let selection = pdfView?.currentSelection, !(selection.string ?? "").isEmpty else { throw DocumentToolError("先在页面上拖动选择文字，再添加标记。") }
        try checkpoint()
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let annotation = PDFAnnotation(bounds: line.bounds(for: page), forType: kind, withProperties: nil)
                annotation.color = kind == .highlight ? .systemYellow.withAlphaComponent(0.45) : .systemRed
                page.addAnnotation(annotation)
            }
        }
        refresh(edited: true)
    }
    func addNote(_ text: String, watermark: Bool = false) throws {
        guard document?.allowsCommenting == true, let page = document?.page(at: currentPageIndex), !text.isEmpty else { throw DocumentToolError("请输入文字，且文档必须允许批注。") }
        try checkpoint()
        let bounds = page.bounds(for: .cropBox)
        let rect = watermark ? CGRect(x: bounds.minX + 24, y: bounds.midY - 25, width: bounds.width - 48, height: 70) : CGRect(x: bounds.minX + 32, y: bounds.maxY - 110, width: min(300, bounds.width - 64), height: 70)
        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.contents = text; annotation.font = .systemFont(ofSize: watermark ? 36 : 14)
        annotation.fontColor = watermark ? .systemRed.withAlphaComponent(0.28) : .labelColor
        annotation.color = watermark ? .clear : .systemYellow.withAlphaComponent(0.25)
        annotation.alignment = watermark ? .center : .left
        page.addAnnotation(annotation); refresh(edited: true)
    }
    func beginFormEditing() {
        guard document?.allowsFormFieldEntry == true else { return }
        perform { try checkpoint(); isEdited = true }
    }
    func saveCopy(indices: [Int]? = nil, flatten: Bool = false, compress: Bool = false, searchable: Bool = false, password: String = "") throws {
        guard let document, !document.isLocked else { throw DocumentToolError("请先解锁 PDF。") }
        if indices != nil { try requireCopy() }
        // Commit an active native form editor before serializing the document.
        pdfView?.window?.makeFirstResponder(pdfView)
        let target: PDFDocument
        if let indices {
            target = PDFDocument()
            for i in indices { if let page = document.page(at: i)?.copy() as? PDFPage { target.insert(page, at: target.pageCount) } }
        } else { target = document }
        guard let url = saveURL(ext: "pdf", suffix: flatten ? "-印章固化" : searchable ? "-可搜索" : compress ? "-压缩" : "-副本") else { return }
        guard url.standardizedFileURL != fileURL.standardizedFileURL else { throw DocumentToolError("请选择新的文件名以保留原文件及其签名。") }
        var options: [PDFDocumentWriteOption: Any] = [.burnInAnnotationsOption: flatten, .saveTextFromOCROption: searchable, .saveImagesAsJPEGOption: compress, .optimizeImagesForScreenOption: compress]
        if !password.isEmpty { options[.userPasswordOption] = password; options[.ownerPasswordOption] = UUID().uuidString }
        guard let data = target.dataRepresentation(options: options) else { throw DocumentToolError("PDF 编码失败。") }
        try data.write(to: url, options: .atomic)
        message = "已保存：\(url.lastPathComponent)\(compress ? "。压缩效果取决于原文件图片。" : "")"
    }
    func saveURL(ext: String, suffix: String = "") -> URL? {
        let panel = NSSavePanel(); panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + suffix + "." + ext
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.directoryURL = fileURL.deletingLastPathComponent(); panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    func exportImages(indices: [Int], jpeg: Bool) throws {
        try requireCopy()
        if indices.count == 1, let i = indices.first, let page = document?.page(at: i) {
            guard let url = saveURL(ext: jpeg ? "jpg" : "png", suffix: "-第\(i + 1)页") else { return }
            try DocumentExport.imageData(Self.render(page), jpeg: jpeg).write(to: url, options: .atomic)
        } else {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "导出到此文件夹"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let output = folder.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + "-页面-" + String(UUID().uuidString.prefix(6)))
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for i in indices { if let page = document?.page(at: i) {
                try DocumentExport.imageData(Self.render(page), jpeg: jpeg).write(to: output.appendingPathComponent(String(format: "%04d.%@", i + 1, jpeg ? "jpg" : "png")), options: .atomic)
            } }
        }
        message = "页面图片已导出（包含可见批注）。"
    }
    func extractEmbeddedImages(_ indices: [Int]) throws {
        try requireCopy()
        guard let document else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "提取到此文件夹"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let output = folder.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + "-内嵌图片-" + String(UUID().uuidString.prefix(6)))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let result = try DocumentExport.embeddedImages(document: document, indices: indices, folder: output)
        message = "已提取 \(result.exported) 张内嵌图片，跳过 \(result.skipped) 张不支持的图片；复杂蒙版、索引色和内联图可使用页面 PNG 导出保留外观。"
    }
    func textPages(indices: [Int]? = nil, ocr: Bool = true) async throws -> [DocumentPageText] {
        try requireCopy()
        guard !isBusy else { throw DocumentToolError("另一个文档任务正在运行。") }
        isBusy = true; defer { isBusy = false }
        let indices = indices ?? Array(0..<pageCount)
        var pages: [DocumentPageText] = []
        for index in indices {
            try Task.checkCancellation()
            guard let page = document?.page(at: index) else { continue }
            var text = page.string ?? ""
            if ocr && text.trimmingCharacters(in: .whitespacesAndNewlines).count < 5 {
                message = "正在识别第 \(index + 1) / \(pageCount) 页…"
                let image = Self.render(page, width: 1800)
                if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    text = try await Task.detached(priority: .userInitiated) {
                        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]; request.usesLanguageCorrection = true
                        try VNImageRequestHandler(cgImage: cg).perform([request])
                        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    }.value
                }
            }
            pages.append(DocumentPageText(page: index + 1, text: text))
            await Task.yield()
        }
        message = "已读取 \(pages.count) 页。"
        return pages
    }
    func exportText(format: String, indices: [Int]) async {
        do {
            let pages = try await textPages(indices: indices)
            guard let url = saveURL(ext: format, suffix: "-文字") else { return }
            try DocumentExport.text(pages: pages, format: format, to: url)
            message = "已导出 \(format.uppercased())。"
        } catch { message = error.localizedDescription }
    }
    func readAloud() async {
        if speaker.isSpeaking { speaker.stopSpeaking(at: .immediate); return }
        do {
            let pages = try await textPages(indices: [currentPageIndex])
            let utterance = AVSpeechUtterance(string: pages.map(\.text).joined(separator: "\n"))
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN"); speaker.speak(utterance)
        } catch { message = error.localizedDescription }
    }
}

final class DocumentPDFView: PDFView {
    var willEditForm: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: false), page.annotation(at: convert(point, to: page))?.type == "Widget" { willEditForm?() }
        super.mouseDown(with: event)
    }
    override func magnify(with event: NSEvent) {
        autoScales = false
        scaleFactor = min(maxScaleFactor, max(minScaleFactor, scaleFactor * (1 + event.magnification)))
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            autoScales = false; scaleFactor = min(maxScaleFactor, max(minScaleFactor, scaleFactor * exp(event.scrollingDeltaY * 0.006)))
        } else { super.scrollWheel(with: event) }
    }
}

struct NativeDocumentPDFView: NSViewRepresentable {
    @ObservedObject var controller: PDFDocumentController
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeNSView(context: Context) -> DocumentPDFView {
        let view = DocumentPDFView(); view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.displaysPageBreaks = true; view.pageBreakMargins = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.backgroundColor = .clear; view.minScaleFactor = 0.1; view.maxScaleFactor = 12
        view.document = controller.document; view.autoScales = true; controller.pdfView = view
        view.willEditForm = { [weak controller] in controller?.beginFormEditing() }
        context.coordinator.view = view
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.changed), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.annotationWillChange), name: .PDFViewAnnotationWillHit, object: view)
        return view
    }
    func updateNSView(_ view: DocumentPDFView, context: Context) {
        if view.document !== controller.document { view.document = controller.document; view.autoScales = true }
        if context.coordinator.revision != controller.revision {
            context.coordinator.revision = controller.revision; view.layoutDocumentView(); view.needsDisplay = true
        }
        if let document = controller.document, let page = document.page(at: controller.currentPageIndex), view.currentPage !== page { view.go(to: page) }
    }
    static func dismantleNSView(_ view: DocumentPDFView, coordinator: Coordinator) { NotificationCenter.default.removeObserver(coordinator) }
    @MainActor final class Coordinator: NSObject {
        let controller: PDFDocumentController
        weak var view: PDFView?
        var revision = -1
        init(_ controller: PDFDocumentController) { self.controller = controller }
        @objc func annotationWillChange() {
            if view?.currentPage?.annotations.contains(where: { $0.type == "Widget" }) == true { controller.beginFormEditing() }
        }
        @objc func changed() {
            guard let view, let page = view.currentPage, let doc = view.document else { return }
            let index = doc.index(for: page)
            if controller.currentPageIndex != index { controller.currentPageIndex = index }
        }
    }
}

struct PDFDocumentBrowserView: View {
    @ObservedObject var controller: PDFDocumentController
    @State private var password = ""
    var body: some View {
        VStack(spacing: 10) {
            if controller.document?.isLocked == true {
                Spacer(); Image(systemName: "lock.doc").font(.system(size: 40)); Text("此 PDF 已加密")
                SecureField("文档密码", text: $password).glassInput().frame(width: 240).onSubmit { controller.unlock(password); password = "" }
                Button("解锁", systemImage: "lock.open") { controller.unlock(password); password = "" }.buttonStyle(QuickPeekGlassButtonStyle(tone: .accent)); Spacer()
            } else if controller.document == nil {
                ContentUnavailableView("无法读取 PDF", systemImage: "doc.badge.ellipsis", description: Text(controller.message))
            } else {
                readerToolbar
                HStack(spacing: 10) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(0..<controller.pageCount, id: \.self) { i in
                                    Button { controller.setCurrentPage(i) } label: {
                                        VStack(spacing: 5) {
                                            if let image = controller.thumbnail(at: i) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 140) }
                                            Text("\(i + 1)").font(.caption).foregroundStyle(.secondary)
                                        }.padding(7).frame(maxWidth: .infinity)
                                            .background(controller.currentPageIndex == i ? Color.accentColor.opacity(0.23) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                    }.buttonStyle(.plain).id(i)
                                    .contextMenu {
                                        Button("导出此页 PNG…") { controller.exportPage(at: i) }
                                        Button("顺时针旋转") { controller.perform { try controller.rotatePages([i]) } }
                                        Button("向前移动") { controller.perform { try controller.movePage(i, by: -1) } }.disabled(i == 0)
                                        Button("向后移动") { controller.perform { try controller.movePage(i, by: 1) } }.disabled(i == controller.pageCount - 1)
                                    }
                                }
                            }.padding(6)
                        }.onChange(of: controller.currentPageIndex) { _, index in withAnimation { proxy.scrollTo(index) } }
                    }.frame(width: 116).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    Group {
                        if controller.usesCompatibilityRenderer { PDFCompatibilityView(controller: controller) }
                        else { NativeDocumentPDFView(controller: controller) }
                    }.clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            if !controller.message.isEmpty {
                HStack { Text(controller.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled); Spacer(); Button { controller.message = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(.horizontal, 8)
            }
        }
        .sheet(isPresented: Binding(get: { controller.showTools || controller.showAI }, set: { visible in
            if !visible { controller.showTools = false; controller.showAI = false }
        })) { DocumentWorkspaceView(controller: controller, initialPage: controller.showAI ? .ai : .tools) }
        .onDisappear { controller.speaker.stopSpeaking(at: .immediate) }
    }
    private var readerToolbar: some View {
        HStack(spacing: 10) {
            Text("\(controller.currentPageIndex + 1) / \(controller.pageCount)")
                .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            if controller.isEdited { Image(systemName: "pencil.circle.fill").foregroundStyle(Color.accentColor).help("已编辑，原文件保留") }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("查找文档", text: $controller.searchQuery)
                    .onSubmit { controller.search() }.accessibilityLabel("查找文档")
            }.glassInput(height: 34).frame(minWidth: 110, maxWidth: 200)
                .disabled(controller.usesCompatibilityRenderer)
            if !controller.searchResults.isEmpty {
                Text("\(controller.searchIndex + 1)/\(controller.searchResults.count)").font(.caption.monospacedDigit())
                GlassIconButton(title: "上一个结果", icon: "chevron.up") { controller.goToSearch(-1) }
                GlassIconButton(title: "下一个结果", icon: "chevron.down") { controller.goToSearch(1) }
            }
            GlassIconButton(title: "缩小", icon: "minus.magnifyingglass") { controller.pdfView?.autoScales = false; controller.pdfView?.zoomOut(nil) }
                .disabled(controller.usesCompatibilityRenderer)
            Button("适合", systemImage: "arrow.up.left.and.arrow.down.right") { controller.pdfView?.autoScales = true }
                .buttonStyle(QuickPeekGlassButtonStyle(height: 34, horizontalPadding: 12))
                .disabled(controller.usesCompatibilityRenderer)
            GlassIconButton(title: "放大", icon: "plus.magnifyingglass") { controller.pdfView?.autoScales = false; controller.pdfView?.zoomIn(nil) }
                .disabled(controller.usesCompatibilityRenderer)
            Button("印章兼容", systemImage: controller.usesCompatibilityRenderer ? "checkmark.seal.fill" : "checkmark.seal") {
                controller.usesCompatibilityRenderer.toggle()
            }.buttonStyle(QuickPeekGlassButtonStyle(selected: controller.usesCompatibilityRenderer, height: 34, horizontalPadding: 12))
                .help("离线显示印章与表单外观；需要编辑时切回原生视图。")
        }.padding(.horizontal, 4).padding(.vertical, 3)
    }
}

enum DocumentWorkspacePage: Int, CaseIterable {
    case tools, ai, settings
}

/// One edge-to-edge scrolling workspace, with navigation floating above its content.
struct DocumentWorkspaceView: View {
    @ObservedObject var controller: PDFDocumentController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: DocumentWorkspacePage

    init(controller: PDFDocumentController, initialPage: DocumentWorkspacePage = .tools) {
        self.controller = controller
        _page = State(initialValue: initialPage)
    }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                PDFToolsView(controller: controller, embedded: true)
                    .frame(width: geometry.size.width)
                    .accessibilityHidden(page != .tools).allowsHitTesting(page == .tools)
                DocumentAIView(controller: controller, embedded: true, onShowSettings: { page = .settings })
                    .frame(width: geometry.size.width)
                    .accessibilityHidden(page != .ai).allowsHitTesting(page == .ai)
                ScrollView {
                    AISettingsView().frame(maxWidth: 600)
                        .frame(maxWidth: .infinity).padding(.top, 90).padding(.bottom, 26)
                }.scrollIndicators(.hidden).frame(width: geometry.size.width)
                    .accessibilityHidden(page != .settings).allowsHitTesting(page == .settings)
            }
            .frame(width: geometry.size.width * 3, height: geometry.size.height, alignment: .leading)
            .offset(x: -CGFloat(page.rawValue) * geometry.size.width)
        }
        .clipped()
        .background { DocumentSheetBackground() }
        .background { DocumentWorkspaceSwipeReader { direction in
            if let destination = DocumentWorkspacePage(rawValue: page.rawValue + direction) { page = destination }
        } }
        .overlay(alignment: .top) { floatingNavigation.padding(.top, 18) }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88), value: page)
        .frame(width: 940, height: 740)
    }
    private var floatingNavigation: some View {
        HStack(spacing: 9) {
            Button("文档工具", systemImage: "doc.richtext") { page = .tools }
                .buttonStyle(QuickPeekGlassButtonStyle(selected: page == .tools, height: 42))
                .accessibilityAddTraits(page == .tools ? .isSelected : [])
            Button("文档 AI", systemImage: "sparkles") { page = .ai }
                .buttonStyle(QuickPeekGlassButtonStyle(selected: page == .ai, height: 42))
                .accessibilityAddTraits(page == .ai ? .isSelected : [])
            Button { page = .settings } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(QuickPeekGlassButtonStyle(selected: page == .settings, height: 42, horizontalPadding: 14))
                .accessibilityLabel("AI 服务设置").help("AI 服务设置")
            Button("完成", systemImage: "checkmark") { dismiss() }
                .buttonStyle(QuickPeekGlassButtonStyle(height: 42))
        }
    }
}

private struct DocumentWorkspaceSwipeReader: NSViewRepresentable {
    var navigate: (Int) -> Void
    func makeNSView(context: Context) -> SwipeView { let view = SwipeView(); view.navigate = navigate; return view }
    func updateNSView(_ view: SwipeView, context: Context) { view.navigate = navigate }
    static func dismantleNSView(_ view: SwipeView, coordinator: ()) { view.stopMonitoring() }
    final class SwipeView: NSView {
        var navigate: ((Int) -> Void)?
        private var monitor: Any?
        private var distance: CGFloat = 0
        private var switched = false
        private var lastTime: TimeInterval = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
                guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                if event.type == .swipe, event.deltaX != 0 { self.navigate?(event.deltaX > 0 ? -1 : 1); return nil }
                guard event.momentumPhase.isEmpty else { return event }
                if event.phase == .began || event.timestamp - self.lastTime > 0.35 { self.distance = 0; self.switched = false }
                self.lastTime = event.timestamp
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 2 else { return event }
                self.distance += event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 12)
                if !self.switched && abs(self.distance) >= 80 {
                    self.switched = true; self.navigate?(self.distance > 0 ? -1 : 1)
                }
                return nil
            }
        }
        func stopMonitoring() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

struct PDFToolsView: View {
    @ObservedObject var controller: PDFDocumentController
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var range = ""
    @State private var note = ""
    @State private var password = ""
    @State private var showNote = false
    @State private var showWatermark = false
    @State private var showEncryption = false
    @State private var showInfo = false
    private func indices() throws -> [Int] { try PDFPageRange.parse(range, count: controller.pageCount) }
    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 25) {
            header
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
                    TextField("全部页面，或输入 1,3,5-8", text: $range).accessibilityLabel("操作页码")
                }.glassInput()
                Button("当前页") { range = "\(controller.currentPageIndex + 1)" }
                    .buttonStyle(QuickPeekGlassButtonStyle())
                GlassIconButton(title: "撤回", icon: "arrow.uturn.backward") { controller.undo() }.disabled(!controller.canUndo)
                GlassIconButton(title: "重做", icon: "arrow.uturn.forward") { controller.redo() }.disabled(!controller.canRedo)
            }
                    toolSection("页面") {
                        GlassToolButton(title: "旋转页面", icon: "rotate.right") { controller.perform { try controller.rotatePages(indices()) } }
                        GlassToolButton(title: "删除页面", icon: "trash", tone: .destructive) { controller.perform { try controller.deletePages(indices()) } }
                        GlassToolButton(title: "合并 PDF", icon: "doc.on.doc") { controller.perform { try controller.mergeFiles() } }
                        GlassToolButton(title: "插入图片", icon: "photo.badge.plus") { controller.perform { try controller.mergeFiles(images: true) } }
                        GlassToolButton(title: "提取页面", icon: "square.on.square.dashed") { controller.perform { try controller.saveCopy(indices: indices()) } }
                    }
                    toolSection("标记与批注") {
                        GlassToolButton(title: "高亮文字", icon: "highlighter") { controller.perform { try controller.annotate(.highlight) } }.help("在原生 PDF 视图中选中文字后使用")
                        GlassToolButton(title: "下划线", icon: "underline") { controller.perform { try controller.annotate(.underline) } }
                        GlassToolButton(title: "删除线", icon: "strikethrough") { controller.perform { try controller.annotate(.strikeOut) } }
                        GlassToolButton(title: "朗读页面", icon: "speaker.wave.2") { Task { await controller.readAloud() } }
                        GlassToolButton(title: "添加批注", icon: "text.bubble") { showNote = true }
                            .popover(isPresented: $showNote) { annotationEditor(watermark: false) }
                        GlassToolButton(title: "添加水印", icon: "drop.halffull") { showWatermark = true }
                            .popover(isPresented: $showWatermark) { annotationEditor(watermark: true) }
                    }
                    toolSection("转换与提取") {
                        Menu {
                            Button("PNG 图片") { controller.perform { try controller.exportImages(indices: indices(), jpeg: false) } }
                            Button("JPG 图片") { controller.perform { try controller.exportImages(indices: indices(), jpeg: true) } }
                        } label: { Label("转换为图片", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, alignment: .leading) }
                            .menuStyle(.button).buttonStyle(QuickPeekGlassButtonStyle(height: 44))
                        GlassToolButton(title: "转换为 Word", icon: "doc.text") { exportText("docx") }.help("导出 DOCX，按文字重新排版；扫描页在本机识别")
                        GlassToolButton(title: "转换为表格", icon: "tablecells") { exportText("csv") }.help("导出 CSV 文字行，不还原复杂表格布局")
                        GlassToolButton(title: "转换为 PPT", icon: "rectangle.on.rectangle") { controller.perform { try DocumentExport.powerPoint(controller: controller, indices: indices()) } }.help("导出 PPTX，每页保留为图片")
                        GlassToolButton(title: "提取文字", icon: "text.viewfinder") { exportText("txt") }.help("导出 TXT；扫描页在本机 OCR")
                        GlassToolButton(title: "提取图片", icon: "photo.badge.arrow.down") { controller.perform { try controller.extractEmbeddedImages(indices()) } }.help("提取 PDF 中内嵌的原始图片")
                    }
                    toolSection("保存") {
                        GlassToolButton(title: "保存副本", icon: "square.and.arrow.down", tone: .accent) { controller.perform { try controller.saveCopy() } }
                        GlassToolButton(title: "固化印章", icon: "checkmark.seal") { controller.perform { try controller.saveCopy(flatten: true) } }.help("将印章和批注固化到页面，保存为新文件")
                        GlassToolButton(title: "压缩 PDF", icon: "arrow.down.right.and.arrow.up.left") { controller.perform { try controller.saveCopy(compress: true) } }
                        GlassToolButton(title: "可搜索 PDF", icon: "doc.text.magnifyingglass") { controller.perform { try controller.saveCopy(searchable: true) } }
                        GlassToolButton(title: "加密副本", icon: "lock.doc") { showEncryption = true }
                            .popover(isPresented: $showEncryption) { encryptionEditor }
                    }
            footer
          }.padding(.horizontal, 30).padding(.top, embedded ? 96 : 28).padding(.bottom, 26)
        }.scrollIndicators(.hidden)
    }
    private var header: some View {
        HStack(spacing: 12) {
            if !embedded {
                Image(systemName: "doc.richtext").font(.system(size: 25, weight: .medium)).foregroundStyle(Color.accentColor)
                Text("文档工具").font(.system(size: 24, weight: .bold))
            } else {
                Text(controller.fileURL.lastPathComponent).font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            GlassIconButton(title: "工具说明与印章兼容", icon: "info.circle") { showInfo = true }
                .popover(isPresented: $showInfo) { compatibilityOptions }
            if !embedded { Button("完成", systemImage: "checkmark") { dismiss() }.buttonStyle(QuickPeekGlassButtonStyle()) }
        }
    }
    private var footer: some View {
        HStack(spacing: 9) {
            if controller.isBusy { ProgressView().controlSize(.small) }
            else { Image(systemName: controller.message.isEmpty ? "checkmark.shield" : "info.circle").foregroundStyle(.secondary) }
            Text(controller.message.isEmpty ? "原文件保留 · 编辑后保存副本" : controller.message)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 0)
        }.frame(minHeight: 22)
    }
    private func annotationEditor(watermark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(watermark ? "添加水印" : "添加批注", systemImage: watermark ? "drop.halffull" : "text.bubble").font(.headline)
            TextField("输入文字", text: $note).glassInput().accessibilityLabel("批注或水印文字")
            Button("添加到当前页", systemImage: "plus") {
                controller.perform { try controller.addNote(note, watermark: watermark) }
                if watermark { showWatermark = false } else { showNote = false }
            }.buttonStyle(QuickPeekGlassButtonStyle(tone: .accent)).disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(22).frame(width: 350)
    }
    private var encryptionEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("加密副本", systemImage: "lock.doc").font(.headline)
            SecureField("设置打开密码", text: $password).glassInput()
            Button("保存加密副本", systemImage: "square.and.arrow.down") {
                controller.perform { try controller.saveCopy(password: password); password = ""; showEncryption = false }
            }.buttonStyle(QuickPeekGlassButtonStyle(tone: .accent)).disabled(password.isEmpty)
        }.padding(22).frame(width: 350)
    }
    private var compatibilityOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("文档与印章", systemImage: "checkmark.seal").font(.headline)
            Text("编辑在预览中进行，保存副本后写入新文件。修改已签名文件可能使副本的数字签名失效。")
            Toggle("显示仅打印的印章", isOn: $controller.showPrintOnlyStamps)
                .onChange(of: controller.showPrintOnlyStamps) { _, value in if value { controller.usesCompatibilityRenderer = true } }
            Text("发现 \(controller.printOnlyAnnotationCount) 个仅打印批注。兼容渲染在本机离线运行。")
                .font(.caption).foregroundStyle(.secondary)
            Text("转换为 Word 会重新排版文字；表格导出 CSV；PPT 每页保留为图片。扫描页面先在本机识别。")
                .font(.caption).foregroundStyle(.secondary)
        }.font(.system(size: 13)).padding(22).frame(width: 370)
    }
    private func exportText(_ format: String) {
        controller.perform { let pages = try indices(); Task { await controller.exportText(format: format, indices: pages) } }
    }
    private func toolSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 5)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12)], alignment: .leading, spacing: 12, content: content)
        }
    }
}
