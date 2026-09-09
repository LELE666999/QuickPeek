import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import AVFoundation
@preconcurrency import AVKit

enum VideoSelectionEdit: String, CaseIterable, Identifiable {
    case keep = "保留选区"
    case remove = "删除选区"
    var id: String { rawValue }

    func ranges(duration: Double, start: Double, end: Double) -> [ClosedRange<Double>] {
        guard duration.isFinite, start.isFinite, end.isFinite, duration > 0,
              start >= 0, end <= duration, end > start else { return [] }
        if self == .keep { return [start...end] }
        var result: [ClosedRange<Double>] = []
        if start > 0 { result.append(0...start) }
        if end < duration { result.append(end...duration) }
        return result
    }
}

struct VideoTrimView: View {
    let fileURL: URL
    let onDone: () -> Void

    @State private var editMode: VideoSelectionEdit = .keep
    @State private var exportedURL: URL?
    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var startTime: Double = 0
    @State private var endTime: Double = 0
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var thumbnails: [NSImage] = []
    @State private var isSaving = false
    @State private var timeObserver: Any?
    @State private var wasPlayingBeforeDrag = false
    @State private var isInteractingWithTimeline = false
    @State private var previousMovableByBackground: Bool?
    @State private var saveErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button("完成") { cleanup(); onDone() }
                    .disabled(isSaving)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("片段剪辑").font(.system(size: 13, weight: .medium))
                Spacer()
                if isSaving {
                    ProgressView().controlSize(.small)
                    Text("保存中…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button("导出副本") { saveTrimed() }
                        .disabled(outputRanges.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            HStack(spacing: 14) {
                Picker("操作", selection: $editMode) {
                    ForEach(VideoSelectionEdit.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                Text(editMode == .keep ? "仅导出选中片段，原视频不变" : "移除选中片段，前后内容自动接起来")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .disabled(isSaving)

            // Video player
            if let player = player {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                    StableVideoPlayer(player: player, showsPlaybackControls: false)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Timeline
            VStack(spacing: 8) {
                // Thumbnail strip + trim handles
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Thumbnail strip
                        HStack(spacing: 0) {
                            ForEach(0..<thumbnails.count, id: \.self) { i in
                                Image(nsImage: thumbnails[i])
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: geo.size.width / max(CGFloat(thumbnails.count), 1), height: 48)
                                    .clipped()
                            }
                        }
                        .frame(width: geo.size.width, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    beginTimelineInteraction()
                                    let frac = (v.location.x / geo.size.width).clamped(to: 0...1)
                                    seekTo(Double(frac) * duration)
                                }
                                .onEnded { _ in
                                    endTimelineInteraction()
                                }
                        )

                        // Dimmed regions
                        let leftW = startFraction * geo.size.width
                        let rightW = (1 - endFraction) * geo.size.width
                        Rectangle().fill(editMode == .keep ? Color.black.opacity(0.6) : Color.clear)
                            .frame(width: max(leftW, 0), height: 48)
                            .allowsHitTesting(false)
                        Rectangle().fill(editMode == .keep ? Color.black.opacity(0.6) : Color.clear)
                            .frame(width: max(rightW, 0), height: 48)
                            .offset(x: endFraction * geo.size.width)
                            .allowsHitTesting(false)

                        Rectangle().fill(editMode == .remove ? Color.red.opacity(0.35) : Color.clear)
                            .frame(width: max(0, (endFraction - startFraction) * geo.size.width), height: 48)
                            .offset(x: startFraction * geo.size.width)
                            .allowsHitTesting(false)

                        // Trim frame
                        let trimX = leftW
                        let trimW = (endFraction - startFraction) * geo.size.width
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(editMode == .keep ? Color.yellow : Color.red, lineWidth: 2)
                            .frame(width: max(trimW, 0), height: 48)
                            .offset(x: trimX)
                            .allowsHitTesting(false)

                        // Left handle
                        trimHandle(color: editMode == .keep ? .yellow : .red)
                            .position(x: leftW, y: 24)
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { v in
                                        beginTimelineInteraction()
                                        let frac = (v.location.x / geo.size.width).clamped(to: 0...(endFraction - 0.01))
                                        startTime = Double(frac) * duration
                                        seekTo(startTime)
                                    }
                                    .onEnded { _ in
                                        endTimelineInteraction()
                                    }
                            )

                        // Right handle
                        trimHandle(color: editMode == .keep ? .yellow : .red)
                            .position(x: endFraction * geo.size.width, y: 24)
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { v in
                                        beginTimelineInteraction()
                                        let frac = (v.location.x / geo.size.width).clamped(to: (startFraction + 0.01)...1.0)
                                        endTime = Double(frac) * duration
                                        seekTo(endTime)
                                    }
                                    .onEnded { _ in
                                        endTimelineInteraction()
                                    }
                            )

                        // Playhead
                        let playX = duration > 0 ? (currentTime / duration) * Double(geo.size.width) : 0
                        Rectangle().fill(Color.white).frame(width: 2, height: 56)
                            .position(x: CGFloat(playX), y: 24)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 48)

                // Time labels
                HStack {
                    Text(formatTime(startTime)).font(.system(size: 11, design: .monospaced))
                    Spacer()
                    Text("选区: \(formatTime(endTime - startTime)) · 导出: \(formatTime(outputDuration))").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(formatTime(endTime)).font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(.secondary)

                HStack {
                    Button("当前位置设为起点") {
                        startTime = min(max(0, currentTime), max(0, endTime - 0.01))
                    }
                    Button("当前位置设为终点") {
                        endTime = max(min(duration, currentTime), min(duration, startTime + 0.01))
                    }
                    Button("重置选区") { startTime = 0; endTime = duration }
                    Spacer()
                    if outputRanges.isEmpty {
                        Text("删除全部内容无法导出，请缩小选区")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                .disabled(isSaving || duration <= 0)

                if let exportedURL {
                    HStack {
                        Text("已导出：\(exportedURL.lastPathComponent)").lineLimit(1)
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
                    }
                    .font(.caption)
                }

                // Play controls
                HStack(spacing: 16) {
                    Button { seekTo(startTime) } label: {
                        Image(systemName: "backward.end.fill").font(.system(size: 14))
                    }.buttonStyle(.plain)
                    Button { togglePlay() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16))
                    }.buttonStyle(.plain)
                    Button { seekTo(endTime) } label: {
                        Image(systemName: "forward.end.fill").font(.system(size: 14))
                    }.buttonStyle(.plain)
                }
            }
            .padding(16)
            .disabled(isSaving)
        }
        .frame(minWidth: 640, minHeight: 480)
        .onChange(of: editMode) { _, _ in
            player?.pause()
            isPlaying = false
        }
        .onAppear {
            setWindowBackgroundDragging(enabled: false)
            setupPlayer()
        }
        .onDisappear {
            setWindowBackgroundDragging(enabled: previousMovableByBackground ?? true)
            cleanup()
        }
        .alert("保存失败", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "视频裁切保存失败")
        }
    }

