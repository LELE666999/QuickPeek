from pathlib import Path
import subprocess, sys, tempfile
source=Path(sys.argv[1] if len(sys.argv)>1 else 'QuickPeek/QuickPeek/PreviewWindow.swift').read_text()
def function(name):
    start=source.index('    private func '+name)
    end=source.find('\n    private func ', start+1)
    if end<0: raise ValueError(name)
    return source[start:end].split('\n    @ViewBuilder')[0]
label_start=source.index('    private func toolbarLabel')
label=source[label_start:source.index('    @ViewBuilder\n    private var conversionOverlay',label_start)]
fixture=r'''
struct ToolbarFixture: View {
    let compact: Bool
    let menu: Bool
    let isConverting = false
    let canResizeExport = false
    let fg = Color.primary
    let neutralCapsuleTint = Color.gray.opacity(0.2)
    let neutralCapsuleStroke = Color.gray.opacity(0.3)
    enum Format: Hashable { case mp4; var menuLabel: String { "MP4" } }
    let availableExportFormats: [Format] = [.mp4]
    func exportResizedMedia() {}
    func exportWithFFmpeg(target: Format) {}
    func exportMenu() -> NSMenu { NSMenu() }
    func showToolbarMenu(_ menu: NSMenu) {}
    var body: some View {
        if menu { conversionMenu(compact: compact) }
        else { neutralToolButton("画面裁剪", icon: "crop", compact: compact) {} }
    }
'''
test=r'''
MainActor.assumeIsolated {
    for compact in [false, true] {
        let button = NSHostingView(rootView: ToolbarFixture(compact: compact, menu: false))
        let menu = NSHostingView(rootView: ToolbarFixture(compact: compact, menu: true))
        let buttonSize = button.fittingSize
        let menuSize = menu.fittingSize
        print("compact=\(compact): button=\(buttonSize), menu=\(menuSize)")
        if abs(buttonSize.height - menuSize.height) > 0.5 || menuSize.height < 36 {
            print("FAIL: menu capsule does not match button height")
            exit(1)
        }
        precondition(menuSize.width >= 42)
    }
    print("PASS: actual SwiftUI menu and action capsules have equal 36pt height in both label modes")
}
'''
with tempfile.TemporaryDirectory() as directory:
    script=Path(directory)/'main.swift'
    script.write_text('import SwiftUI\nimport AppKit\n'+fixture+function('neutralToolButton')+function('conversionMenu')+label+'}\n'+test)
    subprocess.run(['swift', str(script)],check=True)
