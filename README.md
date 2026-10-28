# QuickPeek · 空格预览工具

macOS 文件预览应用，支持图片、视频、PDF、PPT 和代码预览，提供图片工具、语法高亮、视频片段剪辑、格式转换及文档 AI。

[MIT License](LICENSE) · [第三方组件](THIRD_PARTY.md) · [问题反馈](https://github.com/LELE666999/QuickPeek/issues)

## 开发

需要支持 macOS 26 SDK 的 Xcode 和 Swift 6.2 或更新版本。

打开 `QuickPeek/QuickPeek.xcodeproj`，选择 `QuickPeek` scheme。首次构建会通过 Swift Package Manager 获取依赖；在另一台电脑上构建时，请在 Signing & Capabilities 中选择自己的开发团队。

```sh
xcodebuild -project QuickPeek/QuickPeek.xcodeproj \
  -scheme QuickPeek -configuration Release \
  -derivedDataPath build build
```

源码和图标位于 `QuickPeek/QuickPeek/`，本地 Swift packages 位于 `QuickPeek/Packages/`，回归检查位于 `tests/`。部分媒体测试需要本机样例文件，运行前请查看相应测试脚本。

## 单片段导出

在片段剪辑时间轴中，右键点击视频片段 →「导出当前片段」，可保存 MP4、实况图、GIF 或动态 WebP。即使多选了其他片段，也只导出右键点中的一段；声音按这一段在时间轴上的音轨内容保留。文件导出通过保存面板选择位置，默认原视频目录，不覆盖原视频；实况照片默认打开“下载”文件夹，可改选保存位置。

实况图导出为 `.pvt` 包：包内保留配对 JPG、MOV 和 metadata.plist，并设置 macOS package 属性，在 Finder 中作为一个项目管理。预览工具栏“转格式”和片段右键菜单都默认保存到“下载”，完成后在 Finder 中定位；不写入照片图库，也不请求照片权限。PVT 清单格式参考 [makelive](https://github.com/RhetTbull/makelive/blob/main/makelive/makelive.py)，并由本地代码生成。动图无声，采用 15 fps、最长边 640 px；GIF 需要本机 Homebrew 的 `ffmpeg`，WebP 另需 `libwebp` 的 `img2webp`。MP4 和实况图使用系统 AVFoundation，不依赖这些命令行工具。

## 说明

- PPT 在应用内渲染并连续滚动，左侧保留逐页缩略图。
- 最新窗口焦点修正仍待实体触控板捏合复验；详细记录见 `docs/timeline-editor-verification.md`。
- 第三方代码的许可与来源保留在 `QuickPeek/Packages/TimelineKit/` 和 `QuickPeek/QuickPeek/ThirdPartyNotices.txt`。
- 编译产物、安装包、缓存和个人 Xcode 界面状态不纳入版本控制。

预览工具栏的“转格式”按图片、动图、视频、音频分组，支持 PNG/JPG/HEIC/TIFF/BMP、GIF/WebP/APNG、MP4/MOV/MKV/WebM、MP3/M4A/WAV/FLAC（按本机编码器显示）。视频的图片导出使用当前播放位置；WebM 浏览器预览暂使用首帧。图片输入仅显示图片和动图格式，音频输入仅显示音频格式。`tests/check-preview-formats.py` 验证实际编码输出和工具探测。实况照片测试验证包属性、清单以及 PHLivePhoto 对包内配对资源的识别，不写入个人照片库。

## 字体预览与提取

TTF / OTF / TTC / OTC / dfont 使用 CoreText 直接从文件读取字体，展示中英文、数字、符号、自定义试字、可调字号和分页字符表；字体集合可选择字体面。不将预览字体安装到系统，缺失字符会标注，不用系统字体冒充原字体。

TTF / OTF 在“转格式”或“工具”中提供“提取字体字符”：默认 ASCII 英文、数字、标点及常用符号，可编辑保留文字。通过本机 Python 的 fontTools（与格式工坊相同的依赖）生成新字体，验证 cmap、保留布局依赖、修改字体名称以免与原字体混淆；默认另存到下载。原文件不变。`tests/check-font-subset.py` 验证实际中文字体提取、自定义字符、字宽与原文件保护。

## 多选片段批量实况图

时间轴中按住 Command 点击多个视频片段（也可框选），右键“导出所选 N 段为实况图”。一次选择保存文件夹，默认下载；可选苹果、鸿蒙测试版或两种都导出。每段单独生成文件，按时间轴片段编号命名，完成后显示整批文件夹；重复导出自动使用新目录。音画关联中的音频不会重复计数。建议短片段 1.5–3 秒，导出仍保留实际选中范围，不自动截短。

苹果为现有 `.pvt` Live Photo 包。鸿蒙测试版是 JPEG + MP4 + 60 字节尾部（版本、封面、视频长度），依据 [OpenHarmony moving_photo_file_utils.cpp](https://github.com/openharmony/multimedia_media_library/blob/master/frameworks/innerkitsimpl/media_library_helper/src/moving_photo_file_utils.cpp) 的公开封装和解析规则生成。已验证 JPEG 解码、内嵌视频提取和时长；未在用户鸿蒙手机图库实测，不宣称跨版本或所有传输软件通用。发送时保留原文件，避免图片压缩丢弃尾部视频。

## PDF 文档工作台与 AI（2026-10-28）

空格预览 PDF 后，顶部新增「文档」「AI 助手」。主视图改用 PDFKit，支持连续滚动、原生文字选择、搜索、表单填写、缩略图导航和触控板缩放。遇到第三方印章外观，可切换「印章兼容」使用内置的离线 Mozilla PDF.js；「文档」右上角说明按钮中还可选择打印外观，检查文件标记为仅打印的印章。

文档工具包含旋转、删除、移动页面、撤回/重做、合并 PDF、插入图片页、提取指定页、文字高亮/下划线/删除线、批注、水印、朗读、TXT/OCR、Word 文字重排、Excel CSV、PPTX 页面图片、PNG/JPG、内嵌图片提取、批注固化、压缩、可搜索 PDF、密码副本。修改留在内存中，保存时使用新文件名；原文件不会被自动覆盖。数字签名验证与证书签署、PDF↔CAD、复杂表格和可编辑版式还原尚未接入。

「设置 → AI」配置小米 MiMo、DeepSeek 或自定义 OpenAI Chat Completions 服务的地址、模型和密钥。打开「AI 助手」，直接选择全文总结、全文问答、生成目录、全文翻译、文字校对或 PPT 大纲；选择全文/当前页/选中文字/指定页，应用在本机读取文字，可展开原文核对后再点击发送。支持全文总结、问答、目录、翻译、校对和 PPT 大纲；结果可复制、朗读、导出 Markdown/Word/总结长图。长文分段处理并整合，避免只发送开头。密钥保存在系统钥匙串，服务地址变更后不会复用其他地址的密钥；历史仅存在本次运行的内存中。

实现依据、限制和测试见 [PDF 与 AI 验证记录](docs/document-workspace-verification.md)。离线 PDF.js 已随应用打包，用户无需 Node 或 Python；开发者可用 `python3 scripts/update-pdfjs.py` 按固定版本和 SHA-512 重建资源。


## 界面与交互

预览工具栏、识别区与文档控件使用原生 Liquid Glass 胶囊，支持悬浮高亮和按下反馈。文档工具、文档 AI 与服务设置共用一个工作区：顶部导航悬浮，页面横向切换，内容整页滚动。启用系统“减少动态效果”时减少缩放及滑动动画。

## 运行与可选工具

- 系统要求：macOS 26 或更新版本。首次运行按应用提示授予空格键拦截所需的辅助功能权限，以及读取 Finder 选中文件所需的自动化权限。
- PDF 阅读、基础媒体预览、MP4 与苹果实况照片导出使用系统框架；PPT 以静态页面预览，不播放幻灯片动画。
- 部分媒体格式转换需自行安装 FFmpeg；动态 WebP 另需 libwebp 的 img2webp。未安装时以应用实际显示的格式为准。
- 字体提取需要 Python 3 与 fontTools：`python3 -m pip install fonttools`。不包含测试用字体或用户个人素材。
- AI 为可选功能，使用你自己的 MiMo、DeepSeek 或兼容服务密钥；点击发送时才联网。仓库不含 API 密钥。

## 回归检查

在 macOS 与 Xcode 环境下，可先运行无需私人素材的检查：

```sh
python3 tests/check-document-workspace.py
python3 tests/check-continuous-presentations.py
python3 tests/check-trackpad-gestures.py
```

视频回归另需 FFmpeg：`python3 tests/run-timeline-tests.py`。字体与真实 PPT 检查需自行提供样本：

```sh
python3 tests/check-font-subset.py /path/to/chinese-font.ttf
python3 tests/check-native-presentations.py /path/to/seven-slides.pptx
```

实体触控板手势与鸿蒙图库兼容性仍需在对应设备实测；自动化检查通过不代表所有硬件和系统版本均已验收。

## 开源许可

QuickPeek 自有代码采用 [MIT License](LICENSE)，欢迎通过 Issue 反馈问题或提交 Pull Request。第三方组件保留原有许可，详见 [THIRD_PARTY.md](THIRD_PARTY.md)。构建产物、个人配置、密钥和本地制作的介绍视频不纳入源码仓库。
