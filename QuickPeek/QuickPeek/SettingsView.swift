import SwiftUI
import ApplicationServices

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用"
    case display = "显示项"
    case openWith = "打开方式"
    case about = "关于"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .display: return "list.bullet"
        case .openWith: return "arrow.up.forward.app"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
                .overlay(Color.black.opacity(0.03))
                .ignoresSafeArea()

            tabContent
                .padding(.top, 22)

            tabBar
                .padding(.horizontal, 18)
                .padding(.top, 14)
        }
        .frame(minWidth: 500, minHeight: 470)
        .preferredColorScheme(settings.preferredColorScheme)
        .onAppear { accessibilityGranted = AXIsProcessTrusted() }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    Label(tab.rawValue, systemImage: tab.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selectedTab == tab ? .white : .primary.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedTab == tab ? Color.accentColor.opacity(0.92) : Color.white.opacity(0.06))
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 8)
    }

    private var tabContent: some View {
        ScrollView {
            VStack(spacing: 14) {
                Color.clear
                    .frame(height: 54)

                Group {
                    switch selectedTab {
                    case .general: generalTab
                    case .display: displayTab
                    case .openWith: openWithTab
                    case .about: aboutTab
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .scrollIndicators(.hidden)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.92), location: 0.06),
                    .init(color: .black, location: 0.12),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0.72),
                    Color(nsColor: .windowBackgroundColor).opacity(0.22),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 92)
            .allowsHitTesting(false)
        }
    }

    private var generalTab: some View {
        VStack(spacing: 14) {
            section("辅助功能权限") {
                HStack(spacing: 10) {
                    Image(systemName: accessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(accessibilityGranted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(accessibilityGranted ? "辅助功能已授权" : "需要辅助功能权限")
                            .font(.system(size: 13, weight: .semibold))
                        Text(accessibilityGranted ? "QuickPeek 可以正常拦截空格键" : "授权后才能拦截空格键，防止触发系统预览")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !accessibilityGranted {
                        Button("前往授权") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                                if AXIsProcessTrusted() {
                                    timer.invalidate()
                                    accessibilityGranted = true
                                    if let delegate = NSApp.delegate as? AppDelegate {
                                        delegate.setupEventTap()
                                        delegate.updateMenu()
                                    }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            section("界面与启动") {
                Toggle("开机自动启动", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
            }

            section("说明") {
                Text("在 Finder 中选中文件，按空格键即可预览。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var displayTab: some View {
        VStack(spacing: 14) {
            section("基本信息") {
                toggleList([
                    ("文件大小", $settings.showFileSize),
                    ("创建日期", $settings.showCreateDate),
                    ("修改日期", $settings.showModifyDate),
                    ("文件格式", $settings.showFormat)
                ])
            }

            section("图片信息") {
                toggleList([
                    ("尺寸", $settings.showDimensions),
                    ("色彩空间", $settings.showColorSpace),
                    ("分辨率 (DPI)", $settings.showDPI),
                    ("EXIF 信息", $settings.showEXIF)
                ])
            }

            section("文档 / 媒体 / 代码") {
                toggleList([
                    ("PDF 页数", $settings.showPDFPages),
                    ("媒体时长", $settings.showMediaDuration),
                    ("代码行数", $settings.showCodeLines),
                    ("字符编码", $settings.showEncoding)
                ])
            }
        }
    }

    private var openWithTab: some View {
        VStack(spacing: 14) {
            section("不同类型文件的默认打开应用") {
                Text("留空则使用系统默认应用打开")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            section("表格文件") { appPickerRow(binding: $settings.openWithSpreadsheet, subtitle: "xls, xlsx, csv, numbers…") }
            section("文档文件") { appPickerRow(binding: $settings.openWithDocument, subtitle: "doc, docx, ppt, pages…") }
            section("代码文件") { appPickerRow(binding: $settings.openWithCode, subtitle: "swift, py, js, ts…") }
            section("音乐文件") { appPickerRow(binding: $settings.openWithMusic, subtitle: "mp3, flac, wav, aac…") }
            section("其他文件") { appPickerRow(binding: $settings.openWithOther, subtitle: "未单独归类的文件") }
        }
    }

    private var aboutTab: some View {
        VStack(spacing: 14) {
            section("QuickPeek") {
                VStack(spacing: 12) {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    } else {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                    }

                    Text("空格预览增强工具 v1.0")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Divider()

                    Text("在 Finder 中选中文件按空格键，即可查看高保真预览和详细元数据。\n支持图片裁剪、视频裁切、代码编辑、文件夹浏览等功能。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("© 2026 LLEE. All rights reserved.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func labeledRow<Content: View>(_ title: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            trailing()
        }
    }

    private func toggleList(_ items: [(String, Binding<Bool>)]) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 16) {
                    Text(item.0)
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 24)
                    Toggle("", isOn: item.1)
                        .labelsHidden()
                }
                if index < items.count - 1 {
                    Divider()
                }
            }
        }
        .toggleStyle(.switch)
    }

    private func appPickerRow(binding: Binding<String>, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if binding.wrappedValue.isEmpty {
                    Text("系统默认")
                        .foregroundStyle(.secondary)
                } else {
                    let url = URL(fileURLWithPath: binding.wrappedValue)
                    let name = url.deletingPathExtension().lastPathComponent
                    Image(nsImage: NSWorkspace.shared.icon(forFile: binding.wrappedValue))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(name)
                        .lineLimit(1)
                }

                Spacer()

                Button("选择…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        binding.wrappedValue = url.path
                    }
                }
                .buttonStyle(.bordered)

                if !binding.wrappedValue.isEmpty {
                    Button("清除") { binding.wrappedValue = "" }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
            }
        }
    }
}
