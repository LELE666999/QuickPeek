import SwiftUI
import AppKit
import ImageIO
import SDWebImage
import SDWebImageWebPCoder

private enum CropEdge {
    case left
    case right
    case top
    case bottom
}

struct ImageCropView: View {
    let image: NSImage
    let fileURL: URL
    let onDone: () -> Void

    @State private var cropRect: CGRect = .zero
    @State private var imageSize: CGSize = .zero
    @State private var isDragging = false
    @State private var initialCropRect: CGRect = .zero
    @State private var canvasSize: CGSize = .zero
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var previousMovableByBackground: Bool?

    private let minCropPx: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { onDone() }.keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Spacer()
                Text(isAnimatedSource ? "裁剪动图" : "裁剪图片").font(.system(size: 13, weight: .medium))
                Spacer()
                Button("重置") { resetCrop() }
                    .disabled(isSaving)
                Button(isSaving ? "保存中…" : "保存") { saveCrop() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            GeometryReader { geo in
                let fitted = fittedRect(in: geo.size)
                let dc = cropInView(fitted: fitted)
                ZStack {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)

                    dimOverlay(dc: dc, size: geo.size)
                    cropBorder(dc: dc)
                    gridLines(dc: dc)
                    bodyDragArea(dc: dc, fitted: fitted)
                    edgeHandles(dc: dc, fitted: fitted)
                    handles(dc: dc, fitted: fitted)
                }
                .coordinateSpace(name: "canvas")
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .onAppear {
                    imageSize = image.size
                    canvasSize = geo.size
                    cropRect = CGRect(origin: .zero, size: image.size)
                }
                .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 600, minHeight: 450)
        .onAppear {
            setWindowBackgroundDragging(enabled: false)
        }
        .onDisappear {
            setWindowBackgroundDragging(enabled: previousMovableByBackground ?? true)
        }
    }

    private var isAnimatedSource: Bool {
        guard let animated = SDAnimatedImage(contentsOfFile: fileURL.path) else { return false }
        return animated.animatedImageFrameCount > 1
    }

    // MARK: - Geometry

    private func fittedRect(in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
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

    // MARK: - Subviews

    private func dimOverlay(dc: CGRect, size: CGSize) -> some View {
        Canvas { ctx, sz in
            var outer = Path(); outer.addRect(CGRect(origin: .zero, size: sz))
            var inner = Path(); inner.addRect(dc); outer.addPath(inner)
            ctx.fill(outer, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        }.allowsHitTesting(false)
    }

    private func cropBorder(dc: CGRect) -> some View {
        Rectangle().stroke(Color.white, lineWidth: 1.5)
            .frame(width: dc.width, height: dc.height)
            .position(x: dc.midX, y: dc.midY)
            .allowsHitTesting(false)
    }

    private func gridLines(dc: CGRect) -> some View {
        Canvas { ctx, _ in
            let c = Color.white.opacity(0.3)
            for i in 1...2 {
                let x = dc.minX + dc.width * CGFloat(i) / 3
                var p = Path(); p.move(to: CGPoint(x: x, y: dc.minY)); p.addLine(to: CGPoint(x: x, y: dc.maxY))
                ctx.stroke(p, with: .color(c), lineWidth: 0.5)
                let y = dc.minY + dc.height * CGFloat(i) / 3
                var q = Path(); q.move(to: CGPoint(x: dc.minX, y: y)); q.addLine(to: CGPoint(x: dc.maxX, y: y))
                ctx.stroke(q, with: .color(c), lineWidth: 0.5)
            }
        }.allowsHitTesting(false)
    }

    private func handles(dc: CGRect, fitted: CGRect) -> some View {
        let corners: [(CGPoint, Int)] = [
            (CGPoint(x: dc.minX, y: dc.minY), 0), // topLeft
            (CGPoint(x: dc.maxX, y: dc.minY), 1), // topRight
            (CGPoint(x: dc.minX, y: dc.maxY), 2), // bottomLeft
            (CGPoint(x: dc.maxX, y: dc.maxY), 3), // bottomRight
        ]
        return ZStack {
            ForEach(corners, id: \.1) { pos, idx in
                Circle().fill(Color.white).frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .position(x: pos.x, y: pos.y)
                    .cursorOnHover(.crosshair)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                            .onChanged { v in
                                if !isDragging { isDragging = true; initialCropRect = cropRect }
                                let imgPt = viewToImage(v.location, fitted: fitted)
                                updateCorner(idx, imgPt: imgPt)
                            }
                            .onEnded { _ in isDragging = false }
                    )
            }
        }
    }

    private func edgeHandles(dc: CGRect, fitted: CGRect) -> some View {
        ZStack {
            edgeHandle(.left, dc: dc, fitted: fitted)
            edgeHandle(.right, dc: dc, fitted: fitted)
            edgeHandle(.top, dc: dc, fitted: fitted)
            edgeHandle(.bottom, dc: dc, fitted: fitted)
        }
    }

    private func edgeHandle(_ edge: CropEdge, dc: CGRect, fitted: CGRect) -> some View {
        let thickness: CGFloat = 14
        let size: CGSize
        let position: CGPoint
        let cursor: NSCursor

        switch edge {
        case .left:
            size = CGSize(width: thickness, height: max(dc.height - 10, thickness))
            position = CGPoint(x: dc.minX, y: dc.midY)
            cursor = .resizeLeftRight
        case .right:
            size = CGSize(width: thickness, height: max(dc.height - 10, thickness))
            position = CGPoint(x: dc.maxX, y: dc.midY)
            cursor = .resizeLeftRight
        case .top:
            size = CGSize(width: max(dc.width - 10, thickness), height: thickness)
            position = CGPoint(x: dc.midX, y: dc.minY)
            cursor = .resizeUpDown
        case .bottom:
            size = CGSize(width: max(dc.width - 10, thickness), height: thickness)
            position = CGPoint(x: dc.midX, y: dc.maxY)
            cursor = .resizeUpDown
        }

        return Rectangle()
            .fill(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .frame(width: size.width, height: size.height)
            .position(x: position.x, y: position.y)
            .cursorOnHover(cursor)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            initialCropRect = cropRect
                        }
                        let imagePoint = viewToImage(value.location, fitted: fitted)
                        updateEdge(edge, imagePoint: imagePoint)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }

    private func bodyDragArea(dc: CGRect, fitted: CGRect) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).contentShape(Rectangle())
            .frame(width: dc.width, height: dc.height)
            .position(x: dc.midX, y: dc.midY)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                    .onChanged { v in
                        if !isDragging { isDragging = true; initialCropRect = cropRect }
                        let sx = imageSize.width / fitted.width, sy = imageSize.height / fitted.height
                        var r = initialCropRect.offsetBy(dx: v.translation.width * sx, dy: v.translation.height * sy)
                        r.origin.x = r.origin.x.clamped(to: 0...(imageSize.width - r.width))
                        r.origin.y = r.origin.y.clamped(to: 0...(imageSize.height - r.height))
                        cropRect = r
                    }
                    .onEnded { _ in isDragging = false }
            )
    }

    private func updateCorner(_ idx: Int, imgPt: CGPoint) {
        var r = initialCropRect
        switch idx {
        case 0: // topLeft
            let nx = min(imgPt.x, r.maxX - minCropPx).clamped(to: 0...imageSize.width)
            let ny = min(imgPt.y, r.maxY - minCropPx).clamped(to: 0...imageSize.height)
            r = CGRect(x: nx, y: ny, width: r.maxX - nx, height: r.maxY - ny)
        case 1: // topRight
            let nx = max(imgPt.x, r.minX + minCropPx).clamped(to: 0...imageSize.width)
            let ny = min(imgPt.y, r.maxY - minCropPx).clamped(to: 0...imageSize.height)
            r = CGRect(x: r.minX, y: ny, width: nx - r.minX, height: r.maxY - ny)
        case 2: // bottomLeft
            let nx = min(imgPt.x, r.maxX - minCropPx).clamped(to: 0...imageSize.width)
            let ny = max(imgPt.y, r.minY + minCropPx).clamped(to: 0...imageSize.height)
            r = CGRect(x: nx, y: r.minY, width: r.maxX - nx, height: ny - r.minY)
        default: // bottomRight
            let nx = max(imgPt.x, r.minX + minCropPx).clamped(to: 0...imageSize.width)
            let ny = max(imgPt.y, r.minY + minCropPx).clamped(to: 0...imageSize.height)
            r = CGRect(x: r.minX, y: r.minY, width: nx - r.minX, height: ny - r.minY)
        }
        cropRect = r
    }

    private func updateEdge(_ edge: CropEdge, imagePoint: CGPoint) {
        var r = initialCropRect
        switch edge {
        case .left:
            let nx = min(imagePoint.x, r.maxX - minCropPx).clamped(to: 0...imageSize.width)
            r = CGRect(x: nx, y: r.minY, width: r.maxX - nx, height: r.height)
        case .right:
            let nx = max(imagePoint.x, r.minX + minCropPx).clamped(to: 0...imageSize.width)
            r = CGRect(x: r.minX, y: r.minY, width: nx - r.minX, height: r.height)
        case .top:
            let ny = min(imagePoint.y, r.maxY - minCropPx).clamped(to: 0...imageSize.height)
            r = CGRect(x: r.minX, y: ny, width: r.width, height: r.maxY - ny)
        case .bottom:
            let ny = max(imagePoint.y, r.minY + minCropPx).clamped(to: 0...imageSize.height)
            r = CGRect(x: r.minX, y: r.minY, width: r.width, height: ny - r.minY)
        }
        cropRect = r
    }

    // MARK: - Actions

    private func resetCrop() { cropRect = CGRect(origin: .zero, size: imageSize) }

    private func setWindowBackgroundDragging(enabled: Bool) {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            if previousMovableByBackground == nil {
                previousMovableByBackground = window.isMovableByWindowBackground
            }
            window.isMovableByWindowBackground = enabled
        }
    }

    private func saveCrop() {
        errorMessage = nil
        if isAnimatedSource {
            saveAnimatedCrop()
            return
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let s = CGFloat(cgImage.width) / imageSize.width
        let px = CGRect(x: cropRect.minX * s, y: cropRect.minY * s,
                        width: cropRect.width * s, height: cropRect.height * s).integral
        guard let cropped = cgImage.cropping(to: px) else { return }
        let rep = NSBitmapImageRep(cgImage: cropped)
        let ext = fileURL.pathExtension.lowercased()
        let data = ext == "png"
            ? rep.representation(using: .png, properties: [:])
            : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        guard let d = data else { return }
        try? d.write(to: fileURL)
        onDone()
    }

    private func saveAnimatedCrop() {
        let cropRect = self.cropRect
        let imageSize = self.imageSize
        let fileURL = self.fileURL
        isSaving = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = cropAnimatedImage(fileURL: fileURL, cropRect: cropRect, imageSize: imageSize)

            DispatchQueue.main.async {
                isSaving = false
                switch result {
                case .success:
                    onDone()
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private enum AnimatedCropError: LocalizedError {
    case cannotDecode
    case cannotCrop
    case cannotEncode
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .cannotDecode:
            return "无法读取这张动图。"
        case .cannotCrop:
            return "无法裁剪动图帧。"
        case .cannotEncode:
            return "无法重新编码成动图。"
        case .cannotWrite(let message):
            return "保存失败：\(message)"
        }
    }
}

private func cropAnimatedImage(fileURL: URL, cropRect: CGRect, imageSize: CGSize) -> Result<Void, Error> {
    guard let animatedImage = SDAnimatedImage(contentsOfFile: fileURL.path),
          animatedImage.animatedImageFrameCount > 1,
          imageSize.width > 0,
          imageSize.height > 0 else {
        return .failure(AnimatedCropError.cannotDecode)
    }

    let frameCount = Int(animatedImage.animatedImageFrameCount)
    var frames: [SDImageFrame] = []
    frames.reserveCapacity(frameCount)

    for index in 0..<frameCount {
        guard let frameImage = animatedImage.animatedImageFrame(at: UInt(index)),
              let frameCGImage = frameImage.cropViewCGImage else {
            return .failure(AnimatedCropError.cannotCrop)
        }

        let scaleX = CGFloat(frameCGImage.width) / imageSize.width
        let scaleY = CGFloat(frameCGImage.height) / imageSize.height
        let pixelRect = CGRect(
            x: cropRect.minX * scaleX,
            y: cropRect.minY * scaleY,
            width: cropRect.width * scaleX,
            height: cropRect.height * scaleY
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: frameCGImage.width, height: frameCGImage.height))

        guard pixelRect.width >= 1,
              pixelRect.height >= 1,
              let croppedCGImage = frameCGImage.cropping(to: pixelRect) else {
            return .failure(AnimatedCropError.cannotCrop)
        }

        let croppedImage = NSImage(cgImage: croppedCGImage, size: NSSize(width: pixelRect.width, height: pixelRect.height))
        let duration = max(animatedImage.animatedImageDuration(at: UInt(index)), 0.02)
        frames.append(SDImageFrame(image: croppedImage, duration: duration))
    }

    guard !frames.isEmpty else {
        return .failure(AnimatedCropError.cannotCrop)
    }

    let ext = fileURL.pathExtension.lowercased()
    let options: [SDImageCoderOption: Any] = [
        .encodeCompressionQuality: 0.92,
        .encodeFirstFrameOnly: false
    ]
    let loopCount = UInt(animatedImage.animatedImageLoopCount)
    let data: Data?

    if ext == "webp" {
        data = SDImageWebPCoder.shared.encodedData(with: frames, loopCount: loopCount, format: .webP, options: options)
    } else {
        data = SDImageGIFCoder.shared.encodedData(with: frames, loopCount: loopCount, format: .GIF, options: options)
    }

    guard let data else {
        return .failure(AnimatedCropError.cannotEncode)
    }

    do {
        try data.write(to: fileURL, options: .atomic)
        return .success(())
    } catch {
        return .failure(AnimatedCropError.cannotWrite(error.localizedDescription))
    }
}

private extension NSImage {
    var cropViewCGImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        if let cgImage = cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cgImage
        }

        guard let data = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            return nil
        }
        return bitmap.cgImage
    }
}

private extension View {
    func cursorOnHover(_ cursor: NSCursor) -> some View {
        onHover { isInside in
            if isInside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
