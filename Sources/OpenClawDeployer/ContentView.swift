import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var runner: DeploymentRunner

    @State private var mirrorURL = "https://registry.npmmirror.com"
    @State private var modelProvider: OpenClawModelProvider = .qwenCloud
    @State private var modelAPIKey = ""
    @State private var qwenAuthChoice: QwenCloudAuthChoice = .standardChina
    @State private var installClaudeCode = true
    @State private var installAgencyAgents = true
    @State private var installGatewayDaemon = true
    @State private var openDashboard = true
    @State private var channels = ChannelDefinition.supported.map { ChannelFormState(definition: $0) }
    @State private var showExistingAPIKeyDialog = false
    @State private var pendingDeployConfig: DeployConfig?
    @State private var existingAPIKeyConfigSummary = ""
    private let autoRefresh: Bool

    @MainActor
    init(autoRefresh: Bool = true) {
        _runner = StateObject(wrappedValue: DeploymentRunner())
        self.autoRefresh = autoRefresh
    }

    @MainActor
    init(runner: DeploymentRunner, autoRefresh: Bool = true) {
        _runner = StateObject(wrappedValue: runner)
        self.autoRefresh = autoRefresh
    }

    var body: some View {
        ZStack {
            OpenClawBackdrop()

            openClawContent
        }
        .tint(.musicAccent)
        .openClawWindowContainer()
        .onAppear {
            if autoRefresh {
                runner.refreshEnvironment()
            }
        }
        .confirmationDialog(
            "本机存在 API Key 配置",
            isPresented: $showExistingAPIKeyDialog,
            titleVisibility: .visible
        ) {
            Button("覆盖配置") {
                startPendingDeployment(action: .overwriteExisting)
            }
            Button("跳过，沿用现有配置") {
                startPendingDeployment(action: .skipExisting)
            }
            Button("取消", role: .cancel) {
                pendingDeployConfig = nil
                existingAPIKeyConfigSummary = ""
            }
        } message: {
            Text("检测到本机已存在 \(existingAPIKeyConfigSummary) API Key 配置。请选择覆盖配置或跳过沿用。无论选择哪一种，完成后都会重启 Gateway 并打开 GUI。")
        }
    }

    @ViewBuilder
    private var openClawContent: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                contentColumns
            }
        } else {
            contentColumns
        }
    }

    private var contentColumns: some View {
        HStack(alignment: .top, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    actionBar
                    environmentPanel
                    deployForm
                    channelPanel
                }
                .padding(.vertical, 4)
            }
            .frame(width: 510)

            VStack(alignment: .leading, spacing: 12) {
                logHeader
                progressPanel
                logPanel
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .openClawGlassSurface(tint: Color.musicPanelBackground)
        }
        .padding(.top, 42)
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            AppIconBadge()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("OpenClaw 一键部署工具")
                    .font(.title2.bold())
                Text("一键部署OpenClaw，妈妈再也不用担心我看不懂命令行了！")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            StatusPill(
                text: runner.isRunning ? "运行中" : "就绪",
                systemImage: runner.isRunning ? "bolt.horizontal.circle.fill" : "checkmark.circle.fill",
                color: .musicAccent
            )
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
    }

    private var environmentPanel: some View {
        SectionBox(title: "系统检查", systemImage: "desktopcomputer") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                EnvRow(label: "系统", value: "\(runner.snapshot.osName) \(runner.snapshot.osVersion)")
                EnvRow(label: "架构", value: runner.snapshot.architecture)
                EnvRow(label: "最新 LTS Node", value: runner.snapshot.latestNodeLTS)
                EnvRow(label: "本机 Node", value: runner.snapshot.nodeVersion)
                EnvRow(label: "npm", value: runner.snapshot.npmVersion)
                EnvRow(label: "pnpm", value: runner.snapshot.pnpmVersion)
                EnvRow(label: "Git", value: runner.snapshot.gitVersion)
                EnvRow(label: "OpenClaw", value: runner.snapshot.openclawVersion)
            }

            Button {
                runner.refreshEnvironment()
            } label: {
                Label("重新检查", systemImage: "arrow.clockwise")
            }
            .disabled(runner.isRunning)
        }
    }

    private var deployForm: some View {
        SectionBox(title: "部署配置", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("npm/pnpm 镜像源（空为直连）", text: $mirrorURL)
                    .openClawTextFieldSurface()

                Picker("模型提供商", selection: $modelProvider) {
                    ForEach(OpenClawModelProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                if modelProvider == .qwenCloud {
                    Picker("Qwen Cloud 认证类型", selection: $qwenAuthChoice) {
                        ForEach(QwenCloudAuthChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                }

                SecureField(deployConfig.modelAPIKeyPlaceholder, text: $modelAPIKey)
                    .openClawTextFieldSurface()

                Text("部署会先处理 Steam++ Git 加速提示、Xcode Command Line Tools、nvm/Node 24，并把 nvm 配置写入 ~/.zshrc。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(deployConfig.modelProviderSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("安装 Claude Code", isOn: $installClaudeCode)
                    .toggleStyle(.switch)
                Toggle("安装 agency-agents 并生成 OpenClaw workspaces", isOn: $installAgencyAgents)
                    .toggleStyle(.switch)
                Toggle("安装/刷新 Gateway LaunchAgent", isOn: $installGatewayDaemon)
                    .toggleStyle(.switch)
                Toggle("部署完成后打开 OpenClaw Dashboard", isOn: $openDashboard)
                    .toggleStyle(.switch)

                Text("若检测到本机已有 OpenClaw API Key 配置，部署前会先提示“覆盖配置”或“跳过沿用”；无论选择哪一种，完成后都会重启 Gateway 并打开 GUI。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var channelPanel: some View {
        SectionBox(title: "频道账号", systemImage: "message.badge") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($channels) { $channel in
                    ChannelRow(channel: $channel)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await handleDeployAction()
                }
            } label: {
                Label("一键部署", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .openClawPrimaryButtonStyle()
            .disabled(runner.isRunning)

            Button {
                runner.clearLogs()
            } label: {
                Label("清空日志", systemImage: "trash")
            }
            .controlSize(.large)
            .openClawSecondaryButtonStyle()
            .disabled(runner.isRunning)
        }
    }

    private var deployConfig: DeployConfig {
        DeployConfig(
            mirrorURL: mirrorURL.trimmingCharacters(in: .whitespacesAndNewlines),
            modelProvider: modelProvider,
            modelAPIKey: modelAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            qwenAuthChoice: qwenAuthChoice,
            channels: channels,
            installClaudeCode: installClaudeCode,
            installAgencyAgents: installAgencyAgents,
            installGatewayDaemon: installGatewayDaemon,
            openDashboard: openDashboard
        )
    }

    private func handleDeployAction() async {
        let config = deployConfig
        if let existingConfig = await runner.detectExistingOpenClawAPIKeyConfiguration() {
            pendingDeployConfig = config
            existingAPIKeyConfigSummary = existingConfig.summary
            showExistingAPIKeyDialog = true
            return
        }
        runner.startDeployment(config: config)
    }

    private func startPendingDeployment(action: ExistingAPIKeyAction) {
        var config = pendingDeployConfig ?? deployConfig
        config.existingAPIKeyAction = action
        config.forceRestartAndOpenDashboard = true
        pendingDeployConfig = nil
        existingAPIKeyConfigSummary = ""
        runner.startDeployment(config: config)
    }

    private var logHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("执行日志")
                    .font(.title3.bold())
                Text(runner.currentStep)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if runner.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: runner.progress)
                .tint(.musicAccent)
            Text("模型 API Key 与频道 token 会在日志里自动脱敏；Gateway 会先完成 local 配置，再按需要 restart / start，必要时 fallback 到临时 gateway run。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var logPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(runner.logs) { line in
                        LogRow(line: line)
                            .id(line.id)
                    }
                }
            }
            .onChange(of: runner.logs.count) { _ in
                if let last = runner.logs.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

@MainActor
private extension DeploymentRunner {
    static var preview: DeploymentRunner {
        let runner = DeploymentRunner()
        runner.snapshot = EnvironmentSnapshot(
            osName: "macOS",
            osVersion: "26.0",
            architecture: "arm64",
            latestNodeLTS: "v24.x LTS",
            nodeVersion: "v24.0.0",
            npmVersion: "11.0.0",
            pnpmVersion: "10.0.0",
            gitVersion: "git version 2.50.0",
            openclawVersion: "openclaw 0.2.0"
        )
        runner.logs = [
            LogLine(level: .info, message: "macOS 26 UI 预览模式，不会执行部署命令。"),
            LogLine(level: .command, message: "$ openclaw setup --non-interactive --mode local"),
            LogLine(level: .ok, message: "完成：初始化 OpenClaw local 配置"),
            LogLine(level: .warning, message: "Telegram token 未填写，真实部署前需要补齐。")
        ]
        runner.currentStep = "macOS 26 UI 预览"
        runner.progress = 0.62
        return runner
    }
}

private extension View {
    @ViewBuilder
    func openClawWindowContainer() -> some View {
        if #available(macOS 26.0, *) {
            backgroundExtensionEffect()
        } else if #available(macOS 15.0, *) {
            containerBackground(.clear, for: .window)
        } else {
            self
        }
    }

    @ViewBuilder
    func openClawGlassSurface(tint: Color? = nil) -> some View {
        background(tint ?? Color.musicPanelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.045), radius: 18, x: 0, y: 8)
    }

    @ViewBuilder
    func openClawTextFieldSurface() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.musicControlBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    func openClawPrimaryButtonStyle() -> some View {
        buttonStyle(MusicPrimaryButtonStyle())
    }

    @ViewBuilder
    func openClawSecondaryButtonStyle() -> some View {
        buttonStyle(MusicPillButtonStyle())
    }
}

private extension Color {
    static let musicAccent = Color(red: 0.98, green: 0.14, blue: 0.27)
    static let musicWindowBackground = Color(red: 0.94, green: 0.93, blue: 0.915)
    static let musicPanelBackground = Color(red: 0.985, green: 0.98, blue: 0.965)
    static let musicControlBackground = Color(red: 0.90, green: 0.895, blue: 0.885)
}

private struct MusicPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.musicAccent)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(
                Color.musicControlBackground.opacity(configuration.isPressed ? 0.82 : 1),
                in: Capsule()
            )
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct MusicPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.musicAccent.opacity(0.62))
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(backgroundColor(isPressed: configuration.isPressed), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if !isEnabled {
            return Color.musicAccent.opacity(0.12)
        }
        return Color.musicAccent.opacity(isPressed ? 0.82 : 1)
    }
}

