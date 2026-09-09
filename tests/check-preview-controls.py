from pathlib import Path
import subprocess, sys, tempfile
source = Path(sys.argv[1] if len(sys.argv) > 1 else 'QuickPeek/QuickPeek/PreviewWindow.swift').read_text()
player = source[source.index('final class HoverPlayerView:'):source.index('private struct DecodedImageAsset')]
test = r'''
MainActor.assumeIsolated {
    let view = HoverPlayerView(frame: NSRect(x: 0, y: 0, width: 480, height: 600))
    let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    for width in [280.0, 480.0, 900.0] {
        view.setFrameSize(NSSize(width: width, height: 600))
        for _ in 0..<10 {
            view.mouseEntered(with: event)
            if view.controlsStyle != .floating { print("FAIL: hover switched away from floating controls"); exit(1) }
            view.mouseExited(with: event)
            if view.controlsStyle != .floating { print("FAIL: hover destroyed the controls hierarchy"); exit(1) }
        }
        precondition(view.videoGravity == .resizeAspect)
        precondition(view.showsFullScreenToggleButton)
    }
    view.player = AVPlayer()
    let overlay = view.contentOverlayView!
    overlay.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
    view.previewScale = 2
    view.previewOffset = CGSize(width: 20, height: 30)
    view.updateZoomedVideo()
    let videoLayer = overlay.layer!.sublayers!.compactMap { $0 as? AVPlayerLayer }.first!
    precondition(videoLayer.frame == CGRect(x: -220, y: -330, width: 960, height: 1200))
    precondition(videoLayer.player === view.player && !videoLayer.isHidden)
    precondition(view.controlsStyle == .floating, "Zoom must not scale or rebuild the native control hierarchy")
    view.previewScale = 1
    view.previewOffset = .zero
    view.updateZoomedVideo()
    precondition(videoLayer.player == nil && videoLayer.isHidden)
    view.previewScale = 3
    view.updateZoomedVideo()
    view.clearZoomedVideo()
    precondition(videoLayer.player == nil)
    print("PASS: video layer zoom/pan geometry, native controls preserved, reset and player cleanup")
    print("PASS: floating control hierarchy survives 30 hover cycles at 280/480/900pt; aspect fit and full-screen retained")
}
'''
with tempfile.TemporaryDirectory() as directory:
    script=Path(directory)/'main.swift'
    script.write_text('import AppKit\nimport AVKit\n'+player+test)
    subprocess.run(['swift',str(script)], check=True)
