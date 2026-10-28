import Foundation
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import TimelineKitCore

public enum ClipExportFormat: String, CaseIterable, Sendable {
    case livePhoto, harmonyPhoto, video, gif, webp
    public var isLivePhoto: Bool { self == .livePhoto || self == .harmonyPhoto }
    public var title: String { switch self {
    case .livePhoto: "导出苹果实况图…"
    case .harmonyPhoto: "导出鸿蒙动态照片（测试版）…"
    case .video: "导出视频…"
    case .gif: "导出 GIF…"
    case .webp: "导出动态 WebP…"
    } }
    public var fileExtension: String { switch self {
    case .livePhoto: "pvt"
    case .harmonyPhoto: "jpg"
    case .video: "mp4"
    case .gif: "gif"
    case .webp: "webp"
    } }
}

public enum ClipExport {
    public static func selectedVideoIDs(in state: EditState) -> [UUID] {
        state.timeline.tracks.filter { $0.kind == .video }.flatMap(\.segments)
            .filter { state.selection.contains($0.id) }
            .sorted { $0.targetRange.start < $1.targetRange.start }.map(\.id)
    }

    /// Finish the entire batch in a private staging folder before publishing it.
    public static func exportSelectedLivePhotos(url: URL, state: EditState, to parent: URL, formats: [ClipExportFormat] = [.livePhoto],
        progress: (@Sendable (Int, Int) async -> Void)? = nil) async throws -> URL {
        guard !formats.isEmpty, formats.allSatisfy(\.isLivePhoto), Set(formats).count == formats.count else { throw failure("请选择实况照片格式。") }
        let ids = selectedVideoIDs(in:state)
        guard !ids.isEmpty else { throw failure("请先选择视频片段。") }
        let staging = parent.appendingPathComponent(".QuickPeek-batch-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:staging) }
        let clips = state.timeline.tracks.filter { $0.kind == .video }.flatMap(\.segments).sorted { $0.targetRange.start < $1.targetRange.start }
        var completed = 0
        let total = ids.count * formats.count
        for (index,id) in ids.enumerated() {
            let number = (clips.firstIndex { $0.id == id } ?? index) + 1
            for format in formats {
                try Task.checkCancellation()
                await progress?(completed,total)
                let output = staging.appendingPathComponent(String(format:"片段_%03d",number)+"."+format.fileExtension)
                try await export(url:url,state:state,clipID:id,format:format,to:output)
                completed += 1
                await progress?(completed,total)
            }
        }
        try Task.checkCancellation()
        let name = url.deletingPathExtension().lastPathComponent + "_实况图"
        var suffix = 0
        while true {
            let destination = parent.appendingPathComponent(name + (suffix == 0 ? "" : "_\(suffix)"))
            do { try FileManager.default.moveItem(at:staging,to:destination); return destination }
            catch {
                guard FileManager.default.fileExists(atPath:destination.path) else { throw error }
                suffix += 1
            }
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain:"QuickPeek.ClipExport",code:1,userInfo:[NSLocalizedDescriptionKey:message])
    }
    /// Export one video segment and the audible timeline underneath it, rebased to zero.
    public static func isolatedState(_ state: EditState, clipID: UUID) throws -> EditState {
        guard let video = state.timeline.tracks.filter({ $0.kind == .video }).flatMap(\.segments).first(where: { $0.id == clipID }) else {
            throw failure("请右键点击一个视频片段。")
        }
        let interval = video.targetRange
        var result = state
        for t in result.timeline.tracks.indices {
            let track = state.timeline.tracks[t]
            result.timeline.tracks[t].segments = track.segments.compactMap { segment in
                guard !track.isMuted, !track.isHidden,
                      track.kind == .audio || segment.id == clipID,
                      let source = segment.sourceRange else { return nil }
                let start = max(interval.start,segment.targetRange.start)
                let end = min(interval.end,segment.targetRange.end)
                guard end > start else { return nil }
                var clip = segment
                let ratio = source.duration / segment.targetRange.duration
                clip.sourceRange = TimeRange(start:source.start+(start-segment.targetRange.start)*ratio,duration:(end-start)*ratio)
                clip.targetRange = TimeRange(start:start-interval.start,duration:end-start)
                return clip
            }
        }
        result.selection = []; result.links = [:]
        return result
    }

    public static func export(url: URL, state: EditState, clipID: UUID, format: ClipExportFormat, to destination: URL) async throws {
        guard destination.resolvingSymlinksInPath().standardizedFileURL != url.resolvingSymlinksInPath().standardizedFileURL else { throw failure("请另存为副本，不能覆盖原视频。") }
        let isolated = try isolatedState(state,clipID:clipID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let movie = directory.appendingPathComponent("clip.mp4")
        let composition = try await TimelineMedia.composition(url:url,state:isolated)
        guard let session = AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality) else { throw failure("无法创建片段导出任务。") }
        session.videoComposition = try await TimelineMedia.videoComposition(for:composition)
        session.audioMix = try await TimelineMedia.audioMix(for:composition)
        try await session.export(to:movie,as:.mp4)
        try Task.checkCancellation()
        let result: URL
        switch format {
        case .video: result = movie
        case .gif, .webp:
            result = directory.appendingPathComponent("clip."+format.fileExtension)
            try await animation(movie:movie,format:format,to:result)
        case .harmonyPhoto:
            result = directory.appendingPathComponent("motion.jpg")
            try await harmonyPhoto(movie:movie,to:result)
        case .livePhoto:
            result = directory.appendingPathComponent("Live Photo")
            try FileManager.default.createDirectory(at:result,withIntermediateDirectories:true)
            try await livePhoto(movie:movie,to:result)
            // PVT manifest schema: RhetTbull/makelive _make_pvt_package.
            let metadata = try PropertyListSerialization.data(fromPropertyList:["PFVideoComplementMetadataVersionKey":"1"],format:.xml,options:0)
            try metadata.write(to:result.appendingPathComponent("metadata.plist"),options:.atomic)
            var packageURL = result
            var values = URLResourceValues(); values.isPackage = true
            try packageURL.setResourceValues(values)
        }
        // Commit only a completed result. Do not destroy an existing destination on failure.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".QuickPeek-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:staging) }
        try FileManager.default.copyItem(at:result,to:staging)
        if FileManager.default.fileExists(atPath:destination.path) {
            _ = try FileManager.default.replaceItemAt(destination,withItemAt:staging)
        } else { try FileManager.default.moveItem(at:staging,to:destination) }
    }

    private static func animation(movie: URL, format: ClipExportFormat, to output: URL) async throws {
        try await Task.detached(priority:.userInitiated) {
            let candidates = ["/opt/homebrew/bin/ffmpeg","/usr/local/bin/ffmpeg"]
            guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath:$0) }) else { throw failure("导出动图需要安装 ffmpeg；视频和实况图仍可直接导出。") }
            let log = output.deletingPathExtension().appendingPathExtension("log")
            FileManager.default.createFile(atPath:log.path,contents:nil)
            let handle = try FileHandle(forWritingTo:log)
            defer { try? handle.close() }
            func run(_ executable: String, _ arguments: [String]) throws {
                let process = Process(); process.executableURL = URL(fileURLWithPath:executable)
                process.arguments = arguments; process.standardOutput=handle; process.standardError=handle
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let detail = (try? String(contentsOf:log,encoding:.utf8)) ?? ""
                    throw failure("动图转换失败："+String(detail.suffix(2000)))
                }
            }
            let scale = "fps=15,scale=640:640:force_original_aspect_ratio=decrease:flags=lanczos"
            if format == .gif {
                try run(executable,["-hide_banner","-loglevel","error","-nostdin","-y","-i",movie.path,
                    "-filter_complex",scale+",split[a][b];[a]palettegen[p];[b][p]paletteuse","-loop","0","-an",output.path])
            } else {
                guard let encoder = ["/opt/homebrew/bin/img2webp","/usr/local/bin/img2webp"].first(where:{ FileManager.default.isExecutableFile(atPath:$0) }) else { throw failure("导出动态 WebP 需要安装 libwebp（img2webp）。") }
                let frames = output.deletingLastPathComponent().appendingPathComponent("frames")
                try FileManager.default.createDirectory(at:frames,withIntermediateDirectories:true)
                try run(executable,["-hide_banner","-loglevel","error","-nostdin","-y","-i",movie.path,"-vf",scale,"-an",frames.appendingPathComponent("%08d.png").path])
                let files = try FileManager.default.contentsOfDirectory(at:frames,includingPropertiesForKeys:nil).filter{$0.pathExtension == "png"}.sorted{$0.lastPathComponent < $1.lastPathComponent}
                guard !files.isEmpty else { throw failure("片段中没有可导出的画面。") }
                // Read arguments from a file so long clips do not exceed the process argument limit.
                let arguments = frames.appendingPathComponent("frames.txt")
                var options = "-loop 0 -lossy -q 85 "
                for (i,file) in files.enumerated() {
                    let delay = Int((Double(i+1)*1000/15).rounded()) - Int((Double(i)*1000/15).rounded())
                    options += "-d \(delay) \(file.path) "
                }
                options += "-o \(output.path)"
                try options.write(to:arguments,atomically:true,encoding:.utf8)
                try run(encoder,[arguments.path])
            }
        }.value
    }

    /// OpenHarmony moving_photo_file_utils.cpp: JPEG + MP4 + three 20-byte footer fields.
    /// https://github.com/openharmony/multimedia_media_library/blob/master/frameworks/innerkitsimpl/media_library_helper/src/moving_photo_file_utils.cpp
    private static func harmonyPhoto(movie: URL, to output: URL) async throws {
        let asset = AVURLAsset(url:movie)
        let duration = try await asset.load(.duration).seconds
        let still = duration / 2
        let generator = AVAssetImageGenerator(asset:asset); generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at:CMTime(seconds:still,preferredTimescale:60000))
        guard let encoder = CGImageDestinationCreateWithURL(output as CFURL,UTType.jpeg.identifier as CFString,1,nil) else { throw failure("无法创建动态照片。") }
        CGImageDestinationAddImage(encoder,frame.image,[kCGImageDestinationLossyCompressionQuality:0.95] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw failure("动态照片封面写入失败。") }
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw failure("动态照片没有视频轨道。") }
        // Count presentation timestamps to locate the cover even with variable frame rates.
        let reader = try AVAssetReader(asset:asset)
        let samples = AVAssetReaderTrackOutput(track:track,outputSettings:nil); reader.add(samples)
        guard reader.startReading() else { throw reader.error ?? failure("无法读取封面帧位置。") }
        var frameIndex = 0
        while let sample = samples.copyNextSampleBuffer() {
            if CMSampleBufferGetPresentationTimeStamp(sample) < frame.actualTime { frameIndex += 1 }
        }
        guard reader.status == .completed else { throw reader.error ?? failure("封面帧索引读取失败。") }
        let coverMS = max(0,Int(frame.actualTime.seconds * 1000))
        let bytes = try FileManager.default.attributesOfItem(atPath:movie.path)[.size] as? NSNumber
        guard let bytes else { throw failure("无法读取视频大小。") }
        func field(_ text: String) throws -> Data {
            guard text.utf8.count <= 20 else { throw failure("动态照片片段过长。") }
            return Data((text+String(repeating:" ",count:20-text.utf8.count)).utf8)
        }
        let footer = try field("v3_f\(frameIndex)") + field("\(max(0,coverMS-600)):\(coverMS)") + field("LIVE_\(bytes.int64Value+20)")
        let writer = try FileHandle(forWritingTo:output), input = try FileHandle(forReadingFrom:movie)
        defer { try? writer.close(); try? input.close() }
        try writer.seekToEnd()
        while let block = try input.read(upToCount:1_048_576), !block.isEmpty {
            try Task.checkCancellation(); try writer.write(contentsOf:block)
        }
        try writer.write(contentsOf:footer)
    }

    private static func livePhoto(movie: URL, to directory: URL) async throws {
        let asset = AVURLAsset(url:movie)
        let duration = try await asset.load(.duration)
        let stillTime = CMTimeMultiplyByFloat64(duration,multiplier:0.5)
        let identifier = UUID().uuidString
        let generator = AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true
        let image = try await generator.image(at:stillTime).image
        let jpeg = directory.appendingPathComponent("IMG.JPG")
        guard let imageDestination = CGImageDestinationCreateWithURL(jpeg as CFURL,UTType.jpeg.identifier as CFString,1,nil) else { throw failure("无法创建实况照片。") }
        CGImageDestinationAddImage(imageDestination,image,[kCGImagePropertyMakerAppleDictionary:["17":identifier],kCGImageDestinationLossyCompressionQuality:0.95] as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else { throw failure("实况照片写入失败。") }
        let reader = try AVAssetReader(asset:asset)
        let writer = try AVAssetWriter(outputURL:directory.appendingPathComponent("IMG.MOV"),fileType:.mov)
        let contentID=AVMutableMetadataItem();contentID.keySpace = .quickTimeMetadata
        contentID.key="com.apple.quicktime.content.identifier" as NSString
        contentID.value=identifier as NSString;contentID.dataType="com.apple.metadata.datatype.UTF-8"
        writer.metadata=[contentID]
        var pairs: [(AVAssetReaderTrackOutput,AVAssetWriterInput)] = []
        for track in try await asset.load(.tracks) {
            let type = track.mediaType
            guard type == .video || type == .audio else { continue }
            let descriptions = try await track.load(.formatDescriptions)
            let input=AVAssetWriterInput(mediaType:type,outputSettings:nil,sourceFormatHint:descriptions.first)
            if type == .video { input.transform=try await track.load(.preferredTransform) }
            let output=AVAssetReaderTrackOutput(track:track,outputSettings:nil)
            guard reader.canAdd(output),writer.canAdd(input) else { throw failure("无法封装实况图媒体轨道。") }
            reader.add(output);writer.add(input);pairs.append((output,input))
        }
        var description: CMFormatDescription?
        let spec: [String:Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:"mdta/com.apple.quicktime.still-image-time", kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:"com.apple.metadata.datatype.int8"]
        let status=CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator:kCFAllocatorDefault,metadataType:kCMMetadataFormatType_Boxed,metadataSpecifications:[spec] as CFArray,formatDescriptionOut:&description)
        guard status == noErr else { throw failure("无法创建实况图时间标记。") }
        let metadataInput=AVAssetWriterInput(mediaType:.metadata,outputSettings:nil,sourceFormatHint:description)
        let adaptor=AVAssetWriterInputMetadataAdaptor(assetWriterInput:metadataInput)
        guard writer.canAdd(metadataInput) else { throw failure("实况图元数据不可用。") };writer.add(metadataInput)
        guard writer.startWriting(),reader.startReading() else { throw writer.error ?? reader.error ?? failure("实况图封装失败。") }
        writer.startSession(atSourceTime:.zero)
        let marker=AVMutableMetadataItem();marker.keySpace = .quickTimeMetadata
        marker.key="com.apple.quicktime.still-image-time" as NSString
        marker.value=NSNumber(value:Int8(0));marker.dataType="com.apple.metadata.datatype.int8"
        guard adaptor.append(AVTimedMetadataGroup(items:[marker],timeRange:CMTimeRange(start:stillTime,duration:CMTime(value:1,timescale:30)))) else { throw writer.error ?? failure("实况图时间标记写入失败。") }
        metadataInput.markAsFinished()
        var finished=Set<Int>()
        do {
            while finished.count < pairs.count {
                try Task.checkCancellation()
                var advanced=false
                for (index,pair) in pairs.enumerated() where !finished.contains(index) {
                    if pair.1.isReadyForMoreMediaData {
                        if let sample=pair.0.copyNextSampleBuffer() {
                            guard pair.1.append(sample) else { throw writer.error ?? failure("实况视频写入失败。") }
                        } else { pair.1.markAsFinished();finished.insert(index) }
                        advanced=true
                    }
                }
                if writer.status == .failed { throw writer.error ?? failure("实况图写入失败。") }
                if !advanced { try await Task.sleep(for:.milliseconds(2)) }
            }
            if reader.status == .failed { throw reader.error ?? failure("实况视频读取失败。") }
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? failure("实况图未完成。") }
        } catch { reader.cancelReading();writer.cancelWriting();throw error }
    }
}