#Preview("macOS 26 UI") {
    ContentView(runner: .preview, autoRefresh: false)
        .frame(width: 1080, height: 740)
}

private struct OpenClawBackdrop: View {
    var body: some View {
        ZStack {
            WindowMaterialBackground()
            Rectangle()
                .fill(Color.musicWindowBackground)
            Rectangle()
                .fill(Color.white.opacity(0.18))
        }
        .ignoresSafeArea()
    }
}

private struct WindowMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .underWindowBackground
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

private struct StatusPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .openClawCapsuleSurface(color: color)
            .labelStyle(.titleAndIcon)
    }
}

private extension View {
    @ViewBuilder
    func openClawCapsuleSurface(color: Color) -> some View {
        background(Color.musicControlBackground, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(color.opacity(0.18), lineWidth: 0.5)
            }
    }
}

private struct AppIconBadge: View {
    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "terminal.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor)
            }
        }
    }

    private static var image: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        for bundleURL in swiftPMResourceBundleURLs {
            if let bundle = Bundle(url: bundleURL),
               let url = bundle.url(forResource: "AppIcon", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return NSApplication.shared.applicationIconImage
    }

    private static var swiftPMResourceBundleURLs: [URL] {
        let bundleName = "OpenClawDeployer_OpenClawDeployer.bundle"
        return [
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.resourceURL?.appendingPathComponent(bundleName)
        ].compactMap { $0 }
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            content
        }
        .padding(14)
        .openClawGlassSurface(tint: Color.musicPanelBackground)
    }
}

private struct EnvRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct ChannelRow: View {
    @Binding var channel: ChannelFormState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: $channel.isEnabled)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(channel.definition.name)
                            .font(.body.weight(.semibold))
                        Text(channel.definition.setupKind.label)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(channel.definition.isAutomatable ? Color.musicAccent.opacity(0.12) : Color.gray.opacity(0.12))
                            .foregroundStyle(channel.definition.isAutomatable ? Color.musicAccent : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Text(channel.definition.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if channel.isEnabled {
                if channel.definition.isAutomatable {
                    SecureField(channel.definition.tokenLabel, text: $channel.token)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text("该频道需要扫码、OAuth、Webhook 或额外服务配置；本工具会安装 OpenClaw，但不会伪装成可静默完成。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
    }
}

private struct LogRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(line.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var icon: String {
        switch line.level {
        case .info: return "info.circle"
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .command: return "chevron.right"
        }
    }

    private var color: Color {
        switch line.level {
        case .info: return .blue
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        case .command: return .secondary
        }
    }
}
