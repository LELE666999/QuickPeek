# 时间线剪辑验证 · 2026-09-09

## 实现
- 内嵌 TimelineKitCore（MIT，固定提交与 blob 校验见 QuickPeek/Packages/TimelineKit/PROVENANCE.md）。未安装独立剪辑软件。
- 当前视频自动进入视频轨和实际音频轨。点击定位，Ctrl/Command B 分割，Cmd/Shift 多选、框选、Delete 批量删除，Cmd Z / Shift Cmd Z 撤销/重做。
- 音画默认联动；右键解除关联；可拖动片段和两端裁剪。独立删除保留空隙；右键提供明确的全轨闭合空隙操作。
- 底部播放、逐帧、缩放、适合与删除工具；视频画面无浮动控制条。
- 原生事件监听限定剪辑窗口并排除文本编辑与保存面板；全局空格与 Finder 选择轮询在剪辑中避让。
- 可序列化项目快照记录素材 URL、源区间、目标位置、轨道、关联和选择。当前 UI 为单素材临时编辑，未增加磁盘工程管理或多素材导入。
- 预览/导出共享 AVComposition、显式视频渲染、音频混音。任意帧切点被重新编码；音轨空隙输出为静音。原素材不被修改。

## 验证命令
`python3 tests/run-timeline-tests.py` 创建测试素材并执行模型、真实导出、原生事件及解码比较。测试覆盖 24/30 fps、有声/无声、旋转竖屏、非连续多选删除、撤销关联恢复、边界裁剪、序列化；核对输出帧映射、独立音频删除后的静音区间、原文件 SHA-256。

回归：tests/check-trackpad-gestures.py、check-preview-controls.py、check-toolbar-size.py、check-code-editor.py。

构建：`xcodebuild -project QuickPeek/QuickPeek.xcodeproj -scheme QuickPeek -configuration Release -derivedDataPath build -skipPackageUpdates build`。

## 验证范围
原生鼠标/键盘处理器和 AppKit/SwiftUI 离屏布局已验证；860pt 宽窗口工具栏和双轨无遮挡。离屏整页检查使用播放器占位，不作为实际播放截图。已对真实导出进行解码验证。由于电脑控制权限不可用，未进行真实鼠标/触控板的端到端人工操作验证。

## 安装
已完成独立审查并修复无音轨视频默认删除不衔接的问题，补充模型和会话层回归。最终 7 项包测试、原生事件/布局与解码校验通过，Release 构建及签名验证通过。

已退出旧版，替换并启动 `/Applications/QuickPeek.app`。启动进程：94935 /Applications/QuickPeek.app/Contents/MacOS/QuickPeek。

安装二进制 SHA-256 与构建结果一致：`e9968490cb371fce1b9d88d464fea27c6b68e381b888cbc80b4b483b5c3b6084`。

旧版备份：`/Users/lele/Desktop/自己开发的app/空格预览工具/build/app-backups/20260909-125927/QuickPeek.app`。

## 2026-09-09 磁吸与时间轴优化
- 拖动使用独立预览快照，画面中的片段实时跟随；松手提交一次撤销事务，拖回原位取消移动。
- 10pt 邻边磁吸与重叠边界限制；非整帧素材末端仍精确贴合。
- 关联裁短自动衔接；恢复长度时推开后续片段，独立音频编辑保留空隙规则。
- 默认一分钟视野，放大至一秒，向左继续缩小可显示一小时或更长素材；适合重置到素材起点。
- 双指/滚轮横向滚动、Option 拖动平移、拖到边缘持续滚动并扩展时间轴。
- 预览圆角 16pt、左右留白 16pt、上下留白 12pt；860pt 窗口离屏布局已检查。
- 独立审查发现的拖回原位与恢复裁剪边界问题均已修复并补回归。

磁吸版本已构建、验证签名、替换并启动：{"installed": "/Applications/QuickPeek.app", "backup": "/Users/lele/Desktop/自己开发的app/空格预览工具/build/app-backups/20260909-131334/QuickPeek.app", "sha256": "a9f42669cf2bcca4e610cd2530a1b562441f58e9a51bbe0326cbb74bb0908599", "process": "3273 /Applications/QuickPeek.app/Contents/MacOS/QuickPeek", "timestamp": "20260909-131334"}

