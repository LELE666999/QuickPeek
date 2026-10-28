import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers

struct FontSpecimenView: View {
    let url: URL
    @State private var faces: [CTFontDescriptor] = []
    @State private var face = 0
    @State private var size = 36.0
    @State private var custom = "The quick brown fox jumps over the lazy dog. 0123456789"
    @State private var characters: [UInt32] = []
    @State private var page = 0
    @State private var showGlyphs = false
    private var font: CTFont? { faces.indices.contains(face) ? CTFontCreateWithFontDescriptor(faces[face],size,nil) : nil }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            if let font {
                HStack {
                    Text(CTFontCopyFullName(font) as String).font(.title2.bold()).lineLimit(2)
                    Spacer()
                    Text("\(characters.count) 个字符").foregroundStyle(.secondary)
                }
                if faces.count > 1 {
                    Picker("字重 / 字体",selection:$face) {
                        ForEach(faces.indices,id:\.self) { i in
                            Text(CTFontCopyFullName(CTFontCreateWithFontDescriptor(faces[i],16,nil)) as String).tag(i)
                        }
                    }
                }
                HStack {
                    Text("字号"); Slider(value:$size,in:16...96).frame(maxWidth:240)
                    Text("\(Int(size)) pt").monospacedDigit().frame(width:60)
                    Spacer()
                    Toggle("字符表",isOn:$showGlyphs).toggleStyle(.switch)
                }
                if showGlyphs {
                    HStack {
                        Button("上一页") { page -= 1 }.disabled(page == 0)
                        Text("\(page+1) / \(max(1,(characters.count+127)/128))").monospacedDigit()
                        Button("下一页") { page += 1 }.disabled((page+1)*128 >= characters.count)
                    }
                    ScrollView {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:72))],spacing:18) {
                            ForEach(Array(characters.dropFirst(page*128).prefix(128)),id:\.self) { code in
                                VStack(spacing:6) {
                                    Text(String(UnicodeScalar(code)!)).font(Font(font as NSFont)).frame(height:70)
                                    Text(String(format:"U+%04X",code)).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                                }.frame(maxWidth:.infinity).textSelection(.enabled)
                            }
                        }.padding(.vertical,8)
                    }
                } else {
                    TextField("输入文字试字",text:$custom).textFieldStyle(.roundedBorder)
                    ScrollView {
                        VStack(alignment:.leading,spacing:24) {
                            sample("自定义试字",custom,font)
                            sample("大写英文","ABCDEFGHIJKLMNOPQRSTUVWXYZ",font)
                            sample("小写英文","abcdefghijklmnopqrstuvwxyz",font)
                            sample("数字","0123456789",font)
                            sample("符号","!@#$%^&*()_+-=[]{};:'\",.<>/?\\|~` €£¥©®™…—",font)
                            sample("中文","天地玄黄 宇宙洪荒 春风得意 山川湖海 汉字之美",font)
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,8)
                    }
                }
            } else {
                ContentUnavailableView("无法读取字体",systemImage:"textformat",description:Text("此字体可能已损坏或不受系统支持。"))
            }
        }.padding(24)
        .task(id:url) {
            faces = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
            face = 0; updateCharacters()
        }
        .onChange(of:face) { updateCharacters() }
    }
    private func updateCharacters() {
        page = 0
        guard let font else { characters = []; return }
        let set = CTFontCopyCharacterSet(font)
        var result: [UInt32] = []
        for plane: UInt8 in 0...16 where CFCharacterSetHasMemberInPlane(set,Int(plane)) {
            let start = max(32,UInt32(plane)*65536), end = min(0x10ffff,UInt32(plane)*65536+65535)
            for code in start...end where UnicodeScalar(code) != nil && CFCharacterSetIsLongCharacterMember(set,code) { result.append(code) }
        }
        characters = result
    }
    private func sample(_ title: String, _ text: String, _ font: CTFont) -> some View {
        let set = CTFontCopyCharacterSet(font)
        let supported = String(String.UnicodeScalarView(text.unicodeScalars.filter { CFCharacterSetIsLongCharacterMember(set,$0.value) || CharacterSet.whitespacesAndNewlines.contains($0) }))
        let missing = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CFCharacterSetIsLongCharacterMember(set,$0.value) }.count
        return VStack(alignment:.leading,spacing:8) {
            Text(title + (missing > 0 ? " · \(missing) 个字符未收录" : "")).font(.system(size:12)).foregroundStyle(.secondary)
            Text(supported.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "此字体未收录这些字符" : supported)
                .font(supported.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? .body : Font(font as NSFont))
                .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
        }
    }
}

enum FontSubsetExporter {
    static let defaultCharacters = String((32...126).compactMap { UnicodeScalar($0).map(Character.init) }) + "‘’“”–—…•·©®™€£¥¢°±×÷‰"
    static func run(source: URL, destination: URL, characters: String) async throws -> String {
        guard let script = Bundle.main.url(forResource:"font_subset",withExtension:"py") else { throw NSError(domain:"找不到字体提取工具",code:1) }
        return try await Task.detached(priority:.userInitiated) {
            let candidates = ["/Library/Frameworks/Python.framework/Versions/3.13/bin/python3","/opt/homebrew/bin/python3","/usr/local/bin/python3","/usr/bin/python3"]
            var python: String?
            for candidate in candidates where FileManager.default.isExecutableFile(atPath:candidate) {
                let probe = Process(); probe.executableURL = URL(fileURLWithPath:candidate)
                probe.arguments = ["-c","import fontTools.subset"]
                probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
                try probe.run(); probe.waitUntilExit()
                if probe.terminationStatus == 0 { python = candidate; break }
            }
            guard let python else { throw NSError(domain:"需要 Python fontTools 才能提取字体字符",code:1) }
            let text = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try characters.write(to:text,atomically:true,encoding:.utf8)
            defer { try? FileManager.default.removeItem(at:text) }
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath:python)
            process.arguments = [script.path,source.path,destination.path,text.path]
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let message = String(data:data,encoding:.utf8) ?? ""
            guard process.terminationStatus == 0 else { throw NSError(domain:"QuickPeek.FontSubset",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            return "已提取并校验字体字符，保存为 \(destination.lastPathComponent)。"
        }.value
    }
}
