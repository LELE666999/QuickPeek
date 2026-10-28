import SwiftUI
import WebKit
import PDFKit

/// Bundled, offline PDF.js is a second renderer for third-party PDF appearance streams.
struct PDFCompatibilityView: NSViewRepresentable {
    @ObservedObject var controller: PDFDocumentController
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "documentViewer")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator; view.allowsMagnification = true
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.view = view
        if let folder = Bundle.main.url(forResource: "PDFCompatibility", withExtension: nil) {
            view.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
        } else { controller.message = "未找到离线 PDF 兼容组件，请重新安装完整应用。" }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.ready && (coordinator.revision != controller.revision || coordinator.printAppearance != controller.showPrintOnlyStamps) { coordinator.load() }
        if coordinator.ready && coordinator.page != controller.currentPageIndex {
            coordinator.page = controller.currentPageIndex
            view.callAsyncJavaScript("window.goToPDFPage(page)", arguments: ["page": controller.currentPageIndex], in: nil, in: .page) { _ in }
        }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "documentViewer")
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let controller: PDFDocumentController
        weak var view: WKWebView?
        var ready = false
        var revision = -1
        var page = -1
        var printAppearance = false
        init(_ controller: PDFDocumentController) { self.controller = controller }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? [String: Any], let type = value["type"] as? String else { return }
            if type == "ready" { ready = true; load() }
            else if type == "page", let index = value["index"] as? Int {
                page = index; controller.setCurrentPage(index)
            } else if type == "error" { controller.message = "兼容渲染失败：" + (value["message"] as? String ?? "未知错误") }
        }
        func load() {
            do {
                let data: Data
                if !controller.isEdited, controller.document?.isEncrypted == false { data = try Data(contentsOf: controller.fileURL) }
                else if let saved = controller.document?.dataRepresentation() { data = saved }
                else { throw DocumentToolError("无法读取 PDF 数据。") }
                revision = controller.revision; page = controller.currentPageIndex; printAppearance = controller.showPrintOnlyStamps
                view?.callAsyncJavaScript("await window.loadPDF(data, page, printAppearance)", arguments: ["data": data.base64EncodedString(), "page": page, "printAppearance": printAppearance], in: nil, in: .page) { [weak self] result in
                    if case .failure(let error) = result { self?.controller.message = "兼容组件加载失败：" + (((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription) }
                }
            } catch { controller.message = error.localizedDescription }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.isFileURL == true ? .allow : .cancel
        }
    }
}
