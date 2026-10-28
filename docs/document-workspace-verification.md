# PDF 与 AI 工作台验证记录

日期：2026-10-28。目标 macOS 26+，Swift 6；本次使用 Xcode / macOS 27 SDK 构建。

## 调研顺序与实现依据

先核对 Apple Developer 的原生能力，再从官方 GitHub 项目引入兼容渲染器。原有主预览将 PDF 逐页栅格化，不能完整提供文字选择、表单交互与阅读器工具；但 Apple 文档也明确说明 `PDFPage.thumbnail` 可以包含批注，因此不能仅凭原架构断言某个真实印章丢失的根因。用户的问题 PDF 尚未提供，需用原文件继续复验。

- [Apple PDFView](https://developer.apple.com/documentation/pdfkit/pdfview)：应用内阅读、连续显示、导航、缩放与选区。
- [Apple PDFAnnotation](https://developer.apple.com/documentation/pdfkit/pdfannotation)：批注与 appearance stream；`shouldDisplay` / `shouldPrint` 分别控制显示和打印。
- [Apple PDFPage.thumbnail](https://developer.apple.com/documentation/pdfkit/pdfpage/thumbnail(of:for:))：页面含批注的缩略图。
- [Apple PDFDocumentWriteOption](https://developer.apple.com/documentation/pdfkit/pdfdocumentwriteoption)：批注固化、OCR 文字层、图片优化和密码选项。
- [Apple VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)：本地文字识别。
- [Mozilla PDF.js 官方仓库](https://github.com/mozilla/pdf.js)：Apache 2.0；固定 6.4.299，来源、完整性校验与打包器记录在应用资源 `PDFCompatibility/VERSION.json`，完整许可随包分发。
- [小米 MiMo 官方首次调用示例](https://mimo.mi.com/docs/zh-CN/quick-start/summary/first-api-call)：使用 `api-key` 请求头，默认 `https://api.xiaomimimo.com/v1`，预置可修改模型 `mimo-v2.6-pro`。
- [DeepSeek 官方接口](https://api-docs.deepseek.com/api/create-chat-completion/) 与 [当前模型表](https://api-docs.deepseek.com/quick_start/pricing)：默认 `https://api.deepseek.com`，预置可修改模型 `deepseek-flash`。

## 已实现

| 范围 | 行为 |
| --- | --- |
| PDF 阅读 | 原生 PDFKit、连续滚动、双指捏合、Command 滚动、查找、左侧缩略图、原生表单 |
| 印章兼容 | 离线 PDF.js 渲染 appearance stream；只读；可按打印外观显示仅打印批注；不改写原文件 |
| 页面操作 | 页码范围、旋转、删除、缩略图右键前移/后移、合并 PDF、插入图片页、提取指定页、撤回/重做 |
| 批注 | 对原生选中文字添加高亮/下划线/删除线；当前页文字批注和水印 |
| 导出 | TXT、本地 OCR、DOCX 文字重排、Excel 可打开的 CSV、图片版 PPTX、PNG/JPG 页面、常见内嵌图片 |
| 保存 | 新文件名保存副本、批注固化、图像压缩、可搜索 PDF、密码副本 |
| AI | MiMo、DeepSeek、自定义服务；全文/当前页/选区/指定页；总结、问答、目录、翻译、校对、PPT 大纲 |
| AI 结果 | 页码引用提示、分段及全文整合、复制、系统朗读、Markdown / DOCX / PNG 长图、内存历史、取消 |
| 密钥与网络 | 钥匙串按提供商和最终地址隔离；HTTPS，仅 loopback 允许 HTTP；拒绝重定向；不回显服务端原始错误正文 |

## 使用边界

- 不是完整 WPS 复刻。PDF↔CAD、证书签章及验证、直接编辑原 PDF 正文、复杂表格还原、可编辑 PPTX/Word 版式还原没有实现，也没有伪装成可用按钮。
- DOCX 为文字重排；CSV 按文字行导出，不承诺识别表格列；PPTX 每页是一张完整图片；AI 的 PPT 功能输出大纲。嵌入图片提取支持常见 XObject；复杂蒙版和索引色会跳过，内联图不保证，整页 PNG 保留可见外观更可靠。
- 原生页和兼容页是两个渲染器，复杂 PDF 的表现可能不同；打印外观还会遵循文档的打印图层设置。兼容视图只读，编辑需切回原生。
- 批注/页面编辑均不自动覆盖原文件。数字签名文件另存后，签名有效性可能改变；这里的签名外观显示不代表证书验证通过。
- 扫描 OCR 可能漏字，表格、复杂阅读顺序可能需要核对。模型引用页码为生成结果，应对照原文。
- AI 先在本机提取文字，用户可预览，只有点击发送才联网。未提供真实 API 密钥，尚未对三家真实付费接口进行调用；已用本机 HTTP 服务测试兼容协议与失败行为。
- 尚未取得用户那份印章不显示的 PDF。已验证人工构建的标准 Stamp AP、签名 Widget AP 和仅打印印章，不声称覆盖所有 WPS 私有格式。

## 自动验证

运行 `python3 tests/check-document-workspace.py`，直接编译生产文件，使用本机临时 HTTP 服务和离屏 WKWebView。

覆盖范围：

- 真正带 PDF appearance stream 的印章、签名及仅打印印章；原生渲染和 PDF.js 像素检查、显示/打印外观切换。
- 页码范围校验；旋转、移动、删除、撤回/重做；原 PDF 字节保持不变；选择文字加高亮及搜索。
- DOCX、PPTX 打包和 XML 结构验证；CSV 中文及公式前缀保护；本地扫描 OCR、内嵌图片、密码和总结长图。
- AI 地址归一化、禁止明文公网/URL 凭据、端点凭据隔离、Chat Completions 请求、MiMo `api-key` 与其他服务 Bearer 认证区别、HTTP 401、重定向、输出截断错误、长文尾段保留及整合。
- 正式应用 Release 构建及资源签名验证。

离屏 WKWebView 会暂停 rAF，测试夹具单独注入计时器保证渲染，生产代码使用正常 WebKit 时钟。界面检查图存于 `build/document-checks/`，不进入用户文档目录。

## 安装结果

已将签名 Release 安装至 `/Applications/QuickPeek.app` 并重新打开印章测试 PDF；已核对运行进程、签名及安装文件与构建产物一致。旧版备份在 `build/app-backups/QuickPeek-before-documents-20261028-110810.app`。生产应用保留原 bundle identifier 和开发签名要求。


## 文档界面整理

- 使用 macOS 26+ 原生 Liquid Glass 胶囊控件，统一预览工具栏、PDF 查找与缩放、OCR、文档和 AI 工具。悬浮时着色并轻微放大，按下加深并收缩；开启“减少动态效果”时停用缩放和滑动动画。
- 文档工具、文档 AI、服务设置合并为一个工作区。只有一个窗口背景；内容整页滚动到窗口上下边缘，从顶部悬浮导航下经过。导航支持点击和横向滚动切换，切换时保留原文、结果和工具输入。
- 六个 AI 功能直接展示；原文核对按需展开。转换按钮改为“转换为图片 / Word / 表格 / PPT”，格式细节放入菜单和悬浮提示。
- 依据：[Apple 自定义视图使用 Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)、[Glass.interactive](https://developer.apple.com/documentation/swiftui/glass/interactive(_:))；已核对本机 SDK 声明。
- 使用生产 SwiftUI 视图的原生窗口检查了布局、导航切换和滚动边缘。Liquid Glass 依赖窗口合成，离屏 bitmap 缓存会缺少玻璃图层，因此离屏图不作为外观验收依据。

新版已安装并在正式 `/Applications/QuickPeek.app` 中复验导航、图片转换菜单、AI 功能入口与主预览 / OCR 胶囊。新版前备份与 SHA-256 记录在 `build/document-checks/glass-install-result.json`；外观记录 `tools-ui.png`、`ai-ui.png` 来自正式应用窗口截图。实体触控板的横向滑动实现由原生事件处理；本次 UI 工具的滚动动作不能替代实体手势验收。
