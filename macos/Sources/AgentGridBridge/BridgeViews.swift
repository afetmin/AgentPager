import AppKit
import AgentGridCore
import SwiftUI

struct BridgeMenuView: View {
    let model: BridgeModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coreChangedAt = Date.now
    @State private var menuAppeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    PixelCoreView(
                        lifecycle: serviceLifecycle,
                        activity: nil,
                        changedAt: coreChangedAt
                    )
                    .id(serviceLifecycle)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                .frame(width: 58, height: 58)
                .animation(statusAnimation, value: serviceLifecycle)
                .accessibilityLabel("AgentPager 配置状态：\(model.serviceStatus)")

                VStack(alignment: .leading, spacing: 5) {
                    Text("AGENTPAGER BRIDGE")
                        .font(.pixel(15, weight: .bold))
                        .foregroundStyle(PixelTheme.text)
                        .lineLimit(1)
                    Text(model.serviceStatus)
                        .font(.pixel(11))
                        .foregroundStyle(statusColor)
                        .contentTransition(.interpolate)
                        .animation(statusAnimation, value: model.serviceStatus)
                    Text("\(model.phoneCount) 台手机连接")
                        .font(.pixel(10))
                        .foregroundStyle(PixelTheme.muted)
                        .contentTransition(.numericText(value: Double(model.phoneCount)))
                        .animation(statusAnimation, value: model.phoneCount)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                StatusCell(
                    label: "SERVER",
                    value: serviceValue,
                    active: serviceLifecycle == .idle
                )
                StatusCell(
                    label: "HOOK",
                    value: model.hookInstalled ? "READY" : "OFF",
                    active: model.hookInstalled
                )
                StatusCell(
                    label: "LINK",
                    value: model.phoneCount > 0 ? "LIVE" : "WAIT",
                    active: model.phoneCount > 0
                )
            }

            if let error = model.displayedError {
                ErrorBanner(message: error) { model.clearError() }
            }

            PixelDivider()

            Button {
                model.installHooks()
            } label: {
                Text(model.hookInstalled ? "修复 CODEX HOOK" : "安装 CODEX HOOK")
                    .contentTransition(.interpolate)
            }
            .buttonStyle(PixelButtonStyle(accent: PixelTheme.cyan))
            .animation(statusAnimation, value: model.hookInstalled)
            .popoverOptionEntrance(
                isPresented: menuAppeared,
                reduceMotion: reduceMotion,
                order: 0
            )

            Button {
                model.installClaudeHooks()
            } label: {
                Text(!model.claudeHookInstalled ? "安装 CLAUDE CODE HOOK"
                    : model.claudeStatusLineInstalled ? "修复 CLAUDE CODE HOOK" : "更新 CLAUDE CODE HOOK（含额度）")
                    .contentTransition(.interpolate)
            }
            .buttonStyle(PixelButtonStyle(accent: PixelTheme.violet))
            .animation(statusAnimation, value: model.claudeHookInstalled)
            .popoverOptionEntrance(
                isPresented: menuAppeared,
                reduceMotion: reduceMotion,
                order: 1
            )

            Button {
                openSettings()
                NSApplication.shared.activate()
            } label: {
                Text("打开 AGENTPAGER 设置")
            }
            .buttonStyle(PixelButtonStyle(accent: PixelTheme.violet))
            .popoverOptionEntrance(
                isPresented: menuAppeared,
                reduceMotion: reduceMotion,
                order: 2
            )

            PixelDivider()

