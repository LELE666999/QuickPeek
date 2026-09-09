import XCTest
@testable import QuickPeekTimeline
final class EditingTests: XCTestCase {
 func testLinkedCutsAndBatchUndo() {
  var e = TimelineEdits(duration: 10, fps: 30, hasAudio: true)
  for time in [2.0, 4, 6, 8] { e.split(at: time) }
  XCTAssertEqual(e.state.timeline.tracks[0].segments.count, 5)
  XCTAssertEqual(e.state.timeline.tracks[1].segments.count, 5)
  let video = e.state.timeline.tracks[0].segments
  e.select(video[1].id); e.select(video[3].id, additive: true)
  XCTAssertEqual(e.state.selection.count, 4)
  let before = e.state
  e.deleteSelection(ripple: true)
  XCTAssertEqual(e.duration, 6, accuracy: 0.001)
  XCTAssertEqual(e.state.timeline.tracks[0].segments.map { $0.sourceRange!.start }, [0,4,8])
  XCTAssertEqual(e.state.timeline.tracks[1].segments.map { $0.sourceRange!.start }, [0,4,8])
  e.undo(); XCTAssertEqual(e.state, before)
  e.redo(); XCTAssertEqual(e.duration, 6, accuracy: 0.001)
 }
 func testUnlinkAndAudioOnlyDelete() {
  var e = TimelineEdits(duration: 10, fps: 30, hasAudio: true)
  e.split(at: 5)
  let video = e.state.timeline.tracks[0].segments[0]
  e.select(video.id); e.unlinkSelection()
  let audio = e.state.timeline.tracks[1].segments[0]
  e.select(audio.id); XCTAssertEqual(e.state.selection.count, 1)
  e.deleteSelection(ripple: false)
  XCTAssertEqual(e.state.timeline.tracks[0].segments.count, 2)
  XCTAssertEqual(e.state.timeline.tracks[1].segments.count, 1)
  XCTAssertEqual(e.duration, 10)
  e.undo(); e.undo(); e.select(video.id)
  XCTAssertEqual(e.state.selection.count, 2)
 }
 func testBoundariesAndMoveTrim() {
  var e = TimelineEdits(duration: 10, fps: 30, hasAudio: false)
  e.split(at: 0); e.split(at: 10)
  XCTAssertFalse(e.canUndo)
  e.split(at: 2)
  let id = e.state.timeline.tracks[0].segments[1].id
  e.select(id); e.trimSelected(edge: .start, to: 3)
  XCTAssertEqual(e.state.timeline.tracks[0].segments[1].sourceRange!.start, 3)
  e.moveSelection(by: -100)
  XCTAssertEqual(e.state.timeline.tracks[0].segments[1].targetRange.start, 3, "Overlapping move rejected")
  e.undo(); XCTAssertEqual(e.state.timeline.tracks[0].segments[1].sourceRange!.start, 2)
 }
    func testRulerSplitOutsideSelectionAndSerialization() throws {
        var e=TimelineEdits(duration:10,fps:24,hasAudio:true)
        e.split(at:2)
        e.select(e.state.timeline.tracks[0].segments[0].id)
        e.split(at:7.1)
        XCTAssertEqual(e.state.timeline.tracks[0].segments.count,3)
        XCTAssertEqual(e.state.timeline.tracks[1].segments.count,3)
        let project=TimelineProject(sourceURL:URL(fileURLWithPath:"/tmp/source.mp4"),edits:e)
        let decoded=try JSONDecoder().decode(TimelineProject.self,from:JSONEncoder().encode(project))
        XCTAssertEqual(decoded.state,e.state)
        XCTAssertEqual(decoded.fps,24)
    }
    func testSilentSourceUsesDefaultRipplePolicy() {
        var e=TimelineEdits(duration:6,fps:30,hasAudio:false)
        e.split(at:2);e.split(at:4)
        e.select(e.state.timeline.tracks[0].segments[1].id)
        XCTAssertFalse(e.hasDetachedSelection)
        e.deleteSelection(ripple: !e.hasDetachedSelection)
        XCTAssertEqual(e.duration,4,accuracy:0.001)
        XCTAssertEqual(e.state.timeline.tracks[0].segments[1].targetRange.start,2,accuracy:0.001)
    }
    func testMagneticMoveClosesSmallGapAndClampsOverlap() {
        var e=TimelineEdits(duration:10,fps:30,hasAudio:true)
        e.split(at:4)
        let id=e.state.timeline.tracks[0].segments[1].id
        e.select(id);e.trimSelected(edge:.start,to:4.2)
        let before=e.state
        let delta=e.magneticMoveDelta(by:-0.17,tolerance:0.08)
        e.moveSelection(by:delta)
        XCTAssertEqual(e.state.timeline.tracks[0].segments[1].targetRange.start,4,accuracy:0.0001)
        XCTAssertEqual(e.state.timeline.tracks[1].segments[1].targetRange.start,4,accuracy:0.0001)
        e.undo();XCTAssertEqual(e.state,before)
        e.moveSelection(by:e.magneticMoveDelta(by:-1,tolerance:0.08))
        XCTAssertEqual(e.state.timeline.tracks[0].segments[1].targetRange.start,4,accuracy:0.0001)
    }
    func testRippleTrimClosesGapInOneUndo() {
        var e=TimelineEdits(duration:10,fps:30,hasAudio:true)
        e.split(at:4)
        e.select(e.state.timeline.tracks[0].segments[0].id)
        let before=e.state
        e.trimSelected(edge:.end,to:3,ripple:true)
        XCTAssertEqual(e.duration,9,accuracy:0.001)
        for track in e.state.timeline.tracks {
            XCTAssertEqual(track.segments[1].targetRange.start,3,accuracy:0.001)
        }
        e.undo();XCTAssertEqual(e.state,before)
    }
    func testRippleTrimRestoresFootageAndPushesFollowingClips() {
        var e=TimelineEdits(duration:10,fps:30,hasAudio:true)
        e.split(at:4);e.select(e.state.timeline.tracks[0].segments[0].id)
        e.trimSelected(edge:.end,to:3,ripple:true)
        let shortened=e.state
        e.trimSelected(edge:.end,to:3.5,ripple:true)
        XCTAssertEqual(e.duration,9.5,accuracy:0.001)
        for track in e.state.timeline.tracks {
            XCTAssertEqual(track.segments[0].targetRange.end,3.5,accuracy:0.001)
            XCTAssertEqual(track.segments[1].targetRange.start,3.5,accuracy:0.001)
        }
        e.undo();XCTAssertEqual(e.state,shortened)
        e.select(e.state.timeline.tracks[0].segments[1].id)
        e.trimSelected(edge:.start,to:3.5,ripple:true)
        XCTAssertEqual(e.duration,8.5,accuracy:0.001)
        e.trimSelected(edge:.start,to:2.5,ripple:true)
        XCTAssertEqual(e.duration,9,accuracy:0.001)
    }
    func testMagneticEdgeAtFractionalMediaEndHasNoGap() {
        var e=TimelineEdits(duration:6.01,fps:30,hasAudio:true)
        e.split(at:3);e.select(e.state.timeline.tracks[0].segments[0].id)
        let delta=e.magneticMoveDelta(by:6.04,tolerance:0.08)
        e.moveSelection(by:delta,snapToFrame:false)
        for track in e.state.timeline.tracks {
            XCTAssertEqual(track.segments[0].targetRange.end,track.segments[1].targetRange.start,accuracy:0.000001)
        }
    }
}
