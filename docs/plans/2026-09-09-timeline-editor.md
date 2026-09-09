# QuickPeek 内嵌时间线剪辑方案（已确认并实现）

## 目标
在 QuickPeek 的“片段剪辑”界面直接编辑当前视频，不启动独立剪辑软件。普通空格预览保持轻量；进入剪辑后才加载时间线模块。使用开源模块构建，不能以安装一个独立应用代替嵌入。

## 开源候选核查
- 推荐基础：tuxi/TimelineKit，MIT，版权 Ivan Yang。已读取 LICENSE、Package.swift、桌面入口和编辑模型。已固定并核实提交 768476dbfd70375056ca3de25bcdfc66f0b6b678，逐个核对 31 个源码 blob 哈希。
- 有 TimelineDocument 分割、撤销/重做、selection 集合；EditorStore 有 detachAudio；渲染层有波形、组合和导出基础设施。
- macOS ClipEditorView 当前导出按钮为 placeholder 且 disabled(true)，不能直接作为可用整套产品交付。其入口自行创建资源库与空项目，不直接接收正在预览的视频。
- 因此复用 Core/Render 及适用界面模块，增加 QuickPeek 的单视频入口、时间线交互、关联编辑及现有本地导出适配。保留 MIT LICENSE/NOTICE，记录本地修改。
- 对比：Shotcut 官方列出多轨、波形、分割、多选、音频分离和撤销，但它是独立完整编辑器；直接调用它会离开 QuickPeek，不符合当前内嵌体验。

参考：
https://github.com/tuxi/TimelineKit
https://github.com/tuxi/TimelineKit/blob/main/LICENSE
https://github.com/tuxi/TimelineKit/blob/main/Sources/TimelineKitUIMac/ClipEditorView.swift
https://shotcut.org/features/

## 操作约定
1. 点击时间尺或片段位置定位播放头；Ctrl+B 和 Command+B 均在播放头处分割。分割精度按素材帧率对齐。边界位置不生成零长度片段。
2. 可以连续分割成任意多个片段；Command 点击增减选择，Shift 点击范围选择；支持框选。选中片段显示清晰边框。
3. 右下角放删除按钮；Delete 同效。默认删除后闭合时间空隙，多个选中片段作为一次事务处理；另提供“删除并保留空隙”。
4. 底部提供分割、删除、撤销、重做、时间线缩放、适应全部、播放/暂停和导出。Command+Z 撤销，Command+Shift+Z 重做。无可用操作时禁用按钮。
5. 视频缩略图轨在上，有音频时下方显示真实音频波形。无音频不显示虚构音轨。
6. 初始音轨与视频关联。选择、分割、移动、修剪和删除默认同时作用于关联音画，避免自动失步。右键“解除音画关联”后才允许独立编辑；可撤销解除操作。
7. 解除关联后的独立删除默认保留空隙，避免悄悄移动其它关联素材造成失步；闭合空隙须明确选择对应操作。
8. 预览只保留底部一套播放控制；视频上不叠加原生大控制条。
9. 播放、试听和导出使用同一时间线数据；音频不得重复混入。导出副本，不能覆盖原视频。暂不包含字幕、AI、转场商店、滤镜商店等未明确要求的模块。

## 实现结构
- 固定版本的本地开源依赖与许可证资源。
- 可序列化时间线项目：素材引用、源区间、目标位置、轨道、关联 ID。
- 一次编辑一个撤销事务；分割音画及批量删除不能被拆成多个撤销步骤。
- 预览与导出适配共享时间线；生成缩略图和波形在后台执行、按素材缓存。
- 替换 VideoTrimView 的单选区入口；保留 PreviewWindow 的播放器和原生缩放处理。

## 验收
- 在 2/4/6/8 秒连续分割样本，选择不连续片段批量删除；核对剩余画面、顺序和时长。
- 连续撤销/重做，恢复每个片段位置、选中状态、关联和音频内容。
- 有声、无声、竖屏、不同帧率样本；音轨波形与实际声音对应。
- 默认关联的分割/删除音画同步；解除关联后可只删音频，视频不受影响。
- 检查原始文件哈希未变化；成片解码、总时长、接缝画面、接缝声音及方向均正确。
- 快捷键仅在剪辑窗口响应，文本输入时不误触发。
- 完成构建、签名及上述回归后再退出旧版、替换 /Applications/QuickPeek.app 并启动。
- 自动化逻辑与真实鼠标/触控板操作分开报告，不把调用回调当作完整交互验证。

## 当前状态
用户已确认，功能已实现。实际复用 TimelineKitCore；QuickPeekTimeline 包负责关联事务和 AVFoundation 渲染，原生时间线 UI 在 TimelineEditorView.swift。预览和导出使用同一组合、视频渲染与音频混音。验收和安装记录见 docs/timeline-editor-verification.md。