            Button("退出 AGENTPAGER") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(PixelButtonStyle(accent: PixelTheme.muted))
            .popoverOptionEntrance(
                isPresented: menuAppeared,
                reduceMotion: reduceMotion,
                order: 3
            )
        }
        .padding(17)
        .frame(width: 330)
        .background(PixelTheme.background)
        .popoverEntrance(
            isPresented: menuAppeared,
            reduceMotion: reduceMotion
        )
        .preferredColorScheme(.dark)
        .font(.pixel(12))
        .onAppear {
            model.refreshHookStatuses()
            model.refreshPairingText()
            resetMenuEntrance()
            DispatchQueue.main.async {
                menuAppeared = true
            }
        }
        .onDisappear {
            resetMenuEntrance()
        }
        .onChange(of: serviceLifecycle) {
            coreChangedAt = .now
        }
    }

    private var serviceLifecycle: AgentLifecycle {
        switch model.serviceStatus {
        case "局域网服务运行中": .idle
        case "服务启动失败": .offline
        default: .starting
        }
    }

    private var statusColor: Color {
        switch serviceLifecycle {
        case .idle: PixelTheme.cyan
        case .offline: PixelTheme.red
        default: PixelTheme.violet
        }
    }

    private var serviceValue: String {
        switch serviceLifecycle {
        case .idle: "LIVE"
        case .offline: "ERROR"
        default: "START"
        }
    }

    private var statusAnimation: Animation {
        .spring(response: 0.3, dampingFraction: 0.82)
    }

    private func resetMenuEntrance() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            menuAppeared = false
        }
    }
}

struct BridgeSettingsView: View {
    enum Tab: String, CaseIterable {
        case pairing = "连接"
        case hook = "Hook"
        case simulator = "模拟器"
        case diagnostics = "诊断"
    }

    let model: BridgeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: Tab
    @State private var pairingTextCopied = false
    @Namespace private var tabSelection

