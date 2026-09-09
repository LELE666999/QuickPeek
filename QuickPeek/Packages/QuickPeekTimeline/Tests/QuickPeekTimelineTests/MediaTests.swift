import XCTest
@preconcurrency import AVFoundation
@testable import QuickPeekTimeline

final class MediaTests: XCTestCase {
    func testEditedCompositionExportAndWaveform() async throws {
        let source = URL(fileURLWithPath: "/tmp/quickpeek-edit-test/source.mp4")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Generate the 6-second audio/video fixture first") }
        let originalBytes = try Data(contentsOf: source)
        defer { XCTAssertEqual(try? Data(contentsOf: source), originalBytes) }
        var e = TimelineEdits(duration: 6,fps:30,hasAudio:true)
        for time in [1.0,2,3,4,5] { e.split(at:time) }
        let clips = e.state.timeline.tracks[0].segments
        e.select(clips[1].id); e.select(clips[3].id,additive:true)
        e.deleteSelection(ripple:true)
        let composition = try await TimelineMedia.composition(url:source,state:e.state)
        let duration = try await composition.load(.duration).seconds
        XCTAssertEqual(duration,4,accuracy:0.04)
        let videos = try await composition.loadTracks(withMediaType:.video)
        let audios = try await composition.loadTracks(withMediaType:.audio)
        XCTAssertEqual(videos.count,1); XCTAssertEqual(audios.count,1)
        let videoSegments = try await videos[0].load(.segments)
        let audioSegments = try await audios[0].load(.segments)
        for (target,sourceTime) in [(0.5,0.5),(1.5,2.5),(2.5,4.5),(3.5,5.5)] {
            for trackSegments in [videoSegments,audioSegments] {
                let segment = try XCTUnwrap(trackSegments.first { !$0.isEmpty && $0.timeMapping.target.start.seconds <= target && CMTimeRangeGetEnd($0.timeMapping.target).seconds > target })
                XCTAssertEqual(segment.timeMapping.source.start.seconds + target - segment.timeMapping.target.start.seconds,sourceTime,accuracy:0.001)
            }
        }
        let output = URL(fileURLWithPath:"/tmp/quickpeek-edit-test/timeline-batch.mp4")
        try? FileManager.default.removeItem(at:output)
        let exporter = try XCTUnwrap(AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality))
        exporter.videoComposition = try await TimelineMedia.videoComposition(for:composition)
        exporter.audioMix = try await TimelineMedia.audioMix(for:composition)
        try await exporter.export(to:output,as:.mp4)
        let result = AVURLAsset(url:output)
        let resultDuration = try await result.load(.duration).seconds
        XCTAssertEqual(resultDuration,4,accuracy:0.05)
        let peaks = try await TimelineMedia.waveform(url:source,duration:6)
        XCTAssertEqual(peaks.count,1600)
        XCTAssertGreaterThan(peaks.max() ?? 0,0.9)
        e.select(e.state.timeline.tracks[0].segments[1].id); e.unlinkSelection()
        e.select(e.state.timeline.tracks[1].segments[1].id)
        e.deleteSelection(ripple:false)
        let detached = try await TimelineMedia.composition(url:source,state:e.state)
        let detachedAudio = try await detached.loadTracks(withMediaType:.audio)
        let segments = try await detachedAudio[0].load(.segments)
        XCTAssertTrue(segments.contains { $0.isEmpty && abs($0.timeMapping.target.start.seconds-1)<0.01 && abs($0.timeMapping.target.duration.seconds-1)<0.01 })
        let detachedVideo = try await detached.loadTracks(withMediaType:.video)
        let remainingVideo = try await detachedVideo[0].load(.segments)
        XCTAssertEqual(remainingVideo.filter{ !$0.isEmpty }.reduce(0) { $0 + $1.timeMapping.target.duration.seconds },4,accuracy:0.001)
        let detachedOutput=URL(fileURLWithPath:"/tmp/quickpeek-edit-test/timeline-detached.mp4")
        try? FileManager.default.removeItem(at:detachedOutput)
        let detachedExporter=try XCTUnwrap(AVAssetExportSession(asset:detached,presetName:AVAssetExportPresetHighestQuality))
        detachedExporter.videoComposition = try await TimelineMedia.videoComposition(for:detached)
        detachedExporter.audioMix = try await TimelineMedia.audioMix(for:detached)
        try await detachedExporter.export(to:detachedOutput,as:.mp4)
    }
    func testSilentAndRotatedSources() async throws {
        for name in ["silent","rotated","24fps"] {
            let url=URL(fileURLWithPath:"/tmp/quickpeek-edit-test/\(name).mp4")
            guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Generate silent and rotated fixtures first") }
            var e=TimelineEdits(duration:6,fps:name == "24fps" ? 24 : 30,hasAudio:name != "silent")
            e.split(at:1.5)
            e.select(e.state.timeline.tracks[0].segments[0].id)
            e.deleteSelection(ripple:true)
            let composition=try await TimelineMedia.composition(url:url,state:e.state)
            let video=try await TimelineMedia.videoComposition(for:composition)
            if name == "rotated" { XCTAssertEqual(video?.renderSize,CGSize(width:240,height:320)) }
            else if name == "silent" {
                let audio=try await composition.loadTracks(withMediaType:.audio)
                XCTAssertTrue(audio.isEmpty)
                let wave=try await TimelineMedia.waveform(url:url,duration:6)
                XCTAssertTrue(wave.isEmpty)
            }
            let out=URL(fileURLWithPath:"/tmp/quickpeek-edit-test/timeline-\(name).mp4")
            try? FileManager.default.removeItem(at:out)
            let exporter=try XCTUnwrap(AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality))
            exporter.videoComposition=video
            exporter.audioMix=try await TimelineMedia.audioMix(for:composition)
            try await exporter.export(to:out,as:.mp4)
            let duration=try await AVURLAsset(url:out).load(.duration).seconds
            XCTAssertEqual(duration,4.5,accuracy:0.04)
        }
    }
}
