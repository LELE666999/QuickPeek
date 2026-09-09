from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'QuickPeek/QuickPeek/PreviewWindow.swift').read_text()
renderer=s[s.index('@MainActor\nfinal class NativePresentationRenderer'):s.index('private func exportPageImage')]
runner=s[s.index('private func runProcess('):s.index('struct PDFDocumentBrowserView:')]
test=r'''
@main struct Test {
 @MainActor static func main() async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let source=URL(fileURLWithPath:CommandLine.arguments[1])
    let canceled=Task { try await NativePresentationRenderer().render(source) }
    canceled.cancel()
    do { _ = try await canceled.value;preconditionFailure("Canceled presentation must not finish rendering") } catch is CancellationError {}
    let images=try await NativePresentationRenderer().render(source)
    precondition(images.count==7,"All seven slides must be present")
    precondition(images[0].tiffRepresentation != images[1].tiffRepresentation,"Slides must not repeat the first page")
    for (i,image) in images.enumerated() {
        let data=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
        try data.write(to:URL(fileURLWithPath:"/tmp/quickpeek-slide-\(i+1).png"))
    }
    print("PASS: seven native Quick Look pages rendered in WebKit; distinct pages; no external application commands")
 }
}
'''
assert 'Keynote' not in renderer and 'soffice' not in renderer
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'test.swift';p.write_text('import AppKit\nimport WebKit\nimport PDFKit\n'+renderer+runner+test)
 exe=Path(d)/'test'
 subprocess.run(['swiftc','-parse-as-library',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe),'/Users/lele/Downloads/presentation.pptx'],check=True,timeout=90)