    init(model: BridgeModel, initialTab: Tab = .pairing) {
        self.model = model
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                            selection = tab
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Text(tab.rawValue.uppercased())
                                .font(.pixel(12, weight: .bold))
                                .foregroundStyle(
                                    selection == tab ? PixelTheme.text : PixelTheme.muted
                                )
                            ZStack {
                                Rectangle()
                                    .fill(.clear)
                                if selection == tab {
                                    Rectangle()
                                        .fill(PixelTheme.cyan)
                                        .matchedGeometryEffect(
                                            id: "TAB_SELECTION",
                                            in: tabSelection
                                        )
                                }
                            }
                            .frame(height: 2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
            // Hook 页内容较高时，不允许内容区压缩顶部 Tab 栏。
            .fixedSize(horizontal: false, vertical: true)
            .background(PixelTheme.surface)
            .zIndex(1)

            ZStack {
                switch selection {
                case .pairing:
                    pairingView.transition(tabContentTransition)
                case .hook:
                    hookView.transition(tabContentTransition)
                case .simulator:
                    simulatorView.transition(tabContentTransition)
                case .diagnostics:
                    diagnosticsView.transition(tabContentTransition)
                }
            }
            // 内容区高度只取剩余空间，超出部分由各页自己滚动，不能反向撑高/顶走 Tab 栏。
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
        }
        .frame(minWidth: 650, minHeight: 480)
        .background(PixelTheme.background)
        .foregroundStyle(PixelTheme.text)
        .font(.pixel(12))
        .preferredColorScheme(.dark)
        .onAppear {
            model.refreshHookStatuses()
            model.refreshPairingText()
        }
        .onChange(of: model.pairingText) {
            pairingTextCopied = false
        }
        .task(id: pairingTextCopied) {
            // “已复制”只是短暂反馈，不应永久停留。
            guard pairingTextCopied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                pairingTextCopied = false
            }
        }
    }

    private var tabContentTransition: AnyTransition {
        .scale(scale: 0.985).combined(with: .opacity)
    }

    private var hookStatusTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.985).combined(with: .opacity)
    }

    private var hookStatusAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.3, dampingFraction: 0.82)
    }

    private var pairingView: some View {
        HStack(spacing: 34) {
            QRCodeView(text: model.pairingText)
                .padding(14)
                .background(.white)
                .frame(width: 258, height: 258)
                .accessibilityLabel("AgentPager 手机配对二维码")

            VStack(alignment: .leading, spacing: 14) {
                SettingsTitle("扫描配对")
                Text("左侧二维码就是配对码，用 Android AgentPager 扫描即可")
                    .foregroundStyle(PixelTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if model.serviceStatus == "服务启动失败" {
                    Text("局域网服务未启动，手机暂时无法连接，详情见“诊断”页。")
                        .font(.pixel(10))
                        .foregroundStyle(PixelTheme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PixelDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("配对文本（可直接选择）")
                        .font(.pixel(10, weight: .bold))
                        .foregroundStyle(PixelTheme.cyan)
                    ScrollView(.vertical) {
                        // 配对内容较长，限制显示高度并允许选择完整文本。
                        Text(
                            model.pairingText.isEmpty
                                ? "正在生成配对文本…"
                                : model.pairingText
                        )
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(PixelTheme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(height: 72)
                    .background(PixelTheme.background)
                    .overlay {
                        Rectangle()
                            .stroke(PixelTheme.divider, lineWidth: 1)
                    }
                }
                Button {
                    // 给无法扫码的场景提供与手机端输入框对应的文本入口。
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pairingTextCopied = pasteboard.setString(
                        model.pairingText,
                        forType: .string
                    )
                } label: {
                    Text(pairingTextCopied ? "已复制配对文本" : "复制配对文本")
                }
                .buttonStyle(PixelButtonStyle(accent: PixelTheme.cyan))
                .disabled(model.pairingText.isEmpty)
                InfoRow(label: "PHONE", value: "\(model.phoneCount)")
                InfoRow(label: "SERVICE", value: model.serviceStatus)
                InfoRow(
                    label: "LINK",
                    value: model.phoneCount > 0 ? "CONNECTED" : "WAITING",
                    accent: model.phoneCount > 0 ? PixelTheme.green : PixelTheme.amber
                )
            }
            .frame(maxWidth: 270, alignment: .leading)
        }
        .padding(30)
    }

    private var hookView: some View {
        // 内容高度超过最小窗口时需要滚动，否则会把顶部 Tab 栏挤出窗口。
        ScrollView {
            hookContent
        }
        .frame(minHeight: 0)
    }

    private var hookContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsTitle("Agent 生命周期 Hook")
            PixelPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Codex")
                        .font(.pixel(13, weight: .bold))
                        .foregroundStyle(PixelTheme.cyan)
                    ZStack(alignment: .leading) {
                        InfoRow(
                            label: "STATUS",
                            value: model.hookInstalled ? "已安装" : "未安装",
                            accent: model.hookInstalled ? PixelTheme.green : PixelTheme.amber
                        )
                        .id(model.hookInstalled)
                        .transition(hookStatusTransition)
                    }
                    .animation(hookStatusAnimation, value: model.hookInstalled)
                    Text("实时采集开始、工具、批准、完成和 Token；安装会保留现有 Hook，并在改写前备份。")
                        .foregroundStyle(PixelTheme.muted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = model.codexHookError {
                        ErrorBanner(message: error)
                    }
                    HStack(spacing: 10) {
                        Button("安装或修复") { model.installHooks() }
                            .buttonStyle(PixelButtonStyle(accent: PixelTheme.cyan))
                        Button("卸载") { model.uninstallHooks() }
                            .buttonStyle(PixelButtonStyle(accent: PixelTheme.red))
                            .disabled(!model.hookInstalled)
                    }
                }
            }
            PixelPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Claude Code")
                        .font(.pixel(13, weight: .bold))
                        .foregroundStyle(PixelTheme.violet)
                    ZStack(alignment: .leading) {
                        InfoRow(
                            label: "STATUS",
                            value: model.claudeHookInstalled ? "已安装" : "未安装",
                            accent: model.claudeHookInstalled ? PixelTheme.green : PixelTheme.amber
                        )
                        .id(model.claudeHookInstalled)
                        .transition(hookStatusTransition)
                    }
                    .animation(hookStatusAnimation, value: model.claudeHookInstalled)
                    InfoRow(
                        label: "QUOTA",
                        value: model.claudeStatusLineInstalled ? "额度读取已启用" : "未启用",
                        accent: model.claudeStatusLineInstalled ? PixelTheme.green : PixelTheme.amber
                    )
                    Text("向 ~/.claude/settings.json 写入生命周期 Hook，覆盖开始、工具、权限、完成等事件；保留现有 Hook 并自动备份。同时接管 statusLine 读取订阅额度（Claude Code CLI，Pro/Max），并原样转发你已有的状态栏命令，卸载时还原。")
                        .foregroundStyle(PixelTheme.muted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = model.claudeHookError {
                        ErrorBanner(message: error)
                    }
                    HStack(spacing: 10) {
                        Button("安装或修复") { model.installClaudeHooks() }
                            .buttonStyle(PixelButtonStyle(accent: PixelTheme.violet))
                        Button("卸载") { model.uninstallClaudeHooks() }
                            .buttonStyle(PixelButtonStyle(accent: PixelTheme.red))
                            .disabled(!model.claudeHookInstalled)
                    }
                    Text("另可读取 Claude Code 的登录凭据（钥匙串 Claude Code-credentials）直接查询额度：令牌只留在内存，只发往 api.anthropic.com 的只读额度接口；仅 Claude Code CLI 登录的账号可用。")
                        .foregroundStyle(PixelTheme.muted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.claudeOAuthQuotaEnabled ? "关闭凭据查询额度" : "开启凭据查询额度") {
                        model.setClaudeOAuthQuotaEnabled(!model.claudeOAuthQuotaEnabled)
                    }
                    .buttonStyle(PixelButtonStyle(accent: PixelTheme.amber))
                }
            }
            PixelPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Text("其他客户端")
                        .font(.pixel(13, weight: .bold))
                        .foregroundStyle(PixelTheme.cyan)
                    Text("兼容 Claude Code Hook 协议的客户端。只有检测到客户端已安装才能写入，改写前自动备份并保留你的既有 Hook。")
                        .foregroundStyle(PixelTheme.muted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(AgentIntegrations.all) { integration in
                        IntegrationRow(
                            integration: integration,
                            status: model.integrationStatuses[integration.id]
                                ?? BridgeModel.IntegrationStatus(),
                            install: { model.installIntegration(id: integration.id) },
                            uninstall: { model.uninstallIntegration(id: integration.id) }
                        )
                    }
                }
            }
            Text("Bridge 不在线时 Hook 自动放行，不会阻塞 Agent。")
                .font(.pixel(10))
                .foregroundStyle(PixelTheme.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var simulatorView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsTitle("状态模拟器")
                    Text("点击状态后通过真实同步链路更新手机；带声音标记的状态会触发手机提示音")
                        .foregroundStyle(PixelTheme.muted)
                }
                Spacer()
                if let previewTask = simulatorPreviewTask {
                    PixelCoreView(
                        lifecycle: previewTask.lifecycle,
                        activity: previewTask.activity,
                        changedAt: previewTask.updatedAt,
                        compact: false
                    )
                    .frame(width: 72, height: 72)
                }
            }

            LazyVGrid(
                columns: [.init(.adaptive(minimum: 135), spacing: 10)],
                spacing: 10
            ) {
                ForEach(AgentLifecycle.allCases, id: \.self) { lifecycle in
                    Button(simulatorLifecycleText(lifecycle)) {
                        model.simulate(lifecycle)
                    }
                    .buttonStyle(PixelButtonStyle(
                        accent: Color(pixelHex: PixelPalette.hex(
                            lifecycle: lifecycle,
                            activity: lifecycle == .running ? .editing : nil
                        )),
                        selected: simulatorPreviewTask?.lifecycle == lifecycle
                    ))
                }
            }
            HStack(spacing: 7) {
                Circle()
                    .fill(model.phoneCount > 0 ? PixelTheme.green : PixelTheme.muted)
                    .frame(width: 7, height: 7)
                Text(
                    model.phoneCount > 0
                        ? "手机已连接，状态改变会立即同步"
                        : "等待手机连接；未连接时只更新模拟状态"
                )
                .font(.pixel(10))
                .foregroundStyle(PixelTheme.muted)
            }
            Spacer()
        }
        .padding(28)
    }

    private var simulatorPreviewTask: TaskSnapshot? {
        model.tasks.first(where: { $0.id == "agentgrid-simulator" })
            ?? model.tasks.first(where: { $0.id == model.focusedTaskID })
    }

    private var diagnosticsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsTitle("运行诊断")
            HStack(spacing: 10) {
                StatusCell(label: "SERVICE", value: model.serviceStatus, active: true)
                StatusCell(label: "PHONE", value: "\(model.phoneCount)", active: model.phoneCount > 0)
                StatusCell(label: "TASK", value: "\(model.tasks.count)", active: !model.tasks.isEmpty)
            }
            Text("近期事件")
                .font(.pixel(12, weight: .bold))
                .foregroundStyle(PixelTheme.cyan)
            ScrollView {
                if model.recentEvents.isEmpty {
                    Text("暂无事件")
                        .font(.pixel(11))
                        .foregroundStyle(PixelTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.recentEvents.enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(.pixel(11))
                            .foregroundStyle(PixelTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        PixelDivider()
                    }
                }
            }
            .background(PixelTheme.surface)
            if let error = model.displayedError {
                ErrorBanner(message: error) { model.clearError() }
            }
        }
        .padding(28)
    }
}

