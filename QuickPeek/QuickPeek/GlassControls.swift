import SwiftUI

/// Shared native Liquid Glass controls for preview chrome and document workspaces.
struct QuickPeekGlassButtonStyle: ButtonStyle {
    enum Tone { case neutral, accent, destructive }
    var tone: Tone = .neutral
    var selected = false
    var height: CGFloat = 40
    var horizontalPadding: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, style: self)
    }

    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        let style: QuickPeekGlassButtonStyle
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        private var active: Bool { style.selected || style.tone == .accent }
        private var tint: Color {
            let color: Color = style.tone == .destructive ? .red : .accentColor
            if active { return color.opacity(configuration.isPressed ? 0.95 : 0.75) }
            if configuration.isPressed { return color.opacity(0.40) }
            if hovered && enabled { return color.opacity(0.20) }
            return .clear
        }
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, style.horizontalPadding)
                .frame(minHeight: style.height)
                .foregroundStyle(active ? Color.white : (style.tone == .destructive ? Color.red : (hovered && enabled ? Color.accentColor : Color.primary)))
                .contentShape(Capsule())
                .glassEffect(.regular.tint(tint).interactive(enabled), in: Capsule())
                .scaleEffect(enabled && !reduceMotion ? (configuration.isPressed ? 0.96 : (hovered ? 1.035 : 1)) : 1)
                .opacity(enabled ? 1 : 0.38)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.76), value: hovered)
                .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: active)
        }
    }
}

struct GlassToolButton: View {
    let title: String
    let icon: String
    var tone: QuickPeekGlassButtonStyle.Tone = .neutral
    var selected = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(QuickPeekGlassButtonStyle(tone: tone, selected: selected, height: 44))
    }
}

struct GlassIconButton: View {
    let title: String
    let icon: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).frame(width: 16) }
            .buttonStyle(QuickPeekGlassButtonStyle(height: 34, horizontalPadding: 11))
            .accessibilityLabel(title).help(title)
    }
}

private struct GlassInputStyle: ViewModifier {
    var height: CGFloat
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 15)
            .frame(minHeight: height)
            .glassEffect(.regular, in: Capsule())
    }
}
extension View {
    func glassInput(height: CGFloat = 40) -> some View { modifier(GlassInputStyle(height: height)) }
}

struct DocumentSheetBackground: View {
    var body: some View { Rectangle().fill(.ultraThinMaterial).ignoresSafeArea() }
}
