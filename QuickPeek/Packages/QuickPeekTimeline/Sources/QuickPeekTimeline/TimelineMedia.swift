import Foundation
@preconcurrency import AVFoundation

public enum TimelineMedia {
    /// Both the preview and export use this exact composition, including independent audio edits.
    public static func composition(url: URL, state: EditState) async throws -> AVMutableComposition {
        let source = AVURLAsset(url: url)
        let videos = try await source.loadTracks(withMediaType: .video)
        let audios = try await source.loadTracks(withMediaType: .audio)
        let composition = AVMutableComposition()
        for track in state.timeline.tracks {
            let isVideo = track.kind == .video
            guard let input = (isVideo ? videos : audios).first,
                  let output = composition.addMutableTrack(withMediaType: isVideo ? .video : .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            if isVideo { output.preferredTransform = try await input.load(.preferredTransform) }
            for clip in track.segments.sorted(by: { $0.targetRange.start < $1.targetRange.start }) {
                guard let range = clip.sourceRange else { continue }
                try Task.checkCancellation()
                try output.insertTimeRange(CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 60000), duration: CMTime(seconds: range.duration, preferredTimescale: 60000)), of: input, at: CMTime(seconds: clip.targetRange.start, preferredTimescale: 60000))
            }
        }
        return composition
    }

    /// Explicit rendering flattens edit lists so arbitrary-frame cuts also seek correctly in other players.
    public static func videoComposition(for composition: AVComposition) async throws -> AVMutableVideoComposition? {
        guard let track = try await composition.loadTracks(withMediaType: .video).first else { return nil }
        let size = try await track.load(.naturalSize)
        guard size.width > 0, size.height > 0 else { return nil }
        let transform = try await track.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: size).applying(transform).standardized
        let fps = try await track.load(.nominalFrameRate)
        let result = AVMutableVideoComposition()
        result.renderSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        result.frameDuration = CMTime(seconds: 1/max(1, Double(fps > 0 ? fps : 30)), preferredTimescale: 60000)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await composition.load(.duration))
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -transformed.minX, y: -transformed.minY)), at: .zero)
        instruction.layerInstructions = [layer]
        result.instructions = [instruction]
        return result
    }

    public static func audioMix(for composition: AVComposition) async throws -> AVMutableAudioMix {
        let mix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []
        for track in try await composition.loadTracks(withMediaType: .audio) {
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(0, at: .zero)
            for segment in try await track.load(.segments) where !segment.isEmpty {
                input.setVolume(1, at: segment.timeMapping.target.start)
                input.setVolume(0, at: CMTimeRangeGetEnd(segment.timeMapping.target))
            }
            parameters.append(input)
        }
        mix.inputParameters = parameters
        return mix
    }

    public static func waveform(url: URL, duration: Double, bins: Int = 1600) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: 16000
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain:"Timeline",code:1) }
        var peaks = [Float](repeating: 0, count: bins)
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let data = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size
            var values = [Float](repeating:0,count:count)
            _ = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset:0, dataLength:count*4, destination:$0.baseAddress!) }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for i in values.indices {
                let index = min(bins-1,max(0,Int((start+Double(i)/16000)/max(duration,0.001)*Double(bins))))
                peaks[index] = max(peaks[index],abs(values[i]))
            }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain:"Timeline",code:2) }
        let peak = peaks.max() ?? 1
        return peaks.map { $0 / max(peak,0.001) }
    }
}
