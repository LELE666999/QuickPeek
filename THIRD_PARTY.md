# 第三方组件

QuickPeek 自有代码使用根目录的 [MIT 许可证](LICENSE)。第三方代码、字体和编解码器保留各自的许可证与版权声明，不因本项目开源而改变。

| 组件 | 用途 | 许可与来源 |
| --- | --- | --- |
| TimelineKitCore | 时间轴模型 | MIT；[来源与固定版本](QuickPeek/Packages/TimelineKit/PROVENANCE.md)、[LICENSE](QuickPeek/Packages/TimelineKit/LICENSE)、[NOTICE](QuickPeek/Packages/TimelineKit/NOTICE) |
| Mozilla PDF.js | 离线 PDF 印章兼容渲染 | Apache-2.0；[固定版本和来源](QuickPeek/QuickPeek/PDFCompatibility/VERSION.json)、[LICENSE](QuickPeek/QuickPeek/PDFCompatibility/LICENSE) |
| PDF.js 附带字体、CMaps、WASM | 字体、字符映射、PDF 解码 | 各目录保留独立的 LICENSE 文件，以对应文件为准 |
| SDWebImage | 图像加载与处理 | MIT；[官方仓库](https://github.com/SDWebImage/SDWebImage) |
| SDWebImageWebPCoder | WebP 编解码支持 | MIT；[官方仓库](https://github.com/SDWebImage/SDWebImageWebPCoder) |
| libwebp / libwebp-Xcode | WebP 编解码器及 Swift Package 封装 | BSD 许可证；[官方封装仓库](https://github.com/SDWebImage/libwebp-Xcode)、其中的 `libwebp/COPYING` |

Swift Package Manager 依赖的固定版本见 [Package.resolved](QuickPeek/QuickPeek.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)。PDF.js 资源可用 [更新脚本](scripts/update-pdfjs.py) 从固定来源及校验值重新生成。

FFmpeg、img2webp 和 Python fontTools 是用户自行安装的可选外部工具，本仓库不分发其可执行文件。用户用于预览或测试的图片、视频、字体和文档不包含在源码许可中。
