from pathlib import Path
import subprocess, tempfile
s=Path('QuickPeek/QuickPeek/VideoTrimView.swift').read_text()
enum=s[s.index('enum VideoSelectionEdit:'):s.index('struct VideoTrimView:')]
start=s.index('                let asset = AVURLAsset(url: fileURL)',s.index('private func saveTrimed'))
end=s.index('                if FileManager.default.fileExists(atPath: outputURL.path)',start)
export=s[start:end]
test=r'''
@main struct Test {
 static func main() async throws {
    precondition(VideoSelectionEdit.keep.ranges(duration: 6, start: 2, end: 4) == [2...4])
    precondition(VideoSelectionEdit.remove.ranges(duration: 6, start: 2, end: 4) == [0...2,4...6])
    precondition(VideoSelectionEdit.remove.ranges(duration: 6, start: 0, end: 6).isEmpty)
    precondition(VideoSelectionEdit.keep.ranges(duration: 6, start: 4, end: 2).isEmpty)
    let fileURL = URL(fileURLWithPath: "/tmp/quickpeek-edit-test/source.mp4")
    let before = try Data(contentsOf: fileURL)
    for (index, sample) in [(VideoSelectionEdit.keep, 2.0, 4.0, 2.0), (.remove, 2.0, 4.0, 4.0), (.remove, 0.0, 2.0, 4.0), (.remove, 4.0, 6.0, 4.0)].enumerated() {
        let ranges = sample.0.ranges(duration: 6, start: sample.1, end: sample.2)
        let temp = URL(fileURLWithPath: "/tmp/quickpeek-edit-test/result-\(index).mp4")
        try? FileManager.default.removeItem(at: temp)
        EXPORT
        let result = AVURLAsset(url: temp)
        let duration = try await result.load(.duration).seconds
        precondition(abs(duration - sample.3) < 0.1, "Incorrect output duration")
        let video = try await result.loadTracks(withMediaType: .video)
        let audio = try await result.loadTracks(withMediaType: .audio)
        precondition(video.count == 1 && audio.count == 1, "Both picture and sound must survive")
        print("PASS export \(index): \(duration)s, video + audio")
    }
    precondition(try Data(contentsOf: fileURL) == before)
    print("PASS: source unchanged, whole-file deletion rejected")
 }
}
'''.replace('EXPORT',export).replace('precondition(try Data(contentsOf: fileURL) == before)','let after = try Data(contentsOf: fileURL)\n    precondition(after == before)')
with tempfile.TemporaryDirectory() as directory:
 p=Path(directory)/'test.swift';p.write_text('import Foundation\nimport AVFoundation\n'+enum+test)
 binary=Path(directory)/'test'
 subprocess.run(['swiftc','-parse-as-library',str(p),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