/// 可关闭的错误提示：错误必须可见，并且能在用户处理后清除。
private struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(.pixel(11))
                .foregroundStyle(PixelTheme.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(PixelTheme.muted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭错误提示")
            }
        }
        .padding(8)
        .background(PixelTheme.red.opacity(0.1))
        .overlay {
            Rectangle().stroke(PixelTheme.red.opacity(0.5), lineWidth: 1)
        }
    }
}

private struct StatusCell: View {
    let label: String
    let value: String
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.pixel(9, weight: .bold))
                .foregroundStyle(PixelTheme.muted)
            Text(value)
                .font(.pixel(12, weight: .bold))
                .foregroundStyle(active ? PixelTheme.cyan : PixelTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .contentTransition(.interpolate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(PixelTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(active ? PixelTheme.cyan : PixelTheme.divider)
                .frame(height: 2)
        }
        .scaleEffect(active ? 1 : 0.985)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: active)
        .animation(.easeInOut(duration: 0.18), value: value)
    }
}

private struct IntegrationRow: View {
    let integration: AgentIntegration
    let status: BridgeModel.IntegrationStatus
    let install: () -> Void
    let uninstall: () -> Void

    private var statusText: String {
        if !status.detected && !status.installed { return "未检测到客户端" }
        if status.installed { return status.dormant ? "已写入，但客户端总开关已关闭" : "已安装" }
        return "未安装"
    }

