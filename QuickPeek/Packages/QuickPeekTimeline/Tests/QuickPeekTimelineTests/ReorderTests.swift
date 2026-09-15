import XCTest
@preconcurrency import AVFoundation
@testable import QuickPeekTimeline
final class ReorderTests: XCTestCase {
 func testReorderedExport() async throws {
  let source=URL(fileURLWithPath:"/tmp/quickpeek-edit-test/source.mp4")
  guard FileManager.default.fileExists(atPath:source.path) else {throw XCTSkip("Generate media fixtures first")}
  var e=TimelineEdits(duration:6,fps:30,hasAudio:true)
  e.split(at:2);e.split(at:4)
  let id=e.state.timeline.tracks[0].segments[0].id
  e.select(id);e.reorderSelection(draggedID:id,to:6)
  let composition=try await TimelineMedia.composition(url:source,state:e.state)
  let exporter=try XCTUnwrap(AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetHighestQuality))
  exporter.videoComposition=try await TimelineMedia.videoComposition(for:composition)
  exporter.audioMix=try await TimelineMedia.audioMix(for:composition)
  let output=URL(fileURLWithPath:"/tmp/quickpeek-edit-test/timeline-reordered.mp4")
  try? FileManager.default.removeItem(at:output)
  try await exporter.export(to:output,as:.mp4)
  let duration=try await AVURLAsset(url:output).load(.duration).seconds
  XCTAssertEqual(duration,6,accuracy:0.05)
 }
 func testDetachedAudioConflictDoesNotPartiallyReorder() {
  var e=TimelineEdits(duration:6,fps:30,hasAudio:true)
  e.split(at:2);e.split(at:4)
  let clips=e.state.timeline.tracks[0].segments
  e.select(clips[0].id);e.unlinkSelection()
  e.select(clips[1].id)
  let before=e.state
  XCTAssertNil(e.reorderSelection(draggedID:clips[1].id,to:0))
  XCTAssertEqual(e.state,before)
 }
 func testLinkedReorderAndUndo() {
  var e = TimelineEdits(duration:6,fps:30,hasAudio:true)
  e.split(at:2); e.split(at:4)
  let id=e.state.timeline.tracks[0].segments[0].id
  e.select(id); let before=e.state
  XCTAssertEqual(e.reorderSelection(draggedID:id,to:6),4)
  for t in e.state.timeline.tracks {
   XCTAssertEqual(t.segments.map{$0.sourceRange!.start},[2,4,0])
   XCTAssertEqual(t.segments.map{$0.targetRange.start},[0,2,4])
  }
  e.undo(); XCTAssertEqual(e.state,before)
  e.redo(); XCTAssertEqual(e.state.timeline.tracks[0].segments.last?.id,id)
  XCTAssertEqual(e.reorderSelection(draggedID:id,to:0),0)
  XCTAssertEqual(e.state.timeline.tracks[0].segments.map{$0.sourceRange!.start},[0,2,4])
 }
 func testBatchAndDetachedAudio() {
  var e=TimelineEdits(duration:8,fps:30,hasAudio:true)
  for t in [2.0,4,6] {e.split(at:t)}
  e.selectAll(); e.unlinkSelection()
  let audio=e.state.timeline.tracks[1]
  let v=e.state.timeline.tracks[0].segments
  e.select(v[1].id);e.select(v[3].id,additive:true)
  XCTAssertEqual(e.reorderSelection(draggedID:v[1].id,to:0),0)
  XCTAssertEqual(e.state.timeline.tracks[0].segments.map{$0.sourceRange!.start},[2,6,0,4])
  XCTAssertEqual(e.state.timeline.tracks[1],audio)
 }
}
