import AppKit
import SwiftUI
import PDFKit
import WebKit

@main struct DocumentChecks {
    @MainActor static func main() async throws {
        func check(_ condition: Bool, _ message: String = "check failed") { if !condition { fatalError(message) } }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QP_DOC_TEST_ROOT"]!)
        let source = root.appendingPathComponent("stamp-fixture.pdf")
        let original = try Data(contentsOf: source)
        let controller = PDFDocumentController(fileURL: source)
        check(controller.pageCount == 3)
        check(controller.printOnlyAnnotationCount == 1)
        check(try PDFPageRange.parse("3,1-2,2", count: 3) == [2,0,1])
        for invalid in ["0","4","3-1","1,,2","-1","1-4","1-","a"] {
            do { _ = try PDFPageRange.parse(invalid, count: 3); fatalError("accepted invalid range \(invalid)") } catch {}
        }
        let image = PDFDocumentController.render(controller.document!.page(at: 0)!, width: 1000)
        try DocumentExport.imageData(image, jpeg: false).write(to: root.appendingPathComponent("native-stamp.png"))
        func coloredPixels(_ image: NSImage, channel: Int) -> Int {
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!; var count = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) { for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let v = [c.redComponent,c.greenComponent,c.blueComponent]
                if v[channel] > 0.55 && v[(channel+1)%3] < 0.35 && v[(channel+2)%3] < 0.35 { count += 1 }
            } }
            return count
        }
        check(coloredPixels(image,channel:0)>100,"stamp AP disappeared")
        check(coloredPixels(image,channel:1)>100,"signature AP disappeared")
        print("Native stamp pixels",coloredPixels(image,channel:0),coloredPixels(image,channel:1),coloredPixels(image,channel:2))
        let flattened = controller.document!.dataRepresentation(options: [PDFDocumentWriteOption.burnInAnnotationsOption:true])!
        let flatDoc = PDFDocument(data:flattened)!
        check(coloredPixels(PDFDocumentController.render(flatDoc.page(at:0)!),channel:0)>100)
        let text = try await controller.textPages(ocr: false)
        check(text.count==3 && text[0].text.contains("PAGE ONE"))
        try controller.rotatePages([0]);check(controller.document!.page(at:0)!.rotation==90)
        controller.undo();check(controller.document!.page(at:0)!.rotation==0)
        controller.redo();check(controller.document!.page(at:0)!.rotation==90)
        controller.undo();try controller.movePage(2,by:-2)
        check(controller.document!.page(at:0)!.string!.contains("LANDSCAPE"))
        controller.undo();try controller.deletePages([1]);check(controller.pageCount==2)
        controller.undo();check(controller.pageCount==3)
        check(try Data(contentsOf:source)==original,"editing overwrote original")
        try DocumentExport.text(pages:text,format:"docx",to:root.appendingPathComponent("test.docx"))
        try DocumentExport.text(pages:[.init(page:1,text:"=HYPERLINK(test)\n中文,数字\n1.23")],format:"csv",to:root.appendingPathComponent("test.csv"))
        check(try String(contentsOf:root.appendingPathComponent("test.csv"),encoding:.utf8).contains("'=HYPERLINK"))
        try DocumentExport.writePowerPoint(document:controller.document!,indices:[0,1,2],to:root.appendingPathComponent("test.pptx"))
        let encrypted = controller.document!.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption:"fixture-pass", PDFDocumentWriteOption.ownerPasswordOption:"owner-fixture"])!
        let encryptedDoc = PDFDocument(data:encrypted)!
        check(encryptedDoc.isLocked); check(!encryptedDoc.unlock(withPassword:"incorrect")); check(encryptedDoc.unlock(withPassword:"fixture-pass"))
        let poster = try DocumentExport.summaryImage(title:"全文总结",body:"文档结论与关键数据\n来源 [第 1 页]\n请核对原文。")
        try DocumentExport.imageData(poster,jpeg:false).write(to:root.appendingPathComponent("summary-poster.png"))
        let scanImage = NSImage(size:NSSize(width:900,height:280),flipped:false) { rect in
            NSColor.white.setFill();rect.fill()
            ("OCR DOCUMENT TEST 12345" as NSString).draw(at:NSPoint(x:40,y:150),withAttributes:[.font:NSFont.systemFont(ofSize:42),.foregroundColor:NSColor.black])
            return true
        }
        let scanPDF=PDFDocument();scanPDF.insert(PDFPage(image:scanImage)!,at:0)
        let scanURL=root.appendingPathComponent("scan.pdf");check(scanPDF.write(to:scanURL))
        let scanController=PDFDocumentController(fileURL:scanURL)
        let recognized=try await scanController.textPages();check(recognized.first!.text.contains("12345"),"local OCR failed")
        let extracted=root.appendingPathComponent("extracted");try FileManager.default.createDirectory(at:extracted,withIntermediateDirectories:true)
        let extractedCount=try DocumentExport.embeddedImages(document:scanPDF,indices:[0],folder:extracted)
        check(extractedCount.exported>0,"embedded image not extracted")
        let native = DocumentPDFView(frame:NSRect(x:0,y:0,width:750,height:700));native.document=controller.document;native.displayMode = .singlePageContinuous;native.autoScales=true
        controller.pdfView=native;controller.searchQuery="Second";controller.search();check(controller.searchResults.count==1)
        native.setCurrentSelection(controller.document!.page(at:0)!.selection(for:NSRange(location:0,length:9)),animate:false)
        try controller.annotate(.highlight);check(controller.document!.page(at:0)!.annotations.contains{$0.type=="Highlight"});controller.undo()
        var configuration = DocumentAIConfiguration(provider:.custom,baseURL:"http://127.0.0.1:\(ProcessInfo.processInfo.environment["QP_DOC_TEST_PORT"]!)",model:"fixture")
        check(try configuration.endpoint().path=="/chat/completions")
        let originalAccount=configuration.keyAccount;configuration.baseURL += "/v1";check(configuration.keyAccount != originalAccount)
        for value in ["http://example.com","https://user:password@host/v1","https://host/v1?api_key=secret","file:///tmp/a"] {
            var c=configuration;c.baseURL=value
            do { _=try c.endpoint();fatalError("invalid endpoint accepted") } catch {}
        }
        let port=ProcessInfo.processInfo.environment["QP_DOC_TEST_PORT"]!
        for path in ["", "/v1", "/error", "/redirect", "/length"] {
            configuration.baseURL="http://127.0.0.1:\(port)\(path)"
            let client=DocumentAIClient(configuration:configuration,key:"fixture-key")
            do {
                let result=try await client.complete(system:"fixture",prompt:"Document text fixture")
                check(path=="" || path=="/v1");check(result.contains("Fixture AI"))
            } catch {
                check(["/error","/redirect","/length"].contains(path),error.localizedDescription)
                check(!error.localizedDescription.contains("fixture-key"))
            }
        }
        let mimoConfiguration=DocumentAIConfiguration(provider:.mimo,baseURL:"http://127.0.0.1:\(port)/mimo",model:"fixture")
        _=try await DocumentAIClient(configuration:mimoConfiguration,key:"fixture-key").complete(system:"fixture",prompt:"MiMo header fixture")
        let pages=[DocumentPageText(page:1,text:String(repeating:"中文🦉",count:4200)),DocumentPageText(page:2,text:"FINAL_SENTINEL")]
        let chunks=DocumentAIText.chunks(pages);check(chunks.count>1 && chunks.joined().contains("FINAL_SENTINEL"));check(chunks.allSatisfy{$0.count<=9001})
        configuration.baseURL="http://127.0.0.1:\(port)"
        _=try await DocumentAIText.run(pages:pages,action:.summary,question:"",language:"中文",client:.init(configuration:configuration,key:"fixture-key")){_ in}
        print("PASS PDF edits, exports, AI errors and whole-document chunking")
        // Exercise exactly the shipped HTML/PDF.js with the production bridge, not a JavaScript mock.
        controller.isEdited=false;controller.usesCompatibilityRenderer=true
        let holder=NSHostingView(rootView:PDFCompatibilityView(controller:controller))
        let window=NSWindow(contentRect:NSRect(x:4000,y:4000,width:900,height:700),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=holder;window.orderFront(nil)
        func webView(in view:NSView)->WKWebView? {
            if let web=view as? WKWebView{return web}
            for child in view.subviews {if let found=webView(in:child){return found}}
            return nil
        }
        var web:WKWebView?
        var configuredHeadlessClock = false
        for _ in 0..<100 {
            try await Task.sleep(for:.milliseconds(100));web=webView(in:holder)
            if let web, !configuredHeadlessClock {
                // WebKit pauses rAF for offscreen windows. Use a deterministic clock only in this test harness.
                web.configuration.userContentController.addUserScript(WKUserScript(source: "window.requestAnimationFrame=cb=>setTimeout(()=>cb(performance.now()),0);window.cancelAnimationFrame=id=>clearTimeout(id);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
                configuredHeadlessClock = true; web.reload(); continue
            }
            if let web, (try? await web.evaluateJavaScript("Boolean(document.querySelector('#page-0')?._rendered)")) as? Bool == true {break}
        }
        guard let web else {fatalError("no compatibility web view")}
        try await Task.sleep(for:.seconds(2))
        let count=try await web.evaluateJavaScript("document.querySelectorAll('canvas').length") as? Int ?? 0
        if count==0 {
            let body = try await web.evaluateJavaScript("document.body.innerText")
            try ("COMPAT DIAGNOSTIC: " + controller.message + "\n" + String(describing:body)).write(to:root.appendingPathComponent("compat-diagnostic.txt"),atomically:true,encoding:.utf8)
            let snapshot=try await web.takeSnapshot(configuration:nil)
            try DocumentExport.imageData(snapshot,jpeg:false).write(to:root.appendingPathComponent("compat-failure.png"))
        }
        check(count>0,"PDF.js did not render offline")
        let snapshot=try await web.takeSnapshot(configuration:nil)
        try DocumentExport.imageData(snapshot,jpeg:false).write(to:root.appendingPathComponent("compat-stamp.png"))
        let png = try await web.evaluateJavaScript("document.querySelector('#page-0 canvas').toDataURL().split(',')[1]") as! String
        let compatPage = NSImage(data:Data(base64Encoded:png)!)!
        try Data(base64Encoded:png)!.write(to:root.appendingPathComponent("compat-page.png"))
        if coloredPixels(compatPage,channel:0)<=50 {
            let body = try await web.evaluateJavaScript("JSON.stringify({body:document.body.innerText,scrollY,canvases:[...document.querySelectorAll('canvas')].map(c=>({w:c.width,h:c.height,rect:c.getBoundingClientRect().toJSON()}))})")
            try (controller.message + "\n" + String(describing:body)).write(to:root.appendingPathComponent("compat-render-diagnostic.txt"),atomically:true,encoding:.utf8)
        }
        check(coloredPixels(compatPage,channel:0)>50,"compat stamp missing")
        check(coloredPixels(compatPage,channel:2)<30,"print-only stamp visible in display mode")
        controller.showPrintOnlyStamps=true
        holder.rootView=PDFCompatibilityView(controller:controller);holder.layoutSubtreeIfNeeded()
        for _ in 0..<60 {
            try await Task.sleep(for:.milliseconds(100))
            if (try? await web.evaluateJavaScript("document.getElementById('mode').textContent")) as? String == "PDF.js · 离线兼容 · 打印外观"{break}
        }
        try await Task.sleep(for:.seconds(2))
        let printed=try await web.takeSnapshot(configuration:nil)
        try DocumentExport.imageData(printed,jpeg:false).write(to:root.appendingPathComponent("compat-print.png"))
        let printPNG = try await web.evaluateJavaScript("document.querySelector('#page-0 canvas').toDataURL().split(',')[1]") as! String
        let printPage = NSImage(data:Data(base64Encoded:printPNG)!)!
        try Data(base64Encoded:printPNG)!.write(to:root.appendingPathComponent("compat-print-page.png"))
        if coloredPixels(printPage,channel:2)<=30 {
            let mode = try await web.evaluateJavaScript("document.getElementById('mode').textContent")
            try (controller.message + "\n" + String(describing:mode)).write(to:root.appendingPathComponent("compat-print-diagnostic.txt"),atomically:true,encoding:.utf8)
        }
        check(coloredPixels(printPage,channel:2)>30,"print-only stamp missing")
        window.close()
        print("PASS offline PDF.js appearance streams and print-only stamp toggle")
        // Snapshot the actual SwiftUI tool and AI layouts for review.
        for (name,view) in [("tools",AnyView(PDFToolsView(controller:controller))),("ai",AnyView(DocumentAIView(controller:controller)))] {
            let size=NSSize(width:name=="tools" ? 860:940,height:name=="tools" ? 720:690)
            let layoutWindow=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
            layoutWindow.isReleasedWhenClosed=false
            let host=NSHostingView(rootView:view.frame(width:size.width,height:size.height).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(.dark));host.frame=NSRect(origin:.zero,size:size)
            host.appearance=NSAppearance(named:.darkAqua);layoutWindow.contentView=host
            host.layoutSubtreeIfNeeded();try await Task.sleep(for:.milliseconds(500));host.layoutSubtreeIfNeeded();host.displayIfNeeded()
            if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds){host.cacheDisplay(in:host.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(name+"-ui.png"))}
            layoutWindow.close()
        }
        print("PASS document UI snapshots")
    }
}