    private var statusAccent: Color {
        if status.installed { return status.dormant ? PixelTheme.amber : PixelTheme.green }
        return status.detected ? PixelTheme.amber : PixelTheme.muted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PixelDivider()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(integration.displayName)
                    .font(.pixel(12, weight: .bold))
                    .foregroundStyle(PixelTheme.text)
                Text(integration.verification == .officialDocs ? "依据官方文档" : "社区实现 · 未真机验证")
                    .font(.pixel(9))
                    .foregroundStyle(PixelTheme.muted)
            }
            InfoRow(label: "STATUS", value: statusText, accent: statusAccent)
            Text("~/\(integration.configPath)")
                .font(.pixel(10))
                .foregroundStyle(PixelTheme.muted)
            if let note = integration.note {
                Text(note)
                    .font(.pixel(10))
                    .foregroundStyle(PixelTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = status.error {
                ErrorBanner(message: error)
            }
            HStack(spacing: 10) {
                Button(status.installed ? "修复" : "安装", action: install)
                    .buttonStyle(PixelButtonStyle(accent: PixelTheme.cyan))
                    .disabled(!status.detected)
                Button("卸载", action: uninstall)
                    .buttonStyle(PixelButtonStyle(accent: PixelTheme.red))
                    .disabled(!status.installed)
            }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var accent = PixelTheme.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.pixel(9, weight: .bold))
                .foregroundStyle(PixelTheme.muted)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.pixel(12, weight: .bold))
                .foregroundStyle(accent)
                .lineLimit(2)
        }
    }
}

