import AgentGridShared
import SwiftUI
import UIKit

/// 配对后的主界面：顶栏额度、任务列表 / 状态态切换、设置面板与离线提示。
struct DashboardView: View {
    let model: AppModel
    @State private var settingsVisible = false

    private var state: PhoneSessionState { model.state }
    private var projection: TaskDashboardProjection { model.projection }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 600
            ZStack {
                PixelTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    TopBar(
                        codex: projection.dashboardVisible ? nil : state.snapshot.usage,
                        claude: projection.dashboardVisible ? nil : state.snapshot.claudeUsage,
                        compact: compact,
                        dashboardVisible: projection.dashboardVisible,
                        settingsVisible: settingsVisible,
                        onToggleDashboard: {
                            withAnimation(.easeOut(duration: 0.18)) {
                                model.toggleDashboard()
                                settingsVisible = false
                            }
                        },
                        onToggleSettings: {
                            withAnimation(.easeOut(duration: 0.14)) { settingsVisible.toggle() }
                        }
                    )

                    ZStack {
                        if projection.dashboardVisible {
                            UsageDashboardView(
                                codex: state.snapshot.usage,
                                claude: state.snapshot.claudeUsage,
                                connected: state.link == .connected,
                                compact: compact
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.985)))
                        } else {
                            TaskListView(model: model, compact: compact)
                                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.easeOut(duration: 0.2), value: projection.dashboardVisible)
                }

                if settingsVisible {
                    SettingsPanel(model: model, onClose: { settingsVisible = false })
                        .padding(.top, 46)
                        .padding(.trailing, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity)
                }

                if state.link != .connected {
                    Text("BRIDGE OFFLINE · 正在重连")
                        .font(.pixel(11))
                        .tracking(1)
                        .foregroundStyle(PixelTheme.dimmed)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.14), value: state.link)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(model.terminalMode)
        .persistentSystemOverlays(model.terminalMode ? .hidden : .automatic)
        .onAppear { applyKeepAwake() }
        .onChange(of: model.terminalMode) { applyKeepAwake() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func applyKeepAwake() {
        UIApplication.shared.isIdleTimerDisabled = model.terminalMode
    }
}

private struct TopBar: View {
    let codex: UsageSnapshot?
    let claude: UsageSnapshot?
    let compact: Bool
    let dashboardVisible: Bool
    let settingsVisible: Bool
    let onToggleDashboard: () -> Void
    let onToggleSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 12) {
                    ForEach(UsageProvider.allCases) { provider in
                        let windows = provider.pick(codex: codex, claude: claude)?.windows ?? []
                        let picked = UsagePresentation.pickWindows(windows)
                        let shown = [picked.primary, picked.secondary].compactMap { $0 }
                        let limited = compact ? Array(shown.prefix(1)) : shown
                        if !limited.isEmpty {
                            UsagePillGroup(provider: provider, windows: limited, now: context.date)
                        }
                    }
                }
            }
            Button(action: onToggleDashboard) {
                ViewSwitchIcon(showTaskIcon: dashboardVisible)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dashboardVisible ? "切换到任务列表" : "切换到状态显示栏")
            Button(action: onToggleSettings) {
                Text(settingsVisible ? "×" : "⚙")
                    .font(.pixel(16, weight: .bold))
                    .foregroundStyle(settingsVisible ? PixelTheme.amber : PixelTheme.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settingsVisible ? "关闭设置" : "打开设置")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

private struct UsagePillGroup: View {
    let provider: UsageProvider
    let windows: [UsageWindow]
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(provider.shortName)
                .font(.pixel(11, weight: .bold))
                .foregroundStyle(PixelTheme.color(provider))
            ForEach(windows) { window in
                UsagePill(provider: provider, window: window, now: now)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UsagePill: View {
    let provider: UsageProvider
    let window: UsageWindow
    let now: Date

    var body: some View {
        let display = UsagePresentation.display(window, fallbackLabel: window.key, now: now)
        let remaining = display.remaining
        HStack(spacing: 5) {
            Text("\(display.label) \(remaining.map { "\($0)%" } ?? "--")")
                .font(.pixel(11))
                .foregroundStyle(PixelTheme.muted)
                .lineLimit(1)
            QuotaBar(fraction: Double(remaining ?? 0) / 100, color: PixelTheme.quotaColor(remaining), height: 3)
                .frame(width: 36)
        }
        .accessibilityLabel("\(provider.displayName) \(display.label) 额度\(remaining.map { "剩余 \($0)%" } ?? "未知")")
    }
}

/// 方角进度条。
struct QuotaBar: View {
    let fraction: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(PixelTheme.divider)
                Rectangle()
                    .fill(color)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
    }
}

private struct ViewSwitchIcon: View {
    let showTaskIcon: Bool

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 16
            func block(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
                context.fill(
                    Path(CGRect(x: x * unit, y: y * unit, width: width * unit, height: height * unit)),
                    with: .color(PixelTheme.muted)
                )
            }
            if showTaskIcon {
                // 三行任务列表：左侧状态格，右侧信息条。
                for y: CGFloat in [1, 7, 13] {
                    block(0, y, 3, 3)
                    block(5, y, 11, 3)
                }
            } else {
                // 三档状态柱：用硬直角高度差表示状态总览。
                block(0, 10, 4, 6)
                block(6, 6, 4, 10)
                block(12, 1, 4, 15)
            }
        }
        .frame(width: 14, height: 14)
    }
}

private struct SettingsPanel: View {
    let model: AppModel
    let onClose: () -> Void
    @State private var confirmingUnpair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置")
                .font(.pixel(14, weight: .bold))
                .foregroundStyle(PixelTheme.text)
            detail("LINK", model.state.link == .connected ? "已连接" : "正在重连",
                   model.state.link == .connected ? PixelTheme.green : PixelTheme.red)
            detail("TASK", "\(model.projection.orderedTasks.count)", PixelTheme.cyan)
            if let pairing = model.state.pairing {
                detail("MAC", "\(pairing.host):\(pairing.port)", PixelTheme.muted)
            }
            if let error = model.controlError {
                Text(error)
                    .font(.pixel(11))
                    .foregroundStyle(PixelTheme.red)
            }
            Toggle(isOn: Binding(get: { model.soundEnabled }, set: { model.soundEnabled = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("提示音")
                        .font(.pixel(12, weight: .bold))
                        .foregroundStyle(PixelTheme.text)
                    Text("等待输入、完成、中断时响")
                        .font(.pixel(10))
                        .foregroundStyle(PixelTheme.muted)
                }
            }
            .tint(PixelTheme.green)
            Toggle(isOn: Binding(get: { model.terminalMode }, set: { model.terminalMode = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("专用模式")
                        .font(.pixel(12, weight: .bold))
                        .foregroundStyle(PixelTheme.text)
                    Text("屏幕常亮，隐藏状态栏")
                        .font(.pixel(10))
                        .foregroundStyle(PixelTheme.muted)
                }
            }
            .tint(PixelTheme.green)
            PixelButton(title: "解除配对", color: PixelTheme.red) { confirmingUnpair = true }
        }
        .padding(14)
        .frame(width: 236)
        .background(PixelTheme.surface)
        .overlay(Rectangle().stroke(PixelTheme.divider, lineWidth: 1))
        .confirmationDialog("解除配对后需要重新扫码才能连接。", isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("解除配对", role: .destructive) {
                onClose()
                model.unpair()
            }
        }
    }

    private func detail(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.pixel(10, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(.pixel(11))
                .foregroundStyle(PixelTheme.text)
                .lineLimit(1)
        }
    }
}
