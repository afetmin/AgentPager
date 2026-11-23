import AgentGridShared
import SwiftUI

/// 与 Android 端 `AgentGridColors` 保持一致的暗色像素主题。
enum PixelTheme {
    static let background = Color(hex: 0x05070B)
    static let surface = Color(hex: 0x0B1018)
    static let raised = Color(hex: 0x101824)
    static let divider = Color(hex: 0x18212E)
    static let text = Color(hex: 0xE8EDF5)
    static let muted = Color(hex: 0x7F8A9A)
    static let dimmed = Color(hex: 0x4F5968)
    static let blue = Color(hex: 0x60A5FA)
    static let cyan = Color(hex: 0x5EEAD4)
    static let violet = Color(hex: 0xA78BFA)
    static let magenta = Color(hex: 0xE879F9)
    static let indigo = Color(hex: 0x818CF8)
    static let orange = Color(hex: 0xFB923C)
    static let amber = Color(hex: 0xFDBA4A)
    static let yellow = Color(hex: 0xFACC15)
    static let green = Color(hex: 0x4ADE80)
    static let red = Color(hex: 0xFB7185)
    static let usageBar = Color(hex: 0x326B73)
    static let usageBarDimmed = Color(hex: 0x1C3940)

    static func color(lifecycle: AgentLifecycle, activity: AgentActivity?) -> Color {
        switch lifecycle {
        case .waitingApproval: amber
        case .waitingAnswer: yellow
        case .succeeded: green
        case .interrupted, .offline: muted
        case .idle: cyan
        case .starting: violet
        case .running:
            switch activity {
            case .reading, .searching, .browsing: cyan
            case .editing: indigo
            case .executing: orange
            case .testing: blue
            default: magenta
            }
        }
    }

    static func color(_ provider: UsageProvider) -> Color {
        switch provider {
        case .codex: blue
        case .claude: violet
        }
    }

    static func quotaColor(_ remaining: Int?) -> Color {
        guard let remaining else { return dimmed }
        if remaining < 10 { return red }
        if remaining < 20 { return orange }
        return cyan
    }

    static func agentBadgeColor(_ task: TaskSnapshot) -> Color {
        task.source == .claudeCode ? violet : blue
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(pixelHex: UInt32) {
        self.init(hex: pixelHex)
    }
}

extension Font {
    /// Fusion Pixel 12px，随 App 打包（`UIAppFonts`）；缺失时回退到系统字体。
    static func pixel(_ size: CGFloat, weight: Weight = .regular) -> Font {
        .custom("Fusion-Pixel-12px-Prop-zh_hans-Regular", fixedSize: size).weight(weight)
    }
}

/// 方角像素按钮。
struct PixelButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.pixel(12, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(PixelTheme.raised)
                .overlay(Rectangle().stroke(color.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
