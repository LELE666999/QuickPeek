#!/usr/bin/env python3
"""Compile the production AppKit timeline with small host stubs; exercise real mouse/key handlers."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
pkg=root/'QuickPeek/Packages/QuickPeekTimeline'
subprocess.run(['swift','build','--package-path',str(pkg)],check=True)
build=pkg/'.build/arm64-apple-macosx/debug'
source=(root/'QuickPeek/QuickPeek/TimelineEditorView.swift').read_text()
source=source.replace('Library/Logs/QuickPeek/editor-errors.log','Library/Logs/QuickPeek/tests/editor-errors.log').replace('private func continueEdgeScroll()', 'fileprivate func continueEdgeScroll()').replace('private var dragPreview:', 'fileprivate var dragPreview:').replace('_session = State(initialValue: TimelineEditorSession(url: fileURL))', '_session = State(initialValue: NativeSnapshotSession.shared!)').replace('.task { await session.load() }', '')
source+='''
@MainActor enum NativeSnapshotSession { static var shared: TimelineEditorSession? }
@MainActor final class TapSharedState {
    static let shared = TapSharedState()
    var timelineEditing = false
}
struct StableVideoPlayer: View {
    let player: AVPlayer
    var showsPlaybackControls: Bool = true
    var body: some View { Color.black }
}
@main struct NativeTimelineTest {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let session = TimelineEditorSession(url:URL(fileURLWithPath:"/tmp/quickpeek-edit-test/source.mp4"))
        session.edits = TimelineEdits(duration:6,fps:30,hasAudio:true)
        let savePanel=session.makeExportPanel()
        precondition(savePanel.directoryURL == session.url.deletingLastPathComponent(),"Default export directory must be source directory")
        precondition(savePanel.nameFieldStringValue == "source_剪辑.mp4")
        session.report(NSError(domain:"AVFoundationErrorDomain",code:-11847,userInfo:[NSLocalizedDescriptionKey:"Operation Stopped",NSUnderlyingErrorKey:NSError(domain:"NSOSStatusErrorDomain",code:-12345)]),operation:"视频导出失败")
        precondition(session.errorTitle == "视频导出失败" && session.error!.contains("系统中止") && session.errorDetails.contains("-12345"))
        session.error=nil
        session.ready = true
        session.fitTimeline()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:200),styleMask:[.titled],backing:.buffered,defer:false)
        let scroll = TimelineScrollView(frame:NSRect(x:0,y:0,width:1000,height:200))
        let canvas = EditTimelineCanvas(); canvas.session = session
        scroll.documentView = canvas; window.contentView = scroll; scroll.resizeCanvas()
        func mouse(_ type:NSEvent.EventType,_ x:Double,_ y:Double,_ flags:NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:canvas.convert(NSPoint(x:x,y:y),to:nil),modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        func click(_ time:Double,_ y:Double=15,_ flags:NSEvent.ModifierFlags = []) {
            let x=16+time*canvas.scale
            canvas.mouseDown(with:mouse(.leftMouseDown,x,y,flags));canvas.mouseUp(with:mouse(.leftMouseUp,x,y,flags))
        }
        func key(_ value:String,_ flags:NSEvent.ModifierFlags,_ code:UInt16=11) {
            let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:value,charactersIgnoringModifiers:value,isARepeat:false,keyCode:code)!
            precondition(canvas.handle(event))
        }
        click(2);key("b",.control); click(4);key("b",.command)
        precondition(session.edits.state.timeline.tracks[0].segments.count == 3)
        click(1,60);click(5,60,.command)
        precondition(session.edits.state.selection.count == 4)
        key("",[],51)
        precondition(abs(session.edits.duration-2)<0.001)
        key("z",.command)
        precondition(session.edits.state.selection.count == 4)
        precondition(abs(session.edits.duration-6)<0.001)
        // Box-selection covers both tracks, including linked IDs.
        canvas.mouseDown(with:mouse(.leftMouseDown,20,175))
        canvas.mouseDragged(with:mouse(.leftMouseDragged,16+3*canvas.scale,40))
        canvas.mouseUp(with:mouse(.leftMouseUp,16+3*canvas.scale,40))
        precondition(session.edits.state.selection.count == 4)
        // Trim the first linked pair by dragging its left handle.
        canvas.mouseDown(with:mouse(.leftMouseDown,19,60))
        canvas.mouseDragged(with:mouse(.leftMouseDragged,19+0.5*canvas.scale,60))
        canvas.mouseUp(with:mouse(.leftMouseUp,19+0.5*canvas.scale,60))
        precondition(abs(session.edits.state.timeline.tracks[0].segments[0].sourceRange!.start-0.5)<0.001)
        precondition(abs(session.edits.state.timeline.tracks[1].segments[0].sourceRange!.start-0.5)<0.001)
        session.peaks=(0..<1600).map{Float(abs(sin(Double($0)*0.27)))}
        session.position=2.7
        canvas.needsDisplay=true
        if let bitmap=canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds) {
            canvas.cacheDisplay(in:canvas.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/quickpeek-timeline-native.png"))
        }
        // A dragging clip must visibly move before mouse-up, then snap exactly to its neighbor.
        let magnetic=TimelineEditorSession(url:session.url)
        magnetic.ready=true;magnetic.edits=TimelineEdits(duration:6,fps:30,hasAudio:true);magnetic.fitTimeline()
        magnetic.edits.split(at:2)
        let moving=magnetic.edits.state.timeline.tracks[0].segments[1].id
        magnetic.edits.select(moving);magnetic.edits.trimSelected(edge:.start,to:2.2)
        canvas.session=magnetic;scroll.resizeCanvas()
        let startX=16+3*canvas.scale
        canvas.mouseDown(with:mouse(.leftMouseDown,startX,60))
        canvas.mouseDragged(with:mouse(.leftMouseDragged,startX-0.17*canvas.scale,60))
        precondition(abs(canvas.dragPreview!.state.timeline.tracks[0].segments[1].targetRange.start-2)<0.001)
        precondition(abs(magnetic.edits.state.timeline.tracks[0].segments[1].targetRange.start-2.2)<0.001)
        canvas.mouseUp(with:mouse(.leftMouseUp,startX-0.17*canvas.scale,60))
        precondition(abs(magnetic.edits.state.timeline.tracks[0].segments[1].targetRange.start-2)<0.001)
        magnetic.edits.undo()
        precondition(abs(magnetic.edits.state.timeline.tracks[0].segments[1].targetRange.start-2.2)<0.001)
        let unchanged=magnetic.edits.state
        canvas.mouseDown(with:mouse(.leftMouseDown,startX,60))
        canvas.mouseDragged(with:mouse(.leftMouseDragged,startX+canvas.scale,60))
        canvas.mouseDragged(with:mouse(.leftMouseDragged,startX,60))
        canvas.mouseUp(with:mouse(.leftMouseUp,startX,60))
        precondition(magnetic.edits.state == unchanged,"Returning to origin must cancel movement")
        scroll.contentView.scroll(to:.zero)
        canvas.mouseDown(with:mouse(.leftMouseDown,400,60,.option))
        canvas.mouseDragged(with:mouse(.leftMouseDragged,300,60,.option))
        precondition(scroll.contentView.bounds.origin.x>90,"Option drag must pan the timeline")
        canvas.mouseUp(with:mouse(.leftMouseUp,300,60,.option))
        scroll.contentView.scroll(to:.zero)
        canvas.mouseDown(with:mouse(.leftMouseDown,startX,60))
        canvas.mouseDragged(with:mouse(.leftMouseDragged,scroll.contentSize.width-10,60))
        canvas.continueEdgeScroll()
        precondition(scroll.contentView.bounds.origin.x>0,"Edge dragging must scroll even without another pointer event")
        canvas.mouseUp(with:mouse(.leftMouseUp,scroll.contentSize.width-10,60))
        scroll.contentView.scroll(to:.zero)
        magnetic.zoom=magnetic.zoomRange.lowerBound
        precondition(magnetic.visibleSeconds>=120,"Zoom out must extend beyond a minute")
        magnetic.zoom=0;scroll.resizeCanvas()
        precondition(abs(magnetic.visibleSeconds-60)<0.001)
        precondition(canvas.frame.width>scroll.contentSize.width)
        magnetic.zoom=log2(60);scroll.resizeCanvas()
        precondition(abs(magnetic.visibleSeconds-1)<0.001)
        canvas.session=session;scroll.resizeCanvas();magnetic.cleanup()
        NativeSnapshotSession.shared=session
        let host=NSHostingView(rootView:TimelineEditorView(fileURL:session.url,onDone:{}).frame(width:860,height:650).background(Color(nsColor:.windowBackgroundColor)))
        host.frame=NSRect(x:0,y:0,width:860,height:650)
        host.appearance=NSAppearance(named:.darkAqua)
        window.setContentSize(host.frame.size);window.contentView=host
        host.layoutSubtreeIfNeeded()
        if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
            host.cacheDisplay(in:host.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/quickpeek-timeline-editor.png"))
        }
        let silent=TimelineEditorSession(url:session.url)
        silent.ready=true;silent.edits=TimelineEdits(duration:6,fps:30,hasAudio:false)
        silent.edits.split(at:2);silent.edits.split(at:4)
        silent.edits.select(silent.edits.state.timeline.tracks[0].segments[1].id)
        silent.delete()
        precondition(abs(silent.edits.duration-4)<0.001,"Silent session must ripple-delete by default")
        silent.cleanup()
        canvas.stopMonitoring();session.cleanup()
        print("PASS: native mouse positioning, Ctrl/Command B, linked multi-select, Delete, undo, box-select and linked handle trim")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='quickpeek-native-') as d:
    swift=Path(d)/'NativeTest.swift';swift.write_text(source)
    objects=list((build/'TimelineKitCore.build').glob('*.o'))+list((build/'QuickPeekTimeline.build').glob('*.o'))
    exe=Path(d)/'test'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6','-I',str(build/'Modules'),str(swift),*map(str,objects),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
