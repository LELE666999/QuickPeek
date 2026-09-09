# QuickPeek · 空格预览工具

macOS 文件预览应用，支持图片、视频、PDF、PPT 和代码预览，提供图片工具、语法高亮和视频片段剪辑。

## 开发

需要支持 macOS 26 SDK 的 Xcode 和 Swift 6.2 或更新版本。

打开 `QuickPeek/QuickPeek.xcodeproj`，选择 `QuickPeek` scheme。首次构建会通过 Swift Package Manager 获取依赖；在另一台电脑上构建时，请在 Signing & Capabilities 中选择自己的开发团队。

```sh
xcodebuild -project QuickPeek/QuickPeek.xcodeproj \
  -scheme QuickPeek -configuration Release \
  -derivedDataPath build build
```

源码和图标位于 `QuickPeek/QuickPeek/`，本地 Swift packages 位于 `QuickPeek/Packages/`，回归检查位于 `tests/`。部分媒体测试需要本机样例文件，运行前请查看相应测试脚本。

## 说明

- PPT 在应用内渲染并连续滚动，左侧保留逐页缩略图。
- 最新窗口焦点修正仍待实体触控板捏合复验；详细记录见 `docs/timeline-editor-verification.md`。
- 第三方代码的许可与来源保留在 `QuickPeek/Packages/TimelineKit/` 和 `QuickPeek/QuickPeek/ThirdPartyNotices.txt`。
- 编译产物、安装包、缓存和个人 Xcode 界面状态不纳入版本控制。