private struct SettingsTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.pixel(19, weight: .bold))
            .foregroundStyle(PixelTheme.text)
    }
}

private struct PixelPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PixelTheme.surface)
            .overlay {
                Rectangle().stroke(PixelTheme.divider, lineWidth: 1)
            }
    }
}

private struct PixelDivider: View {
    var body: some View {
        Rectangle()
            .fill(PixelTheme.divider)
            .frame(height: 1)
    }
}

private struct PopoverEntranceModifier: ViewModifier {
    let isPresented: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .scaleEffect(
                isPresented || reduceMotion ? 1 : 0.975,
                anchor: .topTrailing
            )
            .offset(y: isPresented || reduceMotion ? 0 : -7)
            .animation(appearanceAnimation, value: isPresented)
    }

    private var appearanceAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.12)
        }
        return .timingCurve(0.16, 1, 0.3, 1, duration: 0.22)
    }
}

private struct PopoverOptionEntranceModifier: ViewModifier {
    let isPresented: Bool
    let reduceMotion: Bool
    let order: Int

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0)
            .offset(y: isPresented || reduceMotion ? 0 : -4)
            .animation(appearanceAnimation, value: isPresented)
    }

    private var appearanceAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.12)
        }
        return .timingCurve(0.16, 1, 0.3, 1, duration: 0.2)
            .delay(Double(order) * 0.03)
    }
}

private extension View {
    func popoverEntrance(
        isPresented: Bool,
        reduceMotion: Bool
    ) -> some View {
        modifier(PopoverEntranceModifier(
            isPresented: isPresented,
            reduceMotion: reduceMotion
        ))
    }

    func popoverOptionEntrance(
        isPresented: Bool,
        reduceMotion: Bool,
        order: Int
    ) -> some View {
        modifier(PopoverOptionEntranceModifier(
            isPresented: isPresented,
            reduceMotion: reduceMotion,
            order: order
        ))
    }
}

private struct PixelButtonStyle: ButtonStyle {
    let accent: Color
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pixel(11, weight: .bold))
            .foregroundStyle(configuration.isPressed ? PixelTheme.background : accent)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .center)
            .background {
                if configuration.isPressed {
                    accent
                } else if selected {
                    accent.opacity(0.16)
                } else {
                    PixelTheme.surface
                }
            }
            .overlay {
                Rectangle().stroke(
                    accent.opacity(selected ? 1 : 0.72),
                    lineWidth: selected ? 2 : 1
                )
            }
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(
                .spring(response: 0.2, dampingFraction: 0.78),
                value: configuration.isPressed
            )
            .animation(.easeInOut(duration: 0.16), value: selected)
    }
}

private func lifecycleText(_ lifecycle: AgentLifecycle) -> String {
    switch lifecycle {
    case .offline: "离线"
    case .idle: "空闲"
    case .starting: "正在启动"
    case .running: "正在运行"
    case .waitingApproval: "等待批准"
    case .waitingAnswer: "等待回答"
    case .succeeded: "任务完成"
    case .interrupted: "已中断"
    }
}

private func simulatorLifecycleText(_ lifecycle: AgentLifecycle) -> String {
    let sound: String? = switch lifecycle {
    case .running: "接收音"
    case .waitingApproval, .waitingAnswer: "提醒音"
    case .succeeded: "完成音"
    case .interrupted: "中断音"
    case .offline, .idle, .starting: nil
    }
    guard let sound else {
        return lifecycleText(lifecycle)
    }
    return "\(lifecycleText(lifecycle)) · \(sound)"
}