    private var startFraction: CGFloat { duration > 0 ? CGFloat(startTime / duration) : 0 }
    private var endFraction: CGFloat { duration > 0 ? CGFloat(endTime / duration) : 1 }

    private func trimHandle(color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.clear)
                .frame(width: 26, height: 60)
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 8, height: 48)
        }
        .contentShape(Rectangle())
    }

    private func setupPlayer() {
        let asset = AVURLAsset(url: fileURL)
        Task { @MainActor in
            do {
                let dur = try await asset.load(.duration)
                let d = CMTimeGetSeconds(dur)
                guard d.isFinite, d > 0 else { return }
                duration = d
                endTime = d
                let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player = p
                let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
                timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
                    let t = CMTimeGetSeconds(time)
                    if t.isFinite { currentTime = t }
                    if isPlaying, !isInteractingWithTimeline {
                        if editMode == .remove, t >= startTime, t < endTime {
                            seekTo(endTime)
                        }
                        let stop = editMode == .keep ? endTime : duration
                        if t >= stop {
                            p.pause()
                            isPlaying = false
                        }
                    }
                }
                generateThumbnails(asset: asset, count: 12)
            } catch {
                // Duration unavailable — cannot trim
            }
        }
    }

    private func generateThumbnails(asset: AVURLAsset, count: Int) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 68)
        var images: [NSImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: duration * Double(i) / Double(count), preferredTimescale: 600)
            if let cgImg = try? generator.copyCGImage(at: t, actualTime: nil) {
                images.append(NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height)))
            }
        }
        thumbnails = images
    }

    private func seekTo(_ time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    private func beginTimelineInteraction() {
        guard !isInteractingWithTimeline else { return }
        isInteractingWithTimeline = true
        wasPlayingBeforeDrag = isPlaying
        if isPlaying {
            player?.pause()
            isPlaying = false
        }
    }

    private func endTimelineInteraction() {
        guard isInteractingWithTimeline else { return }
        isInteractingWithTimeline = false
        if wasPlayingBeforeDrag {
            player?.play()
            isPlaying = true
        }
        wasPlayingBeforeDrag = false
    }

    private func togglePlay() {
        guard let p = player else { return }
        if isPlaying { p.pause() } else {
            guard !outputRanges.isEmpty else { return }
            if editMode == .keep {
                if currentTime < startTime || currentTime >= endTime { seekTo(startTime) }
            } else {
                if currentTime >= duration { seekTo(startTime == 0 ? endTime : 0) }
                else if currentTime >= startTime && currentTime < endTime { seekTo(endTime) }
            }
            p.play()
        }
        isPlaying.toggle()
    }

    private func cleanup() {
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        player?.pause()
        player = nil
    }

    private func setWindowBackgroundDragging(enabled: Bool) {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            if previousMovableByBackground == nil {
                previousMovableByBackground = window.isMovableByWindowBackground
            }
            window.isMovableByWindowBackground = enabled
        }
    }

    private func formatTime(_ t: Double) -> String {
        let total = max(0, Int(t))
        let m = total / 60; let s = total % 60
        let ms = Int((t - Double(total)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, ms)
    }

    private var outputRanges: [ClosedRange<Double>] {
        editMode.ranges(duration: duration, start: startTime, end: endTime)
    }

    private var outputDuration: Double {
        outputRanges.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    }

    private func saveTrimed() {
        let ranges = outputRanges
        guard !isSaving, !ranges.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent
            + (editMode == .keep ? "-片段.mp4" : "-删除选区.mp4")
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        guard outputURL.standardizedFileURL.resolvingSymlinksInPath() != fileURL.standardizedFileURL.resolvingSymlinksInPath() else {
            saveErrorMessage = "请选择另一个文件名，导出副本不能覆盖原视频。"
            return
        }
        isSaving = true
        saveErrorMessage = nil
        player?.pause()
        isPlaying = false
        Task { @MainActor in
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            defer {
                isSaving = false
                try? FileManager.default.removeItem(at: temp)
            }
            do {
                let asset = AVURLAsset(url: fileURL)
                let composition = AVMutableComposition()
                let tracks = try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio)
                for track in tracks {
                    guard let destination = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    destination.preferredTransform = try await track.load(.preferredTransform)
                    let available = try await track.load(.timeRange)
                    var cursor = CMTime.zero
                    for range in ranges {
                        let selected = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                                   end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
                        let intersection = CMTimeRangeGetIntersection(selected, otherRange: available)
                        if intersection.duration > .zero {
                            let insertion = cursor + (intersection.start - selected.start)
                            try destination.insertTimeRange(intersection, of: track, at: insertion)
                        }
                        cursor = cursor + selected.duration
                    }
                }
                guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                    throw NSError(domain: "QuickPeek", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建视频导出任务。"])
                }
                try await session.export(to: temp, as: .mp4)
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: outputURL)
                }
                exportedURL = outputURL
            } catch {
                saveErrorMessage = error.localizedDescription
            }
        }
    }

}