## 导出错误与保存窗口更新（已编译，待替换）
保存窗口默认源目录并作为预览的 sheet 明确选择；错误按阶段显示中文标题、错误码和可复制详情，保留本地诊断及导出项目快照。当前选中录屏五种实际导出成功，截图中的中止未复现，不能断言已修复根因。
旧应用退出返回用户取消 -128，安装未执行。{"status": "built_not_installed", "reason": "Existing app rejected AppleEvent quit with user canceled (-128)", "built_sha256": "b4c9a275fc3394b03432e3b550169f7a7536175231035b8aa493c66176c4c25e", "installed_sha256": "a9f42669cf2bcca4e610cd2530a1b562441f58e9a51bbe0326cbb74bb0908599"}

## PPT 内嵌分页与直接捏合更新
PPT 通过 macOS qlmanage 输出 Quick Look HTML，再由应用内 WebKit 按页面生成静态预览；原 Keynote/LibreOffice 转换调用已移除。PresentationPreview 使用逐页缩略图浏览器，按文件 URL 管理视图生命周期，SwiftUI task 取消时终止后台生成及 WebKit 等待。已验证 7 页实际 PPT 页数与独立页面渲染，临时文件路径规范化避免 WebKit 文件访问失败。
手势增加 NSEvent.magnify 本地事件路由，先于原生视频/文档子视图处理；识别器排除同一事件避免双倍缩放。Command 滚动、双轴平移、默认翻页、点击穿透与原生视频控件回归通过。未进行真实触控板端到端操作，测试覆盖事件路由。PPT 为静态页，不播放演示动画。
已替换并启动，包含此前待安装的导出目录与错误诊断改进：{"status": "installed", "backup": "/Users/lele/Desktop/自己开发的app/空格预览工具/build/app-backups/20260909-182133/QuickPeek.app", "sha256": "e6c670a515e6d142ee53eb31076fb8f32294728502f1777104cd4c6d8c9c16b1", "process": "84180 /Applications/QuickPeek.app/Contents/MacOS/QuickPeek"}

## 2026-09-09 连续 PPT 与捏合事件修正

- PPT 使用 PDFKit 连续垂直文档视图承载原生渲染页面；保留缩略图导航，并同步当前页。页面内原生缩放与双轴滚动不再经过 SwiftUI 缩放覆盖层。
- 图片/视频缩放覆盖层不再从本地监视器吞掉 magnify；识别器代理允许放大事件，保留 responder 回退和 Command 滚动。
- check-continuous-presentations.py 通过：小幅滚动产生中间位置、不会整页切换、Command 缩放、侧栏双向同步。测试使用真实 NSHostingView/PDFView，滚动送入内部 NSScrollView。
- check-trackpad-gestures.py 通过；七页 PPT 原生渲染通过；Release 构建及签名校验通过。
- 已替换 /Applications/QuickPeek.app 并启动 PID 91796；安装详情见 build/continuous-presentation-installation.json。
- 用户确认系统“预览”捏合有效。自动化测试未使用实体触控板，不能宣称硬件输入已验收；新版待用户实际捏合确认。

## 2026-09-09 捏合再次失败：窗口焦点修正

用户确认系统“预览”可以捏合，但 QuickPeek 图片及 PPT 均不行。前一轮对缩放回调的测试未覆盖真实窗口焦点，不应作为实体触控板验收。

排查发现 showPreview 创建 nonactivatingPanel 后，又在 0.2 秒后主动 Finder.activate。此次去除非激活样式及打开后的 Finder 焦点移交；初次打开、Finder 选区更新均激活 QuickPeek 并保持预览为 key window。关闭预览仍返回 Finder。图片/视频单文件预览补充本地箭头导航，编辑时间线时禁止切换文件。标准 application(open URLs) 复用同一预览入口；旧窗口关闭动画使用窗口身份检查，避免清空新打开窗口。

实际应用检查（CUA）：
- 图片缩放控件从 100% 到 150%，方向键从 quickpeek-slide-1.png 切到 quickpeek-slide-2.png。
- 临时本地输入记录得到 `type=22 ... key=true active=true hit=ZoomableNSView`，确认当前输入落在已激活的预览。
- presentation.pptx 有 7 个左侧页缩略图；小幅滚动停在第一页与第二页之间，未硬切。
- 系统外部手势观察器未收到用户操作事件，不能据此判定系统未产生事件。后续用户离开，无法完成实体捏合复测。
- 临时应用事件记录代码已移除，诊断日志只保留测试结果，不含文件内容。

已通过手势逻辑与连续 PDFKit 页面测试；代码审查指出的编辑时切图及关闭动画竞态均已修复。真实触控板捏合仍待用户回来确认，不宣称已完成硬件验收。
