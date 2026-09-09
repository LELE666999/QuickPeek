from pathlib import Path
import subprocess
source = Path('QuickPeek/QuickPeek/PreviewWindow.swift').read_text()
section = source[source.index('final class CodeEditorTextView:'):source.index('// MARK: - Zoomable Content Wrapper')]
test = r'''
let sample = "<?xml version=\"1.0\"?>\r\n\t<!-- 中文注释 -->\r\n\t<View name=\"test\" count=\"42\" />\r\n"
let editor = CodeEditorView(text: .constant(sample), isDark: true, onSave: {})
let view = CodeEditorTextView()
view.string = sample
'''
# Exercise the production highlighting entry point once implemented; current editor has no syntax coloring.
if 'enum CodeSyntaxHighlighter' in source:
    test += 'let styled = CodeSyntaxHighlighter.highlight(sample, language: "xml", isDark: true)\n'
else:
    test += 'let styled = NSAttributedString(string: sample, attributes: [.foregroundColor: NSColor.white])\n'
test += r'''
func color(_ token: String) -> NSColor {
    styled.attribute(.foregroundColor, at: (sample as NSString).range(of: token).location, effectiveRange: nil) as! NSColor
}
precondition(styled.string == sample, "Source whitespace must remain exact")
precondition(color("View") != color("name"), "XML tags and attributes need distinct colors")
precondition(color("test") != color("name"), "XML strings need a distinct color")
precondition(color("中文注释") != color("View"), "Comments need a distinct color")

let coordinator = CodeEditorView.Coordinator(parent: editor)
coordinator.textView = view
view.setSelectedRange(NSRange(location: 5, length: 7))
coordinator.highlight()
precondition(view.string == sample && view.selectedRange() == NSRange(location: 5, length: 7), "Highlighting must preserve text and selection")
view.string = sample + "<Other value=\"你好\" />"
coordinator.highlight()
precondition(view.string.hasSuffix("<Other value=\"你好\" />"), "Rehighlight must preserve edits")
for dark in [true, false] {
    let code = "const url = \"https://example.com/#anchor\"; // comment with \"quotes\"\nreturn 42;"
    let styledCode = CodeSyntaxHighlighter.highlight(code, language: "js", isDark: dark)
    func c(_ token: String) -> NSColor {
        styledCode.attribute(.foregroundColor, at: (code as NSString).range(of: token).location, effectiveRange: nil) as! NSColor
    }
    precondition(c("https") == c("anchor"), "Comment markers inside a string must not start comments")
    precondition(c("comment") == c("quotes"), "Quotes inside a comment must not start strings")
    precondition(c("return") != c("42"), "Keywords and numbers need separate colors")
    precondition(styledCode.string == code)
}
for code in ["", "\t\n\r\n", "😀 中文 e\u{301}", String(repeating: sample, count: 1000)] {
    precondition(CodeSyntaxHighlighter.highlight(code, language: "xml", isDark: true).string == code)
}
print("PASS: XML/JS colors, light/dark themes, string/comment boundaries, selection, edits, empty/Unicode/large input and CRLF/tab preservation")

'''
Path('/tmp/quickpeek-editor-test.swift').write_text('import AppKit\nimport SwiftUI\n' + section + '\nMainActor.assumeIsolated {\n' + test + '\n}')
subprocess.run(['swift', '-swift-version', '5', '-Xfrontend', '-strict-concurrency=minimal', '/tmp/quickpeek-editor-test.swift'], check=True)