// MARK: - Video Frame Crop View
// Crops the visual frame of a video (like image crop but for video)
struct VideoFrameCropView: View {
    let fileURL: URL
    let onDone: () -> Void

    @State private var frameImage: NSImage?
    @State private var videoSize: CGSize = .zero
    @State private var cropRect: CGRect = .zero
    @State private var imageSize: CGSize = .zero
    @State private var isDragging = false
    @State private var initialCropRect: CGRect = .zero
    @State private var isSaving = false

    private let minCropPx: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { onDone() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("裁剪视频画面").font(.system(size: 13, weight: .medium))
                Spacer()
                if isSaving {
                    ProgressView().controlSize(.small)
                    Text("导出中…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button("重置") { cropRect = CGRect(origin: .zero, size: imageSize) }
                    Button("保存") { saveCroppedVideo() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            if let img = frameImage {
                GeometryReader { geo in
                    let fitted = fittedRect(in: geo.size)
                    let dc = cropInView(fitted: fitted)
                    ZStack {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: fitted.midX, y: fitted.midY)

                        // Dim overlay
                        Canvas { ctx, sz in
                            var outer = Path(); outer.addRect(CGRect(origin: .zero, size: sz))
                            var inner = Path(); inner.addRect(dc); outer.addPath(inner)
                            ctx.fill(outer, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                        }.allowsHitTesting(false)

                        // Border
                        Rectangle().stroke(Color.white, lineWidth: 1.5)
                            .frame(width: dc.width, height: dc.height)
                            .position(x: dc.midX, y: dc.midY).allowsHitTesting(false)

                        // Corner handles
                        ForEach(0..<4, id: \.self) { idx in
                            let pos = cornerPos(idx, in: dc)
                            Circle().fill(Color.white).frame(width: 12, height: 12)
                                .shadow(color: .black.opacity(0.3), radius: 2)
                                .position(x: pos.x, y: pos.y)
                                .gesture(cornerDrag(idx, fitted: fitted))
                        }

                        // Body drag
                        Rectangle().fill(Color.white.opacity(0.001)).contentShape(Rectangle())
                            .frame(width: dc.width, height: dc.height)
                            .position(x: dc.midX, y: dc.midY)
                            .gesture(bodyDrag(fitted: fitted))
                    }
                    .coordinateSpace(name: "vcanvas")
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
                    .onAppear {
                        imageSize = img.size
                        cropRect = CGRect(origin: .zero, size: img.size)
                    }
                }
            } else {
                Spacer()
                ProgressView("正在提取视频帧…")
                Spacer()
            }
        }
        .frame(minWidth: 600, minHeight: 450)
        .onAppear { extractFrame() }
    }

    private func extractFrame() {
        let asset = AVURLAsset(url: fileURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1920, height: 1920)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        Task.detached {
            do {
                let cgImg = try gen.copyCGImage(at: time, actualTime: nil)
                let ns = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                // Get actual video track size asynchronously
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let track = tracks.first {
                    let naturalSize = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let sz = naturalSize.applying(transform)
                    await MainActor.run { videoSize = CGSize(width: abs(sz.width), height: abs(sz.height)) }
                }
                await MainActor.run { frameImage = ns }
            } catch {
                // Frame extraction failed — show nothing
            }
        }
    }

    // MARK: - Geometry
    private func fittedRect(in container: CGSize) -> CGRect {
        guard imageSize.width > 0 else { return .zero }
        let s = min(container.width / imageSize.width, container.height / imageSize.height) * 0.9
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private func cropInView(fitted: CGRect) -> CGRect {
        guard imageSize.width > 0 else { return .zero }
        let sx = fitted.width / imageSize.width, sy = fitted.height / imageSize.height
        return CGRect(x: fitted.minX + cropRect.minX * sx, y: fitted.minY + cropRect.minY * sy,
                      width: cropRect.width * sx, height: cropRect.height * sy)
    }

    private func viewToImage(_ pt: CGPoint, fitted: CGRect) -> CGPoint {
        CGPoint(x: (pt.x - fitted.minX) * imageSize.width / fitted.width,
                y: (pt.y - fitted.minY) * imageSize.height / fitted.height)
    }

    private func cornerPos(_ idx: Int, in dc: CGRect) -> CGPoint {
        switch idx {
        case 0: return CGPoint(x: dc.minX, y: dc.minY)
        case 1: return CGPoint(x: dc.maxX, y: dc.minY)
        case 2: return CGPoint(x: dc.minX, y: dc.maxY)
        default: return CGPoint(x: dc.maxX, y: dc.maxY)
        }
    }

    private func cornerDrag(_ idx: Int, fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("vcanvas"))
            .onChanged { v in
                if !isDragging { isDragging = true; initialCropRect = cropRect }
                let pt = viewToImage(v.location, fitted: fitted)
                var r = initialCropRect
                switch idx {
                case 0:
                    let nx = min(pt.x, r.maxX - minCropPx).clamped(to: 0...imageSize.width)
                    let ny = min(pt.y, r.maxY - minCropPx).clamped(to: 0...imageSize.height)
                    r = CGRect(x: nx, y: ny, width: r.maxX - nx, height: r.maxY - ny)
                case 1:
                    let nx = max(pt.x, r.minX + minCropPx).clamped(to: 0...imageSize.width)
                    let ny = min(pt.y, r.maxY - minCropPx).clamped(to: 0...imageSize.height)
                    r = CGRect(x: r.minX, y: ny, width: nx - r.minX, height: r.maxY - ny)
                case 2:
                    let nx = min(pt.x, r.maxX - minCropPx).clamped(to: 0...imageSize.width)
                    let ny = max(pt.y, r.minY + minCropPx).clamped(to: 0...imageSize.height)
                    r = CGRect(x: nx, y: r.minY, width: r.maxX - nx, height: ny - r.minY)
                default:
                    let nx = max(pt.x, r.minX + minCropPx).clamped(to: 0...imageSize.width)
                    let ny = max(pt.y, r.minY + minCropPx).clamped(to: 0...imageSize.height)
                    r = CGRect(x: r.minX, y: r.minY, width: nx - r.minX, height: ny - r.minY)
                }
                cropRect = r
            }
            .onEnded { _ in isDragging = false }
    }

    private func bodyDrag(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("vcanvas"))
            .onChanged { v in
                if !isDragging { isDragging = true; initialCropRect = cropRect }
                let sx = imageSize.width / fitted.width, sy = imageSize.height / fitted.height
                var r = initialCropRect.offsetBy(dx: v.translation.width * sx, dy: v.translation.height * sy)
                r.origin.x = r.origin.x.clamped(to: 0...(imageSize.width - r.width))
                r.origin.y = r.origin.y.clamped(to: 0...(imageSize.height - r.height))
                cropRect = r
            }
            .onEnded { _ in isDragging = false }
    }

    // MARK: - Export cropped video
    private func saveCroppedVideo() {
        guard !isSaving else { return }
        isSaving = true
        let asset = AVURLAsset(url: fileURL)
        // Map crop from image coords to actual video pixel coords
        let scaleX = videoSize.width > 0 ? videoSize.width / imageSize.width : 1
        let scaleY = videoSize.height > 0 ? videoSize.height / imageSize.height : 1
        let pixelCrop = CGRect(
            x: cropRect.minX * scaleX, y: cropRect.minY * scaleY,
            width: cropRect.width * scaleX, height: cropRect.height * scaleY
        ).integral

        Task {
            do {
                let composition = AVMutableComposition()
                let videoComposition = AVMutableVideoComposition()

                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = videoTracks.first,
                      let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    await MainActor.run { isSaving = false }; return
                }
                let dur = try await asset.load(.duration)
                let timeRange = CMTimeRange(start: .zero, duration: dur)
                try compTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)

                // Copy audio if present
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                if let audioTrack = audioTracks.first,
                   let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try compAudio.insertTimeRange(timeRange, of: audioTrack, at: .zero)
                }

                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = timeRange
                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
                let preferredTransform = try await videoTrack.load(.preferredTransform)
                let transform = preferredTransform.translatedBy(x: -pixelCrop.minX, y: -pixelCrop.minY)
                layerInstruction.setTransform(transform, at: .zero)
                instruction.layerInstructions = [layerInstruction]

                videoComposition.instructions = [instruction]
                videoComposition.renderSize = pixelCrop.size
                videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

                let ext = fileURL.pathExtension.lowercased()
                let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
                guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                    await MainActor.run { isSaving = false }; return
                }
                session.videoComposition = videoComposition
                session.outputURL = tmpURL
                session.outputFileType = ext == "mov" ? .mov : .mp4

                session.exportAsynchronously {
                    DispatchQueue.main.async {
                        if session.status == .completed {
                            try? FileManager.default.removeItem(at: fileURL)
                            try? FileManager.default.moveItem(at: tmpURL, to: fileURL)
                        }
                        isSaving = false
                        onDone()
                    }
                }
            } catch {
                await MainActor.run { isSaving = false }
            }
        }
    }
}
