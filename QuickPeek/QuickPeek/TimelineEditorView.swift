import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickPeekTimeline
import TimelineKitCore
@preconcurrency import AVFoundation

@MainActor @Observable
final class TimelineEditorSession {
    let url: URL
    let player = AVPlayer()
    var edits = TimelineEdits(duration: 0, fps: 30, hasAudio: false)
    var ready = false
    var busy = false
    var batchProgress: String?
    var rebuilding = false
    var error: String?
    var errorTitle = "片段剪辑"
    var errorDetails = ""
    var position = 0.0
    var playing = false
    // Zoom measures powers of two around a one-minute visible window.
    var zoom = 0.0
    var visibleSeconds: Double { 60 / pow(2, zoom) }
    var zoomRange: ClosedRange<Double> { log2(60 / max(3600, edits.duration * 2))...log2(60) }
    var viewportReset = 0
    func fitTimeline() { zoom = log2(60 / max(1, edits.duration)); viewportReset += 1 }
    var peaks: [Float] = []
    var thumbnails: [NSImage] = []
    var ripple = true
    private var observer: Any?
    private var buildTask: Task<Void, Never>?
    private var generation = 0
    private var active = true
    init(url: URL) { self.url = url }
    func load() async {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let video = try await asset.loadTracks(withMediaType: .video)
            guard duration.isFinite, duration > 0, let track = video.first else { throw NSError(domain: "无法读取视频", code: 1) }
            let fps = try await track.load(.nominalFrameRate)
            guard active, !Task.isCancelled else { return }
            edits = TimelineEdits(duration: duration, fps: fps > 0 ? Double(fps) : 30, hasAudio: !audio.isEmpty)
            ready = true
            rebuild()
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if time.seconds.isFinite { self.position = time.seconds }
                    self.playing = self.player.rate > 0
                }
            }
            async let wave: [Float] = TimelineMedia.waveform(url: url, duration: duration)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 100)
            var images: [NSImage] = []
            for i in 0..<24 {
                try Task.checkCancellation()
                if let result = try? await generator.image(at: CMTime(seconds: duration*Double(i)/24, preferredTimescale: 600)) {
                    images.append(NSImage(cgImage: result.image, size: .zero))
                }
            }
            if active { thumbnails = images; peaks = (try? await wave) ?? [] }
        } catch is CancellationError {} catch { if active && !Task.isCancelled { report(error, operation:"读取视频失败") } }
    }
    func select(_ id: UUID, flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift), let anchor = edits.segments.first(where: { edits.state.selection.contains($0.id) }), let target = edits.segments.first(where: { $0.id == id }) {
            let low = min(anchor.targetRange.start,target.targetRange.start)
            let high = max(anchor.targetRange.start,target.targetRange.start)
            edits.selectMany(Set(edits.segments.filter { $0.targetRange.start >= low && $0.targetRange.start <= high }.map(\.id)), additive: true)
        } else { edits.select(id,additive:flags.contains(.command)) }
    }
    func change(_ action: (inout TimelineEdits) -> Void) {
        guard ready, !busy else { return }
        let before = edits.state
        action(&edits)
        if before.timeline != edits.state.timeline { rebuild() }
    }
    func split() { change { $0.split(at: position) } }
    func delete(rippleOverride: Bool? = nil) { change { $0.deleteSelection(ripple: rippleOverride ?? (ripple && !$0.hasDetachedSelection)) } }
    func rebuild() {
        player.pause(); playing = false
        generation += 1
        let ticket = generation, snapshot = edits.state, time = min(position,max(0,edits.duration-0.001))
        buildTask?.cancel(); rebuilding = true
        buildTask = Task {
            do {
                let composition = try await TimelineMedia.composition(url: url, state: snapshot)
                try Task.checkCancellation()
                guard active, ticket == generation else { return }
                let item = AVPlayerItem(asset: composition)
                item.videoComposition = try await TimelineMedia.videoComposition(for: composition)
                item.audioMix = try await TimelineMedia.audioMix(for: composition)
                try Task.checkCancellation()
                guard active, ticket == generation else { return }
                player.replaceCurrentItem(with: item)
                seek(time); rebuilding = false
            } catch is CancellationError {} catch {
                if ticket == generation && active && !Task.isCancelled { report(error, operation:"预览更新失败"); rebuilding = false }
            }
        }
    }
    func seek(_ time: Double) {
        position = max(0,min(edits.duration,time))
        player.seek(to: CMTime(seconds: position, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func togglePlayback() {
        guard !rebuilding else { return }
        if player.rate > 0 { player.pause() } else {
            if position >= edits.duration-0.05 { seek(0) }
            player.play()
        }
        playing = player.rate > 0
    }
    func cleanup() {
        active = false; buildTask?.cancel(); player.pause()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.replaceCurrentItem(with: nil)
    }
    func report(_ failure: Error, operation: String) {
        var details: [String] = [operation]
        var current: NSError? = failure as NSError
        for _ in 0..<6 {
            guard let value = current else { break }
            details.append("\(value.domain) (\(value.code)): \(value.localizedDescription)")
            if let reason = value.localizedFailureReason { details.append(reason) }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        errorTitle = operation
        errorDetails = details.joined(separator:"\n")
        let value = failure as NSError
        let reason = value.domain == AVFoundationErrorDomain && value.code == AVError.operationNotSupportedForAsset.rawValue
            ? "当前媒体或音视频轨道配置不支持这次导出。"
            : (value.localizedFailureReason ?? (value.localizedDescription == "Operation Stopped" ? "系统中止了这次操作。" : value.localizedDescription))
        error = "\(reason)\n\n\(value.domain) · \(value.code)\n原视频和当前剪辑仍保留，可重试。"
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/QuickPeek/editor-errors.log")
        try? FileManager.default.createDirectory(at:logURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        let previous = (try? String(contentsOf:logURL,encoding:.utf8)) ?? ""
        let entry = "\n[\(Date())] \(url.lastPathComponent)\n\(errorDetails)\n"
        try? (String(previous.suffix(100_000))+entry).write(to:logURL,atomically:true,encoding:.utf8)
    }
    func makeExportPanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "导出剪辑副本"
        panel.prompt = "导出"
        panel.message = "请选择保存文件夹和文件名。默认打开原视频所在位置，原视频不会被覆盖。"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "_剪辑.mp4"
        return panel
    }
    func export() {
        guard !busy, edits.duration > 0 else { return }
        player.pause()
        let panel = makeExportPanel()
        busy = true
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for:window) { response in
                if response == .OK, let destination = panel.url { self.writeExport(to:destination) }
                else { self.busy = false }
            }
        } else {
            panel.begin { response in
                if response == .OK, let destination = panel.url { self.writeExport(to:destination) }
                else { self.busy = false }
            }
        }
    }
    func exportSelectedLivePhotos() {
        guard ready, !busy else { return }
        let snapshot = edits.state
        let count = ClipExport.selectedVideoIDs(in:snapshot).count
        guard count > 0 else { return }
        player.pause(); playing = false; busy = true
        let panel = NSOpenPanel()
        panel.title = "批量导出 \(count) 段实况图"
        panel.prompt = "导出到此文件夹"
        panel.message = "每段独立导出，保留声音，不写入相册。建议每段 1.5–3 秒；鸿蒙格式仍需真机确认。"
        let choice = NSPopUpButton(frame:NSRect(x:0,y:0,width:320,height:28))
        choice.addItems(withTitles:["苹果 + 鸿蒙（测试版）","仅苹果实况图（.pvt）","仅鸿蒙动态照片（.jpg，测试版）"])
        panel.accessoryView = choice
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let parent = panel.url else { self.busy = false; return }
            let formats: [ClipExportFormat] = choice.indexOfSelectedItem == 1 ? [.livePhoto] : (choice.indexOfSelectedItem == 2 ? [.harmonyPhoto] : [.livePhoto,.harmonyPhoto])
            self.batchProgress = "正在导出 0 / \(count * formats.count)"
            Task {
                defer { self.busy = false; self.batchProgress = nil }
                do {
                    let folder = try await ClipExport.exportSelectedLivePhotos(url:self.url,state:snapshot,to:parent,formats:formats) { done,total in
                        await MainActor.run { self.batchProgress = "正在导出 \(done) / \(total)" }
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                } catch { self.report(error,operation:"批量导出实况图失败") }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for:window,completionHandler:completion) }
        else { panel.begin(completionHandler:completion) }
    }

    func exportClip(_ id: UUID, format: ClipExportFormat) {
        guard ready, !busy, let index = edits.state.timeline.tracks.filter({ $0.kind == .video }).flatMap(\.segments).firstIndex(where: { $0.id == id }) else { return }
        let snapshot = edits.state
        player.pause(); playing = false; busy = true
        let panel = NSSavePanel()
        panel.title = format.title.replacingOccurrences(of:"…",with:"")
        panel.prompt = "导出"
        panel.message = format == .harmonyPhoto ? "保存为鸿蒙动态照片 JPG（测试版），保留动态视频；图库识别需真机确认。" : format == .livePhoto ? "将当前片段保存为一个实况照片包（.pvt），默认存到下载，不写入相册。" : "仅导出右键点中的片段，请选择保存位置。"
        panel.directoryURL = format.isLivePhoto ? FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first : url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        let name = url.deletingPathExtension().lastPathComponent + "_片段\(index+1)"
        panel.allowedContentTypes = [UTType(filenameExtension:format.fileExtension) ?? .data]
        panel.nameFieldStringValue = name + "." + format.fileExtension
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { self.busy = false; return }
            Task {
                defer { self.busy = false }
                do {
                    try await ClipExport.export(url:self.url,state:snapshot,clipID:id,format:format,to:destination)
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch { self.report(error,operation:"片段导出失败") }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for:window,completionHandler:completion) }
        else { panel.begin(completionHandler:completion) }
    }
    private func writeExport(to destination: URL) {
        guard destination.resolvingSymlinksInPath().standardizedFileURL != url.resolvingSymlinksInPath().standardizedFileURL else {
            busy = false; errorTitle = "请选择其他文件名"; errorDetails = ""; error = "请另存为副本，不能覆盖原视频。"; return
        }
        let snapshot = edits.state
        // Keep the exact edit decisions locally so a failed export can be reproduced without the source being modified.
        let diagnosticDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/QuickPeek")
        try? FileManager.default.createDirectory(at:diagnosticDirectory,withIntermediateDirectories:true)
        if let project = try? JSONEncoder().encode(TimelineProject(sourceURL:url,edits:edits)) {
            try? project.write(to:diagnosticDirectory.appendingPathComponent("last-export-project.json"),options:.atomic)
        }
        Task {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: temporary); busy = false }
            var operation = "准备导出失败"
            do {
                let composition = try await TimelineMedia.composition(url: url, state: snapshot)
                guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw NSError(domain: "QuickPeek", code: 1, userInfo:[NSLocalizedDescriptionKey:"无法创建视频导出任务。"] ) }
                exporter.videoComposition = try await TimelineMedia.videoComposition(for: composition)
                exporter.audioMix = try await TimelineMedia.audioMix(for: composition)
                operation = "视频导出失败"
                try await exporter.export(to: temporary, as: .mp4)
                guard FileManager.default.fileExists(atPath: temporary.path) else { throw NSError(domain: "QuickPeek", code: 2, userInfo:[NSLocalizedDescriptionKey:"系统没有生成导出文件。"] ) }
                operation = "保存文件失败"
                if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
                else { try FileManager.default.moveItem(at: temporary, to: destination) }
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { report(error, operation:operation) }
        }
    }

}

