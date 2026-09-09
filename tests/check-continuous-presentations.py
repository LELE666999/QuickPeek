from pathlib import Path
import subprocess, tempfile
s=Path('QuickPeek/QuickPeek/PreviewWindow.swift').read_text()
code=s[s.index('private final class PresentationPagesPDFView'):s.index('private struct PresentationPreview:')]
stub='''
@MainActor final class PresentationDocumentController: ObservableObject {
 @Published var currentPageIndex = 0
 let pageImages: [NSImage]
 init() { pageImages = (0..<3).map { _ in NSImage(size:NSSize(width:1600,height:900), flipped:false) { rect in NSColor.white.setFill(); rect.fill(); return true } } }
 func setCurrentPage(_ index:Int) { currentPageIndex = index }
}
'''
test='''
func findScroll(_ view:NSView) -> NSScrollView? {
 if let scroll = view as? NSScrollView {return scroll}
 for child in view.subviews {if let scroll = findScroll(child) {return scroll}}
 return nil
}
func findPDF(_ view:NSView) -> PDFView? {
 if let pdf = view as? PDFView { return pdf }
 for child in view.subviews { if let pdf = findPDF(child) {return pdf} }
 return nil
}
MainActor.assumeIsolated {
 _ = NSApplication.shared
 let controller = PresentationDocumentController()
 let host = NSHostingView(rootView:ContinuousPresentationPages(controller:controller))
 let window = NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:480),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
 window.isReleasedWhenClosed = false
 window.contentView = host
 host.layoutSubtreeIfNeeded()
 func settle() { RunLoop.main.run(until:Date().addingTimeInterval(0.25)); host.layoutSubtreeIfNeeded() }
 settle()
 let view = findPDF(host)!
 precondition(view.document?.pageCount == 3)
 precondition(view.displayMode == .singlePageContinuous && view.displayDirection == .vertical)
 let page = view.document!.page(at:0)!
 let origin = view.convert(page.bounds(for:.mediaBox), from:page).origin
 let event = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:-35,wheel2:0,wheel3:0)!
 findScroll(view)!.scrollWheel(with:NSEvent(cgEvent:event)!)
 settle()
 let moved = view.convert(page.bounds(for:.mediaBox), from:page).origin
 precondition(origin != moved, "Scrolling must move the document continuously")
 precondition(view.currentPage === page, "Small scroll must not hard-switch slides")
 let scale = view.scaleFactor
 event.flags = .maskCommand
 let up = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:35,wheel2:0,wheel3:0)!
 up.flags = .maskCommand
 view.scrollWheel(with:NSEvent(cgEvent:up)!)
 precondition(view.scaleFactor > scale)
 controller.setCurrentPage(2); settle()
 precondition(view.currentPage === view.document!.page(at:2), "Sidebar must navigate to selected page")
 view.go(to:view.document!.page(at:1)!); settle()
 precondition(controller.currentPageIndex == 1, "Scroll position must synchronize sidebar")
 window.close()
 print("PASS: 3-page native viewport, continuous scrolling without hard cut, Command zoom, sidebar navigation and current-page synchronization")
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'main.swift';p.write_text('import AppKit\nimport SwiftUI\nimport PDFKit\n'+stub+code+test)
 subprocess.run(['swiftc',str(p),'-o',str(Path(d)/'test')],check=True)
 subprocess.run([str(Path(d)/'test')],check=True)
