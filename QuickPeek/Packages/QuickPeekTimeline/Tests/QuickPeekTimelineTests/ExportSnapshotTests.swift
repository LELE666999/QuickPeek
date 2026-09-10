import XCTest
@preconcurrency import AVFoundation
@testable import QuickPeekTimeline

final class ExportSnapshotTests: XCTestCase {
    func testRemovingAllAudioStillExportsVideo() async throws {
        let source = URL(fileURLWithPath:"/tmp/quickpeek-edit-test/source.mp4")
        guard FileManager.default.fileExists(atPath:source.path) else { throw XCTSkip("Run tests/run-timeline-tests.py to generate fixture") }
        var edits = TimelineEdits(duration:6, fps:30, hasAudio:true)
        edits.selectAll(); edits.unlinkSelection()
        edits.select(edits.state.timeline.tracks[1].segments[0].id)
        edits.deleteSelection(ripple:false)
        let composition = try await TimelineMedia.composition(url:source,state:edits.state)
        let audio = try await composition.loadTracks(withMediaType:.audio)
        XCTAssertTrue(audio.isEmpty)
        let exporter = try XCTUnwrap(AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality))
        exporter.videoComposition = try await TimelineMedia.videoComposition(for:composition)
        exporter.audioMix = try await TimelineMedia.audioMix(for:composition)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at:output) }
        try await exporter.export(to:output,as:.mp4)
        let result = AVURLAsset(url:output)
        let duration = try await result.load(.duration).seconds
        let outputAudio = try await result.loadTracks(withMediaType:.audio)
        XCTAssertEqual(duration,6,accuracy:0.1)
        XCTAssertTrue(outputAudio.isEmpty)
    }

    func testRealFailedSnapshot() async throws {
        guard let path = ProcessInfo.processInfo.environment["QUICKPEEK_EXPORT_PROJECT"] else { throw XCTSkip("Requires local failed project") }
        let project = try JSONDecoder().decode(TimelineProject.self, from: Data(contentsOf: URL(fileURLWithPath:path)))
        let composition = try await TimelineMedia.composition(url: project.sourceURL, state: project.state)
        let exporter = try XCTUnwrap(AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality))
        exporter.videoComposition = try await TimelineMedia.videoComposition(for:composition)
        exporter.audioMix = try await TimelineMedia.audioMix(for:composition)
        let output = URL(fileURLWithPath:"/tmp/quickpeek-reproduced-export.mp4")
        try? FileManager.default.removeItem(at:output)
        do { try await exporter.export(to:output,as:.mp4) }
        catch { print("SNAPSHOT ERROR",(error as NSError).userInfo);throw error }
        let duration = try await AVURLAsset(url:output).load(.duration).seconds
        XCTAssertGreaterThan(duration, 0)
    }
}