struct TimelineEditorView: View {
    let fileURL: URL
    let onDone: () -> Void
    @State private var session: TimelineEditorSession
    @State private var help = false
    init(fileURL: URL, onDone: @escaping () -> Void) {
        self.fileURL = fileURL; self.onDone = onDone
        _session = State(initialValue: TimelineEditorSession(url: fileURL))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("完成") { onDone() }.disabled(session.busy)
                Text("片段剪辑").font(.headline)
                Text(fileURL.lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                Button { help.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .popover(isPresented: $help) {
                        Text("点击时间线定位，⌘B / Control-B 分割。\n⌘点击多选，Shift 点击连续选择，空白处拖动框选。\n单击定位播放头；长按片段浮起后拖动排序，松手接拢。\nOption-Shift 拖动自由移动，靠近边缘自动吸附。\n拖动两端裁剪并衔接；Option 拖动平移时间轴。\n音画默认关联；右键可解除关联，分别编辑。\nDelete 删除，⌘Z 撤销，⇧⌘Z 重做。\n解除关联的片段删除后保留空隙，避免其他轨道错位。\n\n时间线数据基础：TimelineKitCore · MIT\nCopyright © 2026 Ivan Yang\n完整许可见应用内 ThirdPartyNotices.txt")
                            .font(.system(size: 13)).padding(20).frame(width: 430)
                    }
                Button(session.batchProgress ?? (session.busy ? "导出中…" : "导出副本")) { session.export() }
                    .buttonStyle(.borderedProminent).disabled(!session.ready || session.busy || session.edits.duration == 0)
            }.padding(12)
            Divider()
            if session.ready {
                StableVideoPlayer(player: session.player, showsPlaybackControls: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { if session.rebuilding { ProgressView().controlSize(.small).allowsHitTesting(false) } }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Divider()
                controls
                NativeEditTimeline(session: session).frame(height: session.edits.state.timeline.tracks.count > 1 ? 200 : 126)
                    .disabled(session.busy)
                bottomBar
            } else { ProgressView("读取视频…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task { await session.load() }
        .onDisappear { session.cleanup() }
        .alert(session.errorTitle, isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("好") { session.error = nil }
            if !session.errorDetails.isEmpty {
                Button("复制错误详情") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.errorDetails,forType:.string); session.error = nil }
            }
        } message: { Text(session.error ?? "") }
    }
    private var controls: some View {
        HStack(spacing: 14) {
            Button { session.seek(session.position - 1/session.edits.fps) } label: { Image(systemName:"backward.end.fill") }.help("上一帧")
            Button { session.togglePlayback() } label: { Image(systemName: session.playing ? "pause.fill" : "play.fill").frame(width: 20) }.help("空格 播放 / 暂停")
            Button { session.seek(session.position + 1/session.edits.fps) } label: { Image(systemName:"forward.end.fill") }.help("下一帧")
            Text(String(format: "%02d:%05.2f / %02d:%05.2f", Int(session.position)/60, session.position.truncatingRemainder(dividingBy:60), Int(session.edits.duration)/60, session.edits.duration.truncatingRemainder(dividingBy:60))).monospacedDigit().font(.system(size:12))
            Spacer()
            Image(systemName:"minus.magnifyingglass")
            Slider(value: $session.zoom, in: session.zoomRange).frame(width:100).help("时间线缩放")
            Text(session.visibleSeconds < 60 ? String(format:"%.1f 秒",session.visibleSeconds) : String(format:"%.1f 分",session.visibleSeconds/60)).font(.system(size:11)).monospacedDigit().frame(width:48)
            Button("适合") { session.fitTimeline() }
        }.buttonStyle(.borderless).padding(.horizontal,16).padding(.vertical,10).disabled(session.busy)
    }
    private var bottomBar: some View {
        HStack(spacing:12) {
            Button { session.change { $0.undo() } } label: { Label("撤销",systemImage:"arrow.uturn.backward") }.disabled(!session.edits.canUndo)
            Button { session.change { $0.redo() } } label: { Image(systemName:"arrow.uturn.forward") }.disabled(!session.edits.canRedo).help("重做 ⇧⌘Z")
            Button { session.split() } label: { Label("分割",systemImage:"scissors") }.help("⌘B / Control-B")
            Toggle("删除后衔接",isOn:$session.ripple).toggleStyle(.checkbox).help("关联片段删除后自动衔接；已解除关联时保留空隙")
            Spacer(minLength:4)
            Text(session.edits.state.selection.isEmpty ? "⌘点击多选 · 右键解除音画关联" : "已选 \(session.edits.state.selection.count) 个轨道片段")
                .font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
            Button(role:.destructive) { session.delete() } label: { Label("删除",systemImage:"trash") }.disabled(session.edits.state.selection.isEmpty)
        }.padding(12).disabled(session.busy)
    }
}

private struct NativeEditTimeline: NSViewRepresentable {
    let session: TimelineEditorSession
    func makeNSView(context: Context) -> TimelineScrollView {
        let scroll = TimelineScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        let canvas = EditTimelineCanvas()
        canvas.session = session; scroll.documentView = canvas
        return scroll
    }
    func updateNSView(_ view: TimelineScrollView, context: Context) {
        // Read observable state here so SwiftUI invalidates the native canvas on edits and playback.
        _ = session.edits.state; _ = session.position; _ = session.zoom; _ = session.peaks; _ = session.thumbnails
        view.canvas?.session = session; view.resizeCanvas()
        if view.lastReset != session.viewportReset {
            view.lastReset = session.viewportReset
            view.contentView.scroll(to:.zero); view.reflectScrolledClipView(view.contentView)
        }
    }
    static func dismantleNSView(_ view: TimelineScrollView, coordinator: ()) { view.canvas?.stopMonitoring() }
}

private final class TimelineScrollView: NSScrollView {
    var lastReset = -1
    var canvas: EditTimelineCanvas? { documentView as? EditTimelineCanvas }
    override func layout() { super.layout(); resizeCanvas() }
    override func scrollWheel(with event: NSEvent) {
        guard let canvas else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let x = min(max(0,contentView.bounds.origin.x-delta),max(0,canvas.frame.width-contentSize.width))
        contentView.scroll(to: NSPoint(x:x,y:0)); reflectScrolledClipView(contentView)
    }
    func resizeCanvas() {
        guard let canvas, let session = canvas.session else { return }
        if !canvas.isDragging { canvas.scale = max(100,contentSize.width-32)/session.visibleSeconds }
        canvas.frame.size = CGSize(width: max(canvas.isDragging ? canvas.frame.width : 0, contentSize.width, max(60,session.edits.duration + max(60,session.visibleSeconds))*canvas.scale+32), height: max(contentSize.height,session.edits.state.timeline.tracks.count > 1 ? 180 : 108))
        canvas.needsDisplay = true
    }
}

private final class EditTimelineCanvas: NSView {
    var session: TimelineEditorSession?
    var scale: Double = 50
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var isDragging: Bool { dragBase != nil }
    private var dragBase: TimelineEdits?
    private var dragPreview: TimelineEdits?
    private var snapGuide: Double?
    private var dragScrollTimer: Timer?
    private var lastDragEvent: NSEvent?
    private var panning = false
    private var holdTimer: Timer?
    private var isClipLifted = false
    private var isScrubbing = false
    private var cancelledPointerSequence = false
    private var motionTimer: Timer?
    private var motionTime = ProcessInfo.processInfo.systemUptime
    private var displayRects: [UUID: NSRect] = [:]
    private var targetRects: [UUID: NSRect] = [:]
    private var focusObserver: NSObjectProtocol?
    private var down = NSPoint.zero
    private var dragPoint = NSPoint.zero
    private var hitID: UUID?
    private var edge: TrimEdge?
    private var box: NSRect?
    private var anchorRange: TimeRange?
    private var originalSelection: Set<UUID> = []
    private var flags: NSEvent.ModifierFlags = []
    private var monitor: Any?
    private weak var oldWindow: NSWindow?
    private var movable = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }
        TapSharedState.shared.timelineEditing = true
        oldWindow = window; movable = window.isMovableByWindowBackground; window.isMovableByWindowBackground = false
        focusObserver = NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:window,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelInteraction() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                  window.attachedSheet == nil, !(window.firstResponder is NSTextView), self.session?.busy == false else { return event }
            return self.handle(event) ? nil : event
        }
    }
    func stopMonitoring() {
        cancelInteraction()
        motionTimer?.invalidate(); motionTimer = nil
        displayRects.removeAll(); targetRects.removeAll()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        dragScrollTimer?.invalidate(); dragScrollTimer = nil; lastDragEvent = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let oldWindow { oldWindow.isMovableByWindowBackground = movable }
        oldWindow = nil
        TapSharedState.shared.timelineEditing = false
    }
    func handle(_ event: NSEvent) -> Bool {
        guard let session else { return false }
        if hitID != nil {
            if event.keyCode == 53 { cancelInteraction() }
            return true
        }
        let cmd = event.modifierFlags.contains(.command), ctrl = event.modifierFlags.contains(.control)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b" where cmd || ctrl: session.split()
        case "z" where cmd: session.change { if event.modifierFlags.contains(.shift) { $0.redo() } else { $0.undo() } }
        case "a" where cmd: session.edits.selectAll()
        case " " where !cmd && !ctrl: session.togglePlayback()
        default:
            if event.keyCode == 51 || event.keyCode == 117 { session.delete() }
            else if event.keyCode == 123 { session.seek(session.position-1/session.edits.fps) }
            else if event.keyCode == 124 { session.seek(session.position+1/session.edits.fps) }
            else { return false }
        }
        needsDisplay = true
        return true
    }
    private func cancelInteraction() {
        cancelledPointerSequence = true
        holdTimer?.invalidate(); holdTimer = nil
        dragScrollTimer?.invalidate(); dragScrollTimer = nil; lastDragEvent = nil
        dragBase = nil; dragPreview = nil; hitID = nil; edge = nil
        isClipLifted = false; isScrubbing = false; panning = false; box = nil; snapGuide = nil
        NSCursor.arrow.set()
        refreshMotionTargets()
    }
    private func beginLift() {
        holdTimer?.invalidate(); holdTimer = nil
        guard hitID != nil, edge == nil, !isScrubbing, session?.busy == false, window != nil else { return }
        isClipLifted = true
        NSCursor.closedHand.set()
        refreshMotionTargets()
    }
    private func refreshMotionTargets() {
        guard let session else { return }
        let drawing = dragPreview ?? session.edits
        var next: [UUID:NSRect] = [:]
        for (t,track) in drawing.state.timeline.tracks.enumerated() {
            for clip in track.segments {
                var target = rect(clip,track:t)
                if displayRects[clip.id] == nil {
                    let original = dragBase?.state.timeline.tracks[t].segments.first { $0.id == clip.id }
                    displayRects[clip.id] = original.map { rect($0,track:t) } ?? target
                }
                if isClipLifted, let base = dragBase, base.state.selection.contains(clip.id),
                   let original = base.state.timeline.tracks[t].segments.first(where: { $0.id == clip.id }) {
                    target = rect(original,track:t).offsetBy(dx:dragPoint.x-down.x,dy:-5)
                    target = target.insetBy(dx:-min(6,target.width*0.025),dy:-3)
                }
                next[clip.id] = target
            }
        }
        targetRects = next
        displayRects = displayRects.filter { next[$0.key] != nil }
        if motionTimer == nil {
            motionTime = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in
                MainActor.assumeIsolated { self?.stepMotion() }
            }
            motionTimer = timer
            RunLoop.main.add(timer,forMode:.common)
        }
        needsDisplay = true
    }
    private func stepMotion() {
        let now = ProcessInfo.processInfo.systemUptime
        let amount = 1-exp(-min(0.1,now-motionTime)/0.055)
        motionTime = now
        var moving = false
        for (id,target) in targetRects {
            let current = displayRects[id] ?? target
            let distance = abs(target.minX-current.minX)+abs(target.minY-current.minY)+abs(target.width-current.width)+abs(target.height-current.height)
            if distance < 0.3 { displayRects[id] = target; continue }
            moving = true
            displayRects[id] = NSRect(x:current.minX+(target.minX-current.minX)*amount,
                y:current.minY+(target.minY-current.minY)*amount,
                width:current.width+(target.width-current.width)*amount,
                height:current.height+(target.height-current.height)*amount)
        }
        needsDisplay = true
        if !moving { motionTimer?.invalidate(); motionTimer = nil }
    }

    private func rect(_ clip: EditorSegment, track: Int) -> NSRect {
        NSRect(x:16+clip.targetRange.start*scale,y:34+Double(track)*72,width:max(2,clip.targetRange.duration*scale),height:62)
    }
    private func time(_ p: NSPoint) -> Double { max(0,(p.x-16)/scale) }
    private func hit(_ p: NSPoint) -> (EditorSegment,Int)? {
        guard let session else { return nil }
        for (t,track) in session.edits.state.timeline.tracks.enumerated() {
            if let clip = track.segments.first(where: { rect($0,track:t).contains(p) }) { return (clip,t) }
        }
        return nil
    }
    private func text(_ value: String, at point: NSPoint, color: NSColor = .secondaryLabelColor, size: Double = 11) {
        (value as NSString).draw(at:point,withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:size,weight:.medium),.foregroundColor:color])
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let session else { return }
        NSColor.black.withAlphaComponent(0.12).setFill(); bounds.fill()
        let drawing = dragPreview ?? session.edits
        let tickOptions = [1.0/30,0.1,0.25,0.5,1,2,5,10,15,30,60,120,300,600,1800,3600]
        let step = tickOptions.first(where: { $0*scale >= 65 }) ?? 3600
        let visible = visibleRect
        var tick = floor(max(0,time(visible.origin))/step)*step
        while tick <= time(NSPoint(x:visible.maxX,y:0)) {
            let x = 16+tick*scale
            text(step < 1 ? String(format:"%02d:%04.1f",Int(tick)/60,tick.truncatingRemainder(dividingBy:60)) : String(format:"%02d:%02d",Int(tick)/60,Int(tick)%60),at:NSPoint(x:x+3,y:8))
            NSColor.separatorColor.setStroke(); let line = NSBezierPath(); line.move(to:NSPoint(x:x,y:27)); line.line(to:NSPoint(x:x,y:bounds.height)); line.stroke()
            tick += step
        }
        // Draw floating clips last, above the smoothly displaced neighboring clips.
        for floatingPass in [false,true] {
        for (t,track) in drawing.state.timeline.tracks.enumerated() {
            for (index,clip) in track.segments.enumerated() {
                let floating = isClipLifted && (dragBase?.state.selection.contains(clip.id) ?? false)
                guard floating == floatingPass else { continue }
                let r = (motionTimer != nil || isClipLifted) ? (displayRects[clip.id] ?? rect(clip,track:t)) : rect(clip,track:t)
                guard r.intersects(visible) else { continue }
                let selected = drawing.state.selection.contains(clip.id)
                if floating {
                    let slot = NSBezierPath(roundedRect:rect(clip,track:t).insetBy(dx:2,dy:2),xRadius:5,yRadius:5)
                    NSColor.controlAccentColor.withAlphaComponent(0.10).setFill();slot.fill()
                    NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke();slot.stroke()
                    NSGraphicsContext.saveGraphicsState()
                    let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.45)
                    shadow.shadowBlurRadius=12;shadow.shadowOffset=NSSize(width:0,height:-3);shadow.set()
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(roundedRect:r,xRadius:7,yRadius:7).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                let color: NSColor = t == 0 ? .systemBlue : .systemTeal
                NSGraphicsContext.saveGraphicsState()
                let path = NSBezierPath(roundedRect:r.insetBy(dx:1,dy:1),xRadius:5,yRadius:5)
                path.addClip()
                color.withAlphaComponent(selected ? 0.5 : 0.22).setFill(); r.fill()
                if t == 0, !session.thumbnails.isEmpty, let source = clip.sourceRange {
                    var x = max(r.minX, floor(visible.minX/74)*74)
                    while x < min(r.maxX,visible.maxX) {
                        let s = source.start + (x-r.minX)/scale
                        let i = min(session.thumbnails.count-1,max(0,Int(s/max(session.edits.sourceDuration,0.001)*Double(session.thumbnails.count))))
                        session.thumbnails[i].draw(in:NSRect(x:x,y:r.minY+20,width:74,height:42),from:.zero,operation:.sourceOver,fraction:0.8,respectFlipped:true,hints:nil)
                        x += 74
                    }
                } else if t > 0, !session.peaks.isEmpty, let source = clip.sourceRange {
                    color.setStroke(); let wave = NSBezierPath(); wave.lineWidth = 1.5
                    var x = max(r.minX+3,visible.minX)
                    while x < min(r.maxX-3,visible.maxX) {
                        let seconds = source.start+(x-r.minX)/scale
                        let i = min(session.peaks.count-1,max(0,Int(seconds/max(session.edits.sourceDuration,0.001)*Double(session.peaks.count))))
                        let h = max(1,Double(session.peaks[i])*17)
                        wave.move(to:NSPoint(x:x,y:r.minY+40-h)); wave.line(to:NSPoint(x:x,y:r.minY+40+h)); x += 3
                    }
                    wave.stroke()
                }
                let linked = drawing.state.links[clip.id] != nil ? " ⛓" : ""
                let labelIndex = dragBase?.state.timeline.tracks[t].segments.firstIndex(where: { $0.id == clip.id }) ?? index
                text("\(t == 0 ? "视频" : "音频") \(labelIndex+1)\(linked)",at:NSPoint(x:r.minX+8,y:r.minY+3),color:.labelColor)
                NSGraphicsContext.restoreGraphicsState()
                (selected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.15)).setStroke()
                path.lineWidth = selected ? 2 : 1; path.stroke()
                if selected {
                    NSColor.white.withAlphaComponent(0.8).setFill()
                    NSRect(x:r.minX+3,y:r.midY-8,width:2,height:16).fill()
                    NSRect(x:r.maxX-5,y:r.midY-8,width:2,height:16).fill()
                }
            }
        }
        }
        if let box {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill(); box.fill()
            NSColor.controlAccentColor.setStroke(); NSBezierPath(rect:box).stroke()
        }
        if let snapGuide {
            NSColor.systemYellow.setStroke()
            let guide=NSBezierPath();guide.lineWidth=1.5
            guide.move(to:NSPoint(x:16+snapGuide*scale,y:26));guide.line(to:NSPoint(x:16+snapGuide*scale,y:bounds.height));guide.stroke()
        }
        let x = 16+session.position*scale
        NSColor.white.setStroke(); let head = NSBezierPath(); head.lineWidth = 2
        head.move(to:NSPoint(x:x,y:25)); head.line(to:NSPoint(x:x,y:bounds.height)); head.stroke()
        NSColor.white.setFill(); NSBezierPath(roundedRect:NSRect(x:x-4,y:21,width:8,height:9),xRadius:2,yRadius:2).fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard let session, !session.busy else { return }
        cancelInteraction()
        cancelledPointerSequence = false
        motionTimer?.invalidate(); motionTimer = nil; displayRects.removeAll(); targetRects.removeAll()
        window?.makeFirstResponder(self)
        down = convert(event.locationInWindow,from:nil); dragPoint = down; flags = event.modifierFlags
        originalSelection = session.edits.state.selection
        hitID = nil; edge = nil; box = nil; anchorRange = nil
        dragBase = nil; dragPreview = nil; snapGuide = nil
        panning = flags.contains(.option) && !flags.contains(.shift)
        if panning { return }
        session.player.pause()
        if let (clip,t) = hit(down) {
            hitID = clip.id; anchorRange = clip.targetRange
            let r = rect(clip,track:t)
            if r.width > 24 && down.x < r.minX+7 { edge = .start }
            else if r.width > 24 && down.x > r.maxX-7 { edge = .end }
            if edge != nil { session.edits.select(clip.id) }
            else if flags.contains([.option, .shift]) {
                if !session.edits.state.selection.contains(clip.id) { session.edits.select(clip.id) }
            }
            else if !session.edits.state.selection.contains(clip.id) || flags.contains(.command) || (flags.contains(.shift) && !flags.contains(.option)) { session.select(clip.id,flags:flags) }
        } else {
            session.seek(time(down))
            if down.y > 30 && !flags.contains(.command) { session.edits.selectMany([]) }
        }
        if hitID != nil {
            dragBase = session.edits
            if edge != nil || flags.contains([.option,.shift]) { session.seek(time(down)) }
            else {
                let timer = Timer(timeInterval:0.28,repeats:false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.beginLift() }
                }
                holdTimer = timer; RunLoop.main.add(timer,forMode:.common)
            }
        }
        needsDisplay = true
    }
    private func updateDrag(at point: NSPoint) {
        guard let base = dragBase, let range = anchorRange, let session else { return }
        guard edge != nil || isClipLifted || flags.contains([.option,.shift]) else { return }
        dragPoint = point
        guard abs(point.x-down.x) > 3 else { dragPreview = base; snapGuide = nil; refreshMotionTargets(); return }
        var preview = base
        let proposed = (point.x-down.x)/scale
        snapGuide = nil
        if let edge {
            var target = (edge == .start ? range.start : range.end) + proposed
            let boundaries: [Double] = base.segments.filter { !base.state.selection.contains($0.id) }.flatMap { [$0.targetRange.start,$0.targetRange.end] } + [0]
            if let nearest = boundaries.min(by: { abs($0-target) < abs($1-target) }), abs(nearest-target)*scale <= 10 {
                target = nearest; snapGuide = nearest
            }
            preview.trimSelected(edge:edge,to:target,ripple:session.ripple && !base.hasDetachedSelection)
        } else if !flags.contains([.option, .shift]), let hitID {
            snapGuide = preview.reorderSelection(draggedID:hitID,to:time(point))
        } else {
            let delta = base.magneticMoveDelta(by:proposed,tolerance:10/scale)
            preview.moveSelection(by:delta,snapToFrame:false)
            let edges: [Double] = base.segments.filter { !base.state.selection.contains($0.id) }.flatMap { [$0.targetRange.start,$0.targetRange.end] } + [0]
            let movedEdges = preview.segments.filter { base.state.selection.contains($0.id) }.flatMap { [$0.targetRange.start,$0.targetRange.end] }
            snapGuide = edges.first { fixed in movedEdges.contains { abs($0-fixed)<0.00001 } }
        }
        dragPreview = preview; refreshMotionTargets()
    }
    private func continueEdgeScroll() {
        guard let event = lastDragEvent, let scroll = enclosingScrollView else { return }
        let point = convert(event.locationInWindow,from:nil)
        let visible=visibleRect
        let velocity: Double = point.x > visible.maxX-32 ? 12 : (point.x < visible.minX+32 ? -12 : 0)
        guard velocity != 0 else { return }
        if velocity > 0, visible.maxX+40 > frame.width { frame.size.width += max(200,scale*10) }
        let x=max(0,min(frame.width-visible.width,visible.minX+velocity))
        scroll.contentView.scroll(to:NSPoint(x:x,y:0));scroll.reflectScrolledClipView(scroll.contentView)
        updateDrag(at:convert(event.locationInWindow,from:nil))
    }
    override func mouseDragged(with event: NSEvent) {
        guard !cancelledPointerSequence else { return }
        guard let session, !session.busy else { return }
        dragPoint = convert(event.locationInWindow,from:nil)
        if panning, let scroll = enclosingScrollView {
            let windowDelta = event.locationInWindow.x - convert(down,to:nil).x
            let x=max(0,min(frame.width-scroll.contentSize.width,scroll.contentView.bounds.origin.x-windowDelta))
            scroll.contentView.scroll(to:NSPoint(x:x,y:0));scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        if hitID != nil {
            if edge == nil && !isClipLifted && !flags.contains([.option,.shift]) {
                if isScrubbing || hypot(dragPoint.x-down.x,dragPoint.y-down.y) > 6 {
                    holdTimer?.invalidate();holdTimer = nil;isScrubbing = true
                    session.seek(time(dragPoint)); needsDisplay = true
                }
                return
            }
            updateDrag(at:dragPoint)
            lastDragEvent = event
            if dragScrollTimer == nil {
                dragScrollTimer = Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.continueEdgeScroll() }
                }
                if let dragScrollTimer { RunLoop.main.add(dragScrollTimer,forMode:.eventTracking) }
            }
        } else {
            if down.y < 30 { session.seek(time(dragPoint)) }
            else {
                let r = NSRect(x:min(down.x,dragPoint.x),y:min(down.y,dragPoint.y),width:abs(down.x-dragPoint.x),height:abs(down.y-dragPoint.y))
                box = r
                var ids: Set<UUID> = flags.contains(.command) ? originalSelection : []
                for (t,track) in session.edits.state.timeline.tracks.enumerated() {
                    for clip in track.segments where rect(clip,track:t).intersects(r) { ids.insert(clip.id) }
                }
                session.edits.selectMany(ids)
            }
        }
        autoscroll(with:event); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !cancelledPointerSequence else { return }
        guard let session, !session.busy else { cancelInteraction(); return }
        holdTimer?.invalidate(); holdTimer = nil
        dragScrollTimer?.invalidate();dragScrollTimer=nil;lastDragEvent=nil
        let p = convert(event.locationInWindow,from:nil)
        if !panning {
            if hitID != nil && edge == nil && !isClipLifted && !flags.contains([.option,.shift]) { session.seek(time(p)) }
            else { updateDrag(at:p) }
        }
        if let result = dragPreview { session.change { $0 = result } }
        hitID = nil; box = nil; dragBase = nil; dragPreview = nil; snapGuide = nil; panning = false
        isClipLifted = false; isScrubbing = false
        NSCursor.arrow.set()
        refreshMotionTargets()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let session, !session.busy else { return nil }
        let p = convert(event.locationInWindow,from:nil)
        if let (clip,_) = hit(p), !session.edits.state.selection.contains(clip.id) { session.edits.select(clip.id) }
        let menu = NSMenu()
        for (title,selector) in [("在播放头处分割  ⌘B",#selector(split)),("解除音画关联",#selector(unlink)),("删除所选片段",#selector(deleteClips)),("删除并闭合全部轨道空隙",#selector(rippleDelete)),("撤销",#selector(undoEdit))] {
            let item = NSMenuItem(title:title,action:selector,keyEquivalent:""); item.target = self; menu.addItem(item)
        }
        if let (clip,trackIndex) = hit(p), session.edits.state.timeline.tracks[trackIndex].kind == .video {
            menu.addItem(.separator())
            let exportMenu = NSMenu()
            for format in ClipExportFormat.allCases {
                let item = NSMenuItem(title:format.title,action:#selector(exportClipItem(_:)),keyEquivalent:"")
                item.target = self
                item.representedObject = ["id":clip.id.uuidString,"format":format.rawValue]
                exportMenu.addItem(item)
            }
            let item = NSMenuItem(title:"导出当前片段",action:nil,keyEquivalent:"")
            item.submenu = exportMenu; menu.addItem(item)
        }
        let selectedCount = ClipExport.selectedVideoIDs(in:session.edits.state).count
        if selectedCount > 1 {
            menu.addItem(.separator())
            let item = NSMenuItem(title:"导出所选 \(selectedCount) 段为实况图…",action:#selector(exportSelectedLivePhotos),keyEquivalent:"")
            item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func exportSelectedLivePhotos() { session?.exportSelectedLivePhotos() }
    @objc private func exportClipItem(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String:String], let rawID = values["id"], let id = UUID(uuidString:rawID), let rawFormat = values["format"], let format = ClipExportFormat(rawValue:rawFormat) else { return }
        session?.exportClip(id,format:format)
    }
    @objc private func split() { session?.split() }
    @objc private func unlink() { session?.change { $0.unlinkSelection() } }
    @objc private func deleteClips() { session?.delete() }
    @objc private func rippleDelete() { session?.delete(rippleOverride: true) }
    @objc private func undoEdit() { session?.change { $0.undo() } }
}
