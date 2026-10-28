import AppKit
import PDFKit

@MainActor
enum DocumentExport {
    static func imageData(_ image: NSImage, jpeg: Bool) throws -> Data {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.9] : [:]) else {
            throw DocumentToolError("图片编码失败。")
        }
        return data
    }
    static func text(pages: [DocumentPageText], format: String, to url: URL) throws {
        if format == "csv" {
            // UTF-8 BOM lets Excel recognize Chinese without an import wizard.
            func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            var csv = "\u{FEFF}页码,行号,文字\r\n"
            for page in pages { for (i, line) in page.text.components(separatedBy: .newlines).enumerated() {
                // Quoting alone does not prevent Excel formula execution.
                let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: { line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix($0) }) ? "'" + line : line
                csv += "\(page.page),\(i + 1),\(quoted(safe))\r\n"
            } }
            try Data(csv.utf8).write(to: url, options: .atomic)
        } else if format == "docx" {
            let attributed = NSMutableAttributedString()
            for page in pages {
                attributed.append(NSAttributedString(string: "第 \(page.page) 页\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
                attributed.append(NSAttributedString(string: page.text + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            }
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url, options: .atomic)
        } else {
            let text = pages.map { "第 \($0.page) 页\n\($0.text)" }.joined(separator: "\n\n────────\n\n")
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }
    static func summaryImage(title: String, body: String) throws -> NSImage {
        let width: CGFloat = 1200, inset: CGFloat = 72
        let style = NSMutableParagraphStyle(); style.lineSpacing = 9
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor(calibratedWhite: 0.14, alpha: 1), .paragraphStyle: style]
        let text = NSAttributedString(string: body, attributes: attributes)
        let bounds = text.boundingRect(with: NSSize(width: width - inset * 2, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        guard bounds.height < 24_000 else { throw DocumentToolError("结果太长，无法生成单张长图；请按章节处理或导出 Word / Markdown。") }
        let height = max(500, ceil(bounds.height) + 270)
        return NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: NSRect(x: inset, y: 50, width: 48, height: 6), xRadius: 3, yRadius: 3).fill()
            (title as NSString).draw(in: NSRect(x: inset, y: 83, width: width - inset * 2, height: 65), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 38), .foregroundColor: NSColor.black])
            text.draw(with: NSRect(x: inset, y: 170, width: width - inset * 2, height: bounds.height + 4), options: [.usesLineFragmentOrigin, .usesFontLeading])
            ("QuickPeek · AI 文档助手 · 请核对原文" as NSString).draw(at: NSPoint(x: inset, y: height - 50), withAttributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.gray])
            return true
        }
    }
    /// Extract JPEG/JPX streams directly, and decode common raw RGB/gray/CMYK image XObjects.
    /// Complex indexed color spaces and inline images are reported as unsupported instead of mis-exported.
    static func embeddedImages(document: PDFDocument, indices: [Int], folder: URL) throws -> (exported: Int, skipped: Int) {
        var exported = 0, skipped = 0
        func walk(_ resources: CGPDFDictionaryRef, page: Int, depth: Int) {
            guard depth < 10 else { return }
            var xObjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return }
            CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return true }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return true }
                if String(cString: subtype) == "Form" {
                    var nested: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dict, "Resources", &nested), let nested { walk(nested, page: page, depth: depth + 1) }
                } else if String(cString: subtype) == "Image" {
                    var mask: CGPDFObjectRef?
                    if CGPDFDictionaryGetObject(dict, "SMask", &mask) || CGPDFDictionaryGetObject(dict, "Mask", &mask) { skipped += 1; return true }
                    var width = 0, height = 0, bits = 0
                    _ = CGPDFDictionaryGetInteger(dict, "Width", &width); _ = CGPDFDictionaryGetInteger(dict, "Height", &height); _ = CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bits)
                    guard width > 0, height > 0, width <= 30_000, height <= 30_000, width * height <= 60_000_000 else { skipped += 1; return true }
                    var format = CGPDFDataFormat.raw
                    guard let bytes = CGPDFStreamCopyData(stream, &format) as Data? else { skipped += 1; return true }
                    var output: Data?, ext = "png"
                    if format == .jpegEncoded { output = bytes; ext = "jpg" }
                    else if format == .JPEG2000 { output = bytes; ext = "jp2" }
                    else if bits == 8 {
                        var name: UnsafePointer<CChar>?
                        if CGPDFDictionaryGetName(dict, "ColorSpace", &name), let name {
                            let spaceName = String(cString: name)
                            let channels = spaceName == "DeviceRGB" ? 3 : spaceName == "DeviceGray" ? 1 : spaceName == "DeviceCMYK" ? 4 : 0
                            if channels > 0, bytes.count >= width * height * channels {
                                let space = channels == 3 ? CGColorSpaceCreateDeviceRGB() : channels == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceCMYK()
                                if let provider = CGDataProvider(data: bytes as CFData), let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * channels, bytesPerRow: width * channels, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                                    output = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                                }
                            }
                        }
                    }
                    if let output {
                        let url = folder.appendingPathComponent(String(format: "page-%04d-image-%04d.%@", page + 1, exported + 1, ext))
                        do { try output.write(to: url, options: .atomic); exported += 1 } catch { skipped += 1 }
                    } else { skipped += 1 }
                }
                return true
            }, nil)
        }
        for index in indices {
            guard let page = document.page(at: index)?.pageRef else { continue }
            guard let dict = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources { walk(resources, page: index, depth: 0) }
        }
        return (exported, skipped)
    }
    static func powerPoint(controller: PDFDocumentController, indices: [Int]) throws {
        try controller.requireCopy()
        guard !indices.isEmpty else { throw DocumentToolError("请选择要导出的页面。") }
        guard let url = controller.saveURL(ext: "pptx", suffix: "-图片版") else { return }
        try writePowerPoint(document: controller.document!, indices: indices, to: url)
        controller.message = "已导出 PPTX，每张幻灯片为一张完整页面图片。"
    }
    static func writePowerPoint(document: PDFDocument, indices: [Int], to destination: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuickPeek-PPT-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ path: String, _ value: String) throws {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
        let officeNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pNS = "http://schemas.openxmlformats.org/presentationml/2006/main"
        let aNS = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let first = document.page(at: indices[0])!
        let size = PDFDocumentController.render(first, width: 1200).size
        let width = 9_144_000, height = Int(Double(9_144_000) * size.height / max(1, size.width))
        var slideIDs = "", relationships = "", contentTypes = ""
        let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        for (offset, index) in indices.enumerated() {
            guard let page = document.page(at: index) else { throw DocumentToolError("页面已发生变化。") }
            let n = offset + 1
            let image = PDFDocumentController.render(page, width: 1800)
            let imageURL = folder.appendingPathComponent("ppt/media/page\(n).png")
            try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try imageData(image, jpeg: false).write(to: imageURL)
            let scale = min(Double(width) / image.size.width, Double(height) / image.size.height)
            let cx = Int(image.size.width * scale), cy = Int(image.size.height * scale)
            let x = (width - cx) / 2, y = (height - cy) / 2
            try write("ppt/slides/slide\(n).xml", xml + "<p:sld xmlns:p=\"\(pNS)\" xmlns:a=\"\(aNS)\" xmlns:r=\"\(officeNS)\"><p:cSld><p:spTree>\(group)<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Page \(index + 1)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rId1\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
            try write("ppt/slides/_rels/slide\(n).xml.rels", xml + "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"rId1\" Type=\"\(officeNS)/image\" Target=\"../media/page\(n).png\"/><Relationship Id=\"rId2\" Type=\"\(officeNS)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/></Relationships>")
            slideIDs += "<p:sldId id=\"\(256 + n)\" r:id=\"rId\(n)\"/>"
            relationships += "<Relationship Id=\"rId\(n)\" Type=\"\(officeNS)/slide\" Target=\"slides/slide\(n).xml\"/>"
            contentTypes += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        try write("_rels/.rels", xml + "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"rId1\" Type=\"\(officeNS)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
        try write("ppt/presentation.xml", xml + "<p:presentation xmlns:p=\"\(pNS)\" xmlns:r=\"\(officeNS)\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rIdMaster\"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx=\"\(width)\" cy=\"\(height)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
        try write("ppt/_rels/presentation.xml.rels", xml + "<Relationships xmlns=\"\(relNS)\">\(relationships)<Relationship Id=\"rIdMaster\" Type=\"\(officeNS)/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/></Relationships>")
        let colors = "<a:dk1><a:srgbClr val=\"000000\"/></a:dk1><a:lt1><a:srgbClr val=\"FFFFFF\"/></a:lt1><a:dk2><a:srgbClr val=\"222222\"/></a:dk2><a:lt2><a:srgbClr val=\"EEEEEE\"/></a:lt2>" + (1...6).map { "<a:accent\($0)><a:srgbClr val=\"007AFF\"/></a:accent\($0)>" }.joined() + "<a:hlink><a:srgbClr val=\"007AFF\"/></a:hlink><a:folHlink><a:srgbClr val=\"800080\"/></a:folHlink>"
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\">\(fill)<a:prstDash val=\"solid\"/><a:miter lim=\"800000\"/></a:ln>"
        try write("ppt/theme/theme1.xml", xml + "<a:theme xmlns:a=\"\(aNS)\" name=\"QuickPeek\"><a:themeElements><a:clrScheme name=\"QuickPeek\">\(colors)</a:clrScheme><a:fontScheme name=\"System\"><a:majorFont><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"Default\"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst><a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>")
        try write("ppt/slideMasters/slideMaster1.xml", xml + "<p:sldMaster xmlns:p=\"\(pNS)\" xmlns:a=\"\(aNS)\" xmlns:r=\"\(officeNS)\"><p:cSld><p:spTree>\(group)</p:spTree></p:cSld><p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>")
        try write("ppt/slideMasters/_rels/slideMaster1.xml.rels", xml + "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"rId1\" Type=\"\(officeNS)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"\(officeNS)/theme\" Target=\"../theme/theme1.xml\"/></Relationships>")
        try write("ppt/slideLayouts/slideLayout1.xml", xml + "<p:sldLayout xmlns:p=\"\(pNS)\" xmlns:a=\"\(aNS)\" type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        try write("ppt/slideLayouts/_rels/slideLayout1.xml.rels", xml + "<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"rId1\" Type=\"\(officeNS)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>")
        try write("[Content_Types].xml", xml + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>\(contentTypes)</Types>")
        let zip = folder.appendingPathComponent("output.pptx")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folder; process.arguments = ["-q", "-r", zip.path, "[Content_Types].xml", "_rels", "ppt"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DocumentToolError("PPTX 打包失败。") }
        try Data(contentsOf: zip).write(to: destination, options: .atomic)
    }
}
