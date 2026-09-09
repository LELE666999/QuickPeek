import XCTest
@preconcurrency import AVFoundation
@testable import QuickPeekTimeline
final class VariableRateTests: XCTestCase {
    func testSelectedScreenRecordingExport() async throws {
        guard let path=ProcessInfo.processInfo.environment["QUICKPEEK_EXPORT_SAMPLE"] else { throw XCTSkip("Optional real screen recording") }
        let url=URL(fileURLWithPath:path), asset=AVURLAsset(url:URL(fileURLWithPath:path))
        let duration=try await asset.load(.duration).seconds
        let tracks=try await asset.loadTracks(withMediaType:.video)
        let video=try XCTUnwrap(tracks.first)
        let fps=try await video.load(.nominalFrameRate)
        print("SOURCE nominal fps",fps,"duration",duration)
        for scenario in ["whole", "trim", "leading-gap", "middle-gap", "audio-only-tail"] {
        var edits=TimelineEdits(duration:duration,fps:Double(fps),hasAudio:true)
        if scenario == "trim" { edits.split(at:10);edits.split(at:14);edits.select(edits.state.timeline.tracks[0].segments.last!.id);edits.deleteSelection(ripple:true) }
        if scenario == "leading-gap" { edits.selectAll();edits.moveSelection(by:1) }
        if scenario == "middle-gap" { edits.split(at:10);edits.select(edits.state.timeline.tracks[0].segments.last!.id);edits.moveSelection(by:1) }
        if scenario == "audio-only-tail" { edits.split(at:14);edits.select(edits.state.timeline.tracks[0].segments.last!.id);edits.unlinkSelection();edits.select(edits.state.timeline.tracks[0].segments.last!.id);edits.deleteSelection(ripple:false) }
        print("SCENARIO",scenario)
        let composition=try await TimelineMedia.composition(url:url,state:edits.state)
        let render=try await TimelineMedia.videoComposition(for:composition)
        print("RENDER",render?.frameDuration.seconds ?? 0)
        let exporter=try XCTUnwrap(AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality))
        exporter.videoComposition=render;exporter.audioMix=try await TimelineMedia.audioMix(for:composition)
        let out=URL(fileURLWithPath:"/tmp/quickpeek-real-\(scenario).mp4");try? FileManager.default.removeItem(at:out)
        do { try await exporter.export(to:out,as:.mp4) }
        catch { print("EXPORT FAILURE",String(reflecting:error), (error as NSError).userInfo);throw error }
        let resultDuration=try await AVURLAsset(url:out).load(.duration).seconds
        XCTAssertEqual(resultDuration,edits.duration,accuracy:0.15)
        }
    }
}
