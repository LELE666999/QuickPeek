from pathlib import Path
import subprocess
import tempfile

source = Path('QuickPeek/QuickPeek/PreviewWindow.swift').read_text()
navigation = source[source.index('struct PreviewScrollNavigation {'):source.index('/// Shared zoom state')]
zoom = source[source.index('@MainActor\nfinal class ZoomState:'):source.index('/// NSViewRepresentable wrapper for the gesture overlay')]
test = r'''
final class TestPinchEvent: NSEvent {
    var targetWindow: NSWindow?
    override var type: NSEvent.EventType { .magnify }
    override var window: NSWindow? { targetWindow }
    override var locationInWindow: NSPoint { NSPoint(x:300,y:200) }
    override var magnification: CGFloat { 0.5 }
    override var phase: NSEvent.Phase { .ended }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
MainActor.assumeIsolated {
    var nav = PreviewScrollNavigation()
    precondition(nav.direction(deltaX: 40, deltaY: 5, time: 1, began: true, momentum: false) == nil)
    precondition(nav.direction(deltaX: 0, deltaY: -20, time: 1.01, began: false, momentum: false) == nil)
    precondition(nav.direction(deltaX: 0, deltaY: -20, time: 1.02, began: false, momentum: false) == 1)
    precondition(nav.direction(deltaX: 0, deltaY: -100, time: 1.03, began: false, momentum: false) == nil)
    precondition(nav.direction(deltaX: 0, deltaY: -100, time: 1.04, began: false, momentum: true) == nil)
    precondition(nav.direction(deltaX: 0, deltaY: 40, time: 2, began: true, momentum: false) == -1)
    var nextPageNav = PreviewScrollNavigation()
    precondition(nextPageNav.direction(deltaX: 0, deltaY: -100, time: 2.1, began: false, momentum: true) == nil)

    let state = ZoomState()
    state.containerSize = CGSize(width: 600, height: 400)
    let view = ZoomableNSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    view.zoomState = state
    var pages: [Int] = []
    view.onNavigate = { pages.append($0) }
    func scroll(_ x: Int32, _ y: Int32) {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
        view.scrollWheel(with: NSEvent(cgEvent: cg)!)
    }
    scroll(0, -60)
    precondition(state.scale == 1 && state.offset == .zero)
    precondition(pages == [1], "Fitted image must navigate without zooming")
    state.zoom(by: 2, anchor: CGPoint(x: 300, y: 200))
    scroll(35, -45)
    precondition(state.scale == 2 && state.offset.width != 0 && state.offset.height != 0)
    precondition(pages == [1], "Magnified scroll must pan, not navigate")
    scroll(10000, -10000)
    precondition(abs(state.offset.width) <= 300 && abs(state.offset.height) <= 200)
    state.zoom(to: 1, anchor: CGPoint(x: 300, y: 200))
    precondition(state.offset == .zero)
    state.zoom(to: 100, anchor: .zero)
    precondition(state.scale == 10)
    state.zoom(to: 0.01, anchor: .zero)
    precondition(state.scale == 0.1 && state.offset == .zero)
    state.reset(animated: false)
    let commandScroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 30, wheel2: 0, wheel3: 0)!
    commandScroll.flags = .maskCommand
    view.scrollWheel(with: NSEvent(cgEvent: commandScroll)!)
    precondition(state.scale > 1, "Command-scroll must zoom")
    let commandDown = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -30, wheel2: 0, wheel3: 0)!
    commandDown.flags = .maskCommand
    let previousScale = state.scale
    view.scrollWheel(with: NSEvent(cgEvent: commandDown)!)
    precondition(state.scale < previousScale)
    let app = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView!.addSubview(view)
    let recognizer = window.contentView!.gestureRecognizers.compactMap { $0 as? NSMagnificationGestureRecognizer }.first!
    state.reset(animated: false)
    recognizer.magnification = 0.5
    precondition(app.sendAction(recognizer.action!, to: recognizer.target, from: recognizer))
    precondition(abs(state.scale - 1.5) < 0.001, "Native pinch action must reach the zoom state")
    precondition(recognizer.magnification == 0, "Consume the incremental pinch delta exactly once")
    view.passesClicksThrough = true
    precondition(view.hitTest(CGPoint(x: 30, y: 30)) == nil, "Video buttons must stay reachable")
    state.reset(animated:false)
    let pinchEvent=TestPinchEvent();pinchEvent.targetWindow=window
    precondition(view.routePreviewEvent(pinchEvent) === pinchEvent,"Let AppKit deliver magnify to its recognizer")
    precondition(state.scale == 1,"Event routing must not apply a second zoom")
    precondition(view.gestureRecognizer(recognizer,shouldAttemptToRecognizeWith:pinchEvent),"Never reject the actual magnification event")
    view.magnify(with:pinchEvent)
    precondition(abs(state.scale-1.5)<0.001,"Responder fallback must zoom without Command")
    view.stopMonitoring()
    precondition(window.contentView!.gestureRecognizers.isEmpty, "Detach the window gesture when preview closes")
    window.close()
    print("PASS: Command-scroll both directions, attached native magnification action, recognizer cleanup")
    print("PASS: default paging, gesture threshold, momentum filtering, two-axis pan, bounds, reset, scale limits, video click passthrough")
}
'''
with tempfile.TemporaryDirectory() as directory:
    script = Path(directory) / 'main.swift'
    script.write_text('import AppKit\nimport SwiftUI\n' + navigation + zoom + test)
    subprocess.run(['swift', str(script)], check=True)
