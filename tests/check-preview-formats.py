#!/usr/bin/env python3
"""Exercise the production format catalog, FFmpeg discovery and argument builder."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'QuickPeek/QuickPeek/PreviewWindow.swift').read_text()
enum=s[s.index('private enum ExportFormat:'):s.index('private struct ConversionStatus')].replace('private enum','enum')
support=s[s.index('@MainActor\nfinal class FFmpegSupport'):s.index('/// NSViewRepresentable wrapper for WKWebView')]
args=s[s.index('    private func ffmpegArguments('):s.index('    private func loadData()',s.index('    private func ffmpegArguments('))].replace('private func','func')
program='import Foundation\nimport AppKit\nimport UniformTypeIdentifiers\nimport ImageIO\n'+enum+support+'struct Arguments {\n'+args+'}\n'+r'''
@main struct Check {
 @MainActor static func main() throws {
  let support=FFmpegSupport.shared
  precondition(support.versionOutput.hasPrefix("ffmpeg version"))
  let ff=try unwrap(support.ffmpegURL)
  let root=URL(fileURLWithPath:"/tmp/quickpeek-edit-test/preview-formats")
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let source="/tmp/quickpeek-edit-test/source.mp4"
  for format in ExportFormat.allCases where ![.png,.jpg,.heic,.tiff,.bmp,.webp].contains(format) {
   let output=root.appendingPathComponent("export."+format.fileExtension)
   let process=Process(); process.executableURL=ff
   process.arguments=["-hide_banner","-loglevel","error","-nostdin"]+Arguments().ffmpegArguments(inputPath:source,outputPath:output.path,target:format)
   try process.run();process.waitUntilExit()
   precondition(process.terminationStatus == 0,format.rawValue)
   precondition((try! Data(contentsOf:output)).count > 0)
   print("PASS conversion: \(format.menuLabel)")
  }
  let image=NSImage(size:NSSize(width:80,height:60),flipped:false) { rect in NSColor.red.setFill();rect.fill();return true }
  let cg=try unwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
  for format in [ExportFormat.png,.jpg,.heic,.tiff,.bmp] {
   let data=NSMutableData()
   let encoder=try unwrap(CGImageDestinationCreateWithData(data,format.contentType.identifier as CFString,1,nil))
   CGImageDestinationAddImage(encoder,cg,nil)
   precondition(CGImageDestinationFinalize(encoder))
   let decoded=try unwrap(CGImageSourceCreateWithData(data,nil))
   precondition(CGImageSourceGetCount(decoded)==1)
   print("PASS still image: \(format.menuLabel)")
  }
 }
 static func unwrap<T>(_ value:T?) throws -> T { guard let value else {throw NSError(domain:"Missing test value",code:1)};return value }
}
'''
with tempfile.TemporaryDirectory() as d:
    swift=Path(d)/'formats.swift';swift.write_text(program)
    binary=Path(d)/'check'
    subprocess.run(['swiftc','-parse-as-library',str(swift),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
