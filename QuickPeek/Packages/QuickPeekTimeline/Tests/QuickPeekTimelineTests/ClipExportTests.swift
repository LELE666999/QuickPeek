import XCTest
@preconcurrency import AVFoundation
import ImageIO
import Photos
@testable import QuickPeekTimeline

final class ClipExportTests: XCTestCase {
    func testOnlyContextClipWithOverlappingAudio() throws {
        var edits = TimelineEdits(duration:6,fps:30,hasAudio:true)
        edits.split(at:2); edits.split(at:4); edits.selectAll()
        let clips = edits.state.timeline.tracks[0].segments
        let result = try ClipExport.isolatedState(edits.state,clipID:clips[1].id)
        for track in result.timeline.tracks {
            XCTAssertEqual(track.segments.count,1)
            XCTAssertEqual(track.segments[0].sourceRange!.start,2,accuracy:0.001)
            XCTAssertEqual(track.segments[0].sourceRange!.duration,2,accuracy:0.001)
            XCTAssertEqual(track.segments[0].targetRange.start,0)
        }
        XCTAssertTrue(result.selection.isEmpty)
        XCTAssertEqual(edits.state.timeline.tracks[0].segments.count,3)
        XCTAssertThrowsError(try ClipExport.isolatedState(edits.state,clipID:UUID()))
    }
    func testSourceCannotBeOverwritten() async throws {
        let source = URL(fileURLWithPath:"/tmp/quickpeek-edit-test/source.mp4")
        let edits = TimelineEdits(duration:6,fps:30,hasAudio:true)
        let id = edits.state.timeline.tracks[0].segments[0].id
        do {
            try await ClipExport.export(url:source,state:edits.state,clipID:id,format:.video,to:source)
            XCTFail("Must refuse to overwrite the original")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不能覆盖原视频")) }
    }
    func testBatchNonAdjacentSelectionAndNoOverwrite() async throws {
        let source = URL(fileURLWithPath:"/tmp/quickpeek-edit-test/source.mp4")
        guard FileManager.default.fileExists(atPath:source.path) else { throw XCTSkip("Generate fixtures first") }
        var edits = TimelineEdits(duration:6,fps:30,hasAudio:true)
        edits.split(at:2); edits.split(at:4)
        let clips = edits.state.timeline.tracks[0].segments
        edits.select(clips[2].id); edits.select(clips[0].id,additive:true)
        XCTAssertEqual(ClipExport.selectedVideoIDs(in:edits.state),[clips[0].id,clips[2].id])
        let root = source.deletingLastPathComponent().appendingPathComponent("batch-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let folder = try await ClipExport.exportSelectedLivePhotos(url:source,state:edits.state,to:root,formats:[.livePhoto,.harmonyPhoto])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:folder.path)),["片段_001.pvt","片段_003.pvt","片段_001.jpg","片段_003.jpg"])
        let second = try await ClipExport.exportSelectedLivePhotos(url:source,state:edits.state,to:root)
        XCTAssertNotEqual(folder,second)
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.appendingPathComponent("片段_001.jpg").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".QuickPeek")})
        // Nothing selected: fail without creating an empty batch folder.
        var empty = edits.state; empty.selection = []
        do { _ = try await ClipExport.exportSelectedLivePhotos(url:source,state:empty,to:root); XCTFail("Empty selection accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("选择视频")) }
    }
    func testAllExportFormats() async throws {
        let source = URL(fileURLWithPath:"/tmp/quickpeek-edit-test/source.mp4")
        guard FileManager.default.fileExists(atPath:source.path) else { throw XCTSkip("Generate fixtures first") }
        var edits = TimelineEdits(duration:6,fps:30,hasAudio:true)
        edits.split(at:2); edits.split(at:4); edits.selectAll()
        let id = edits.state.timeline.tracks[0].segments[1].id
        let root = source.deletingLastPathComponent().appendingPathComponent("clip-exports")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for format in ClipExportFormat.allCases {
            let output = root.appendingPathComponent(format == .livePhoto ? "live.pvt" : "clip."+format.fileExtension)
            try? FileManager.default.removeItem(at:output)
            try await ClipExport.export(url:source,state:edits.state,clipID:id,format:format,to:output)
            XCTAssertTrue(FileManager.default.fileExists(atPath:output.path))
            if format == .video || format == .livePhoto {
                let movie = format == .video ? output : output.appendingPathComponent("IMG.MOV")
                let asset = AVURLAsset(url:movie)
                let duration = try await asset.load(.duration).seconds
                XCTAssertEqual(duration,2,accuracy:0.08)
                let audio = try await asset.loadTracks(withMediaType:.audio)
                XCTAssertEqual(audio.count,1)
                if format == .livePhoto {
                    XCTAssertEqual(try output.resourceValues(forKeys:[.isPackageKey]).isPackage,true)
                    let manifest = try PropertyListSerialization.propertyList(from:Data(contentsOf:output.appendingPathComponent("metadata.plist")),options:[],format:nil) as? [String:String]
                    XCTAssertEqual(manifest?["PFVideoComplementMetadataVersionKey"],"1")
                    let jpeg = try XCTUnwrap(CGImageSourceCreateWithURL(output.appendingPathComponent("IMG.JPG") as CFURL,nil))
                    let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(jpeg,0,nil) as? [String:Any])
                    let maker = try XCTUnwrap(props[kCGImagePropertyMakerAppleDictionary as String] as? [String:Any])
                    let metadata = try await asset.load(.metadata)
                    let item = try XCTUnwrap(metadata.first{$0.key as? String == "com.apple.quicktime.content.identifier"})
                    let identifier = try await item.load(.stringValue)
                    XCTAssertEqual(maker["17"] as? String,identifier)
                    let tracks = try await asset.loadTracks(withMediaType:.metadata)
                    XCTAssertFalse(tracks.isEmpty)
                    let accepted = expectation(description:"Photos recognizes exported pair")
                    PHLivePhoto.request(withResourceFileURLs:[output.appendingPathComponent("IMG.JPG"),movie],placeholderImage:nil,targetSize:.zero,contentMode:.aspectFit) { photo, info in
                        if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
                        XCTAssertNotNil(photo,"\(info)"); accepted.fulfill()
                    }
                    await fulfillment(of:[accepted],timeout:20)
                }
            } else if format == .harmonyPhoto {
                let data = try Data(contentsOf:output)
                let tail = String(data:data.suffix(20),encoding:.ascii)!.trimmingCharacters(in:.whitespaces)
                XCTAssertTrue(tail.hasPrefix("LIVE_"))
                let liveSize = Int(tail.dropFirst(5))!
                let imageSize = data.count-liveSize-40
                XCTAssertGreaterThan(imageSize,0)
                XCTAssertNotNil(CGImageSourceCreateWithData(data.prefix(imageSize) as CFData,nil))
                XCTAssertTrue(String(data:data.suffix(60).prefix(20),encoding:.ascii)!.hasPrefix("v3_f"))
                let mp4 = root.appendingPathComponent("harmony-extracted.mp4")
                try data.subdata(in:imageSize..<(data.count-60)).write(to:mp4)
                let duration = try await AVURLAsset(url:mp4).load(.duration).seconds
                XCTAssertEqual(duration,2,accuracy:0.08)
            } else if format == .gif {
                let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL,nil))
                XCTAssertEqual(CGImageSourceGetCount(image),30)
            } else {
                let data = try Data(contentsOf:output)
                XCTAssertEqual(String(data:data.prefix(4),encoding:.ascii),"RIFF")
                XCTAssertNotNil(data.range(of:Data("ANIM".utf8)))
                XCTAssertNotNil(data.range(of:Data("ANMF".utf8)))
            }
        }
    }
}
