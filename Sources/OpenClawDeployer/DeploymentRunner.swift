import Darwin
import Foundation
import SwiftUI

@MainActor
final class DeploymentRunner: ObservableObject {
    @Published var snapshot = EnvironmentSnapshot()
    @Published var logs: [LogLine] = []
    @Published var isRunning = false
    @Published var currentStep = "等待操作"
    @Published var progress: Double = 0

    func clearLogs() {
        logs.removeAll()
    }

    func refreshEnvironment() {
        guard !isRunning else { return }
        isRunning = true
        currentStep = "检查环境"
        progress = 0
        append(.info, "开始检查当前系统与工具链。")

        Task {
            let osVersion = await output("sw_vers -productVersion")
            let arch = await output("uname -m")
            let node = await output(userToolchainCommand("node -v"))
            let npm = await output(userToolchainCommand("npm -v"))
            let pnpm = await output(userToolchainCommand("pnpm -v"))
            let git = await output("git --version")
            let openclaw = await output(userToolchainCommand("openclaw --version"))
            let latest = await fetchLatestNodeLTS()

            snapshot = EnvironmentSnapshot(
                osName: "macOS",
                osVersion: osVersion.emptyFallback("-"),
                architecture: arch.emptyFallback("-"),
                latestNodeLTS: latest.emptyFallback("Node 24 LTS"),
                nodeVersion: node.emptyFallback("未安装"),
                npmVersion: npm.emptyFallback("未安装"),
                pnpmVersion: pnpm.emptyFallback("未安装"),
                gitVersion: git.emptyFallback("未安装"),
                openclawVersion: openclaw.emptyFallback("未安装")
            )
            progress = 1
            currentStep = "环境检查完成"
            isRunning = false
            append(.ok, "环境检查完成：\(snapshot.osName) \(snapshot.osVersion) / \(snapshot.architecture)。")
        }
    }

    func startDeployment(config: DeployConfig) {
        guard !isRunning else { return }
        logs.removeAll()
        isRunning = true
        progress = 0
        currentStep = "准备部署"

        Task {
            do {
                try validate(config)
                try await deploy(config)
                await refreshOpenClawVersionSilently()
                progress = 1
                currentStep = "部署完成"
                append(.ok, "部署流程完成。API Key / 模型配置已跳过，请继续在 CC switch 中维护。")
            } catch {
                currentStep = "部署失败"
                append(.error, error.localizedDescription)
            }
            isRunning = false
        }
    }

    private func refreshOpenClawVersionSilently() async {
        let openclaw = await output(userToolchainCommand("openclaw --version"))
        guard !openclaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        snapshot.openclawVersion = openclaw
    }

    private func validate(_ config: DeployConfig) throws {
        for channel in config.enabledChannels where channel.definition.isAutomatable {
            if channel.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("已启用 \(channel.definition.name)，请填写 \(channel.definition.tokenLabel)。")
            }
        }
    }

    private func deploy(_ config: DeployConfig) async throws {
        let secrets = config.secretsForRedaction
        let env = deploymentEnvironment(config: config)
        let steps: [DeploymentStep] = [
            .init(title: "检查系统架构") { try await self.preflight(config: config, env: env, secrets: secrets) },
            .init(title: "准备 Git 连接加速提示") { try await self.prepareGitAccelerationHint(config: config) },
            .init(title: "检查/安装 Xcode 命令行工具 / Git") { try await self.ensureCommandLineTools(env: env, secrets: secrets) },
            .init(title: "检查/安装 nvm / Node 24") { try await self.installNodeWithNVM(config: config, env: env, secrets: secrets) },
            .init(title: "检查/安装 Homebrew") { try await self.installHomebrew(config: config, env: env, secrets: secrets) },
            .init(title: "检查/安装 Claude Code") { try await self.installClaudeCode(config: config, env: env, secrets: secrets) },
            .init(title: "检查/安装 CC Switch") { try await self.installCCSwitch(config: config, env: env, secrets: secrets) },
            .init(title: "检查/安装 OpenClaw") { try await self.installOpenClaw(env: env, secrets: secrets) },
            .init(title: "初始化 OpenClaw local 配置") { try await self.setupOpenClaw(env: env, secrets: secrets) },
            .init(title: "检查/安装 pnpm") { try await self.installPNPM(config: config, env: env, secrets: secrets) },
            .init(title: "保存频道密钥") { try await self.persistChannelSecrets(config: config) },
            .init(title: "配置频道账号") { try await self.configureChannels(config: config, env: env, secrets: secrets) },
            .init(title: "安装 agency-agents 技能") { try await self.installAgencyAgentsIfNeeded(config: config, env: env, secrets: secrets) },
            .init(title: "启动并验证 Gateway") { try await self.startAndVerifyGateway(config: config, env: env, secrets: secrets) }
        ]

        for (index, step) in steps.enumerated() {
            currentStep = step.title
            progress = Double(index) / Double(steps.count)
            append(.info, "▶ \(step.title)")
            try await step.action()
            append(.ok, "完成：\(step.title)")
        }
    }

    private func prepareGitAccelerationHint(config: DeployConfig) async throws {
        guard usesBuiltinMirrors(config) else {
            append(.info, "镜像源为空，按直连网络执行；跳过 Steam++ / GitHub 加速提示。")
            return
        }
        append(.info, "GitHub / Git 连接较慢时，请先安装并开启 Steam++（Watt Toolkit）的 GitHub 加速：https://steampp.net/")
        append(.info, "Steam++ 是本机网络加速工具，部署器会继续使用 git/curl 执行后续安装。")
    }

    private func ensureCommandLineTools(env: [String: String], secrets: [String]) async throws {
        let command = """
        set -e
        if xcode-select -p >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
          xcode-select -p
          git --version
          exit 0
        fi

        echo "未检测到 Xcode Command Line Tools，正在打开系统安装器..."
        xcode-select --install || true

        if ! xcode-select -p >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
          echo "请在弹出的窗口完成 Xcode Command Line Tools 安装，然后重新运行部署。"
          exit 65
        fi

        git --version
        """
        let result = await run(command, env: env, secrets: secrets)
        if result.exitCode == 65 {
            throw ValidationError("已打开 Xcode Command Line Tools 安装器。请安装完成后重新点击一键部署。")
        }
        try ensureSuccess(result, command: "xcode-select --install")
    }

    private func installNodeWithNVM(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        let mirrorSetup: String
        let nvmInstallScriptURL: String

        if usesBuiltinMirrors(config) {
            mirrorSetup = """
            \(shellProfileHelpers)
            touch "$HOME/.zshrc"
            append_zshrc_line 'export NVM_SOURCE="\(ToolchainDefaults.nvmSource)"'
            append_zshrc_line 'export NVM_NODEJS_ORG_MIRROR="\(ToolchainDefaults.nodeMirror)"'

            export NVM_SOURCE="\(ToolchainDefaults.nvmSource)"
            export NVM_NODEJS_ORG_MIRROR="\(ToolchainDefaults.nodeMirror)"
            """
            nvmInstallScriptURL = ToolchainDefaults.nvmMirrorInstallScriptURL
        } else {
            mirrorSetup = """
            unset NVM_SOURCE
            unset NVM_NODEJS_ORG_MIRROR
            """
            nvmInstallScriptURL = ToolchainDefaults.nvmOfficialInstallScriptURL
        }

        let command = """
        set -euo pipefail
        export NVM_DIR="$HOME/.nvm"

        if [ -s "$NVM_DIR/nvm.sh" ]; then
          . "$NVM_DIR/nvm.sh"
          if nvm version \(ToolchainDefaults.nodeMajorVersion) | grep -vq '^N/A$'; then
            echo "Node \(ToolchainDefaults.nodeMajorVersion) 已通过 nvm 安装，跳过安装。"
            nvm use --delete-prefix \(ToolchainDefaults.nodeMajorVersion)
            node -v
            npm -v
            exit 0
          fi
        fi

        if command -v node >/dev/null 2>&1; then
          echo "检测到本机已安装 Node $(node -v)，跳过 nvm/Node 安装。"
          node -v
          npm -v
          exit 0
        fi

        \(mirrorSetup)

        if [ ! -s "$NVM_DIR/nvm.sh" ]; then
          nvm_install_script="$(mktemp /tmp/nvm-install.XXXXXX)"
          curl -fsSL \(shellQuote(nvmInstallScriptURL)) -o "$nvm_install_script"
          bash "$nvm_install_script"
        fi

        . "$NVM_DIR/nvm.sh"
        nvm install \(ToolchainDefaults.nodeMajorVersion)
        nvm alias default \(ToolchainDefaults.nodeMajorVersion)
        nvm use --delete-prefix \(ToolchainDefaults.nodeMajorVersion)
        node -v
        npm -v
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "install nvm/node")
    }

    private func installHomebrew(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        let mirrorSetup: String

        if usesBuiltinMirrors(config) {
            mirrorSetup = """
            \(shellProfileHelpers)
            touch "$HOME/.zshrc"
            append_zshrc_line 'export HOMEBREW_BREW_GIT_REMOTE="\(ToolchainDefaults.homebrewBrewGitRemote)"'
            append_zshrc_line 'export HOMEBREW_CORE_GIT_REMOTE="\(ToolchainDefaults.homebrewCoreGitRemote)"'
            append_zshrc_line 'export HOMEBREW_BOTTLE_DOMAIN="\(ToolchainDefaults.homebrewBottleDomain)"'
            append_zshrc_line 'export HOMEBREW_API_DOMAIN="\(ToolchainDefaults.homebrewAPIDomain)"'

            export HOMEBREW_BREW_GIT_REMOTE="\(ToolchainDefaults.homebrewBrewGitRemote)"
            export HOMEBREW_CORE_GIT_REMOTE="\(ToolchainDefaults.homebrewCoreGitRemote)"
            export HOMEBREW_BOTTLE_DOMAIN="\(ToolchainDefaults.homebrewBottleDomain)"
            export HOMEBREW_API_DOMAIN="\(ToolchainDefaults.homebrewAPIDomain)"
            """
        } else {
            mirrorSetup = """
            unset HOMEBREW_BREW_GIT_REMOTE
            unset HOMEBREW_CORE_GIT_REMOTE
            unset HOMEBREW_BOTTLE_DOMAIN
            unset HOMEBREW_API_DOMAIN
            """
        }

        let command = """
        set -e
        \(homebrewShellPrelude)
        if command -v brew >/dev/null 2>&1; then
          echo "Homebrew 已安装，跳过安装与镜像写入。"
          brew --version
          brew config
          exit 0
        fi

        \(mirrorSetup)

        \(homebrewShellPrelude)
        homebrew_install_script="$(mktemp /tmp/homebrew-install.XXXXXX)"
        curl -fsSL https://github.com/Homebrew/install/HEAD/install.sh -o "$homebrew_install_script"
        NONINTERACTIVE=1 /bin/bash "$homebrew_install_script"
        \(homebrewShellPrelude)
        brew --version
        brew config
        brew doctor || true
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "install homebrew")
    }

    private func installClaudeCode(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        guard config.installClaudeCode else {
            append(.info, "已跳过 Claude Code 安装。")
            return
        }

        let registryLine: String
        if config.mirrorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            registryLine = ""
        } else {
            registryLine = "npm config set registry \(shellQuote(config.mirrorURL))"
        }

        let command = """
        set -e
        \(nvmShellPrelude)
        if command -v claude >/dev/null 2>&1; then
          echo "Claude Code 已安装，跳过安装。"
          claude --version || true
          exit 0
        fi
        if npm list -g \(ToolchainDefaults.claudeCodePackage) --depth=0 >/dev/null 2>&1; then
          echo "Claude Code npm 包已安装，跳过安装。"
          npm list -g \(ToolchainDefaults.claudeCodePackage) --depth=0
          exit 0
        fi
        \(registryLine)
        npm install -g \(ToolchainDefaults.claudeCodePackage)
        claude --version || true
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "install claude-code")
    }

    private func installCCSwitch(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        guard config.installCCSwitch else {
            append(.info, "已跳过 CC Switch 安装。")
            return
        }

        let command = """
        set -e
        \(homebrewShellPrelude)
        if [ -d "/Applications/CC Switch.app" ] || [ -d "$HOME/Applications/CC Switch.app" ]; then
          echo "CC Switch 已安装，跳过安装。"
          exit 0
        fi
        if ! command -v brew >/dev/null 2>&1; then
          echo "Homebrew 未安装，无法继续安装 CC Switch。"
          exit 1
        fi
        if brew list --cask cc-switch >/dev/null 2>&1; then
          echo "CC Switch 已通过 Homebrew 安装，跳过安装。"
          brew list --cask cc-switch
          exit 0
        fi

        brew tap | grep -Fxq farion1231/ccswitch || brew tap farion1231/ccswitch
        brew install --cask cc-switch
        brew list --cask cc-switch
        """
        let result = await run(command, env: env, secrets: secrets)
        if result.exitCode == 0 {
            return
        }

        guard !usesBuiltinMirrors(config), shouldRetryCCSwitchWithGitAcceleration(result) else {
            try ensureSuccess(result, command: "install cc-switch")
            return
        }

        append(.warning, "CC Switch 直连下载失败，正在尝试拉起 Git 加速工具。")
        switch await openCCSwitchGitAccelerationFallback() {
        case .openedApp(let appName):
            append(.info, "已打开 \(appName)。请确认 GitHub 加速已开启，5 秒后自动重试 CC Switch 下载。")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let retryResult = await run(command, env: env, secrets: secrets)
            if retryResult.exitCode == 0 {
                append(.ok, "CC Switch 已在 Git 加速 fallback 后安装完成。")
                return
            }
            append(.warning, "CC Switch 已在 \(appName) Git 加速后自动重试一次，但下载仍未成功；已跳过该步骤。请手动下载 CC Switch：\(ToolchainDefaults.ccSwitchManualDownloadPage)")
            return
        case .failed:
            append(.warning, "CC Switch 直连下载失败，且未检测到可用的 Git 加速工具；已跳过该步骤。请手动下载 CC Switch：\(ToolchainDefaults.ccSwitchManualDownloadPage)")
            return
        }
    }

    private func preflight(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        let result = await run("uname -s && uname -m && sw_vers -productVersion", env: env, secrets: secrets)
        try ensureSuccess(result, command: "system preflight")
        if usesBuiltinMirrors(config) {
            append(.info, "已设置 npm/pnpm 镜像源：\(config.mirrorURL)")
        } else {
            append(.info, "镜像源为空，将使用直连；不会注入 nvm/Homebrew 内置镜像，也不会提示 Git 加速。")
        }
    }

    private func installOpenClaw(env: [String: String], secrets: [String]) async throws {
        let installCommand = """
        set -e
        \(nvmShellPrelude)
        if command -v openclaw >/dev/null 2>&1; then
          openclaw --version
        else
          curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-prompt --no-onboard
        fi
        node -v
        npm -v
        git --version
        openclaw --version
        """
        append(.command, "检查 OpenClaw；如已安装则跳过，缺失时运行官方安装器。")
        let result = await run(installCommand, env: env, secrets: secrets)
        try ensureSuccess(result, command: "openclaw installer")
    }

    private func setupOpenClaw(env: [String: String], secrets: [String]) async throws {
        let workspace = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/workspace")
            .path
        let command = """
        set -e
        \(nvmShellPrelude)
        mkdir -p \(shellQuote(workspace))
        openclaw setup --non-interactive --mode local --workspace \(shellQuote(workspace)) || openclaw setup --workspace \(shellQuote(workspace))
        openclaw config set gateway.mode local || true
        openclaw config set agents.defaults.workspace \(shellQuote(workspace)) || true
        openclaw doctor --fix --non-interactive || true
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "openclaw setup")
    }

    private func installPNPM(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        let registryLine: String
        if config.mirrorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            registryLine = ""
        } else {
            registryLine = "npm config set registry \(shellQuote(config.mirrorURL))"
        }

        let command = """
        set -e
        \(nvmShellPrelude)
        if command -v pnpm >/dev/null 2>&1; then
          echo "pnpm 已安装，跳过安装。"
          pnpm --version
          exit 0
        fi
        \(registryLine)
        if command -v corepack >/dev/null 2>&1; then
          corepack enable || true
          corepack prepare pnpm@latest --activate || true
        fi
        command -v pnpm >/dev/null 2>&1 || npm install -g pnpm@latest
        pnpm --version
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "install pnpm")
    }

    private func persistChannelSecrets(config: DeployConfig) async throws {
        let secretsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)

        for channel in config.enabledChannels where channel.definition.isAutomatable {
            let tokenFile = secretsDir.appendingPathComponent("\(channel.definition.id).token")
            try writePrivateFile(tokenFile, contents: channel.token + "\n")
            append(.info, "已保存 \(channel.definition.name) 密钥文件：\(tokenFile.path)")
        }
    }

    private func configureChannels(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        var didRun = false

        for channel in config.enabledChannels {
            guard channel.definition.isAutomatable else {
                append(.warning, "\(channel.definition.name) 需要 \(channel.definition.setupKind.label) 流程，已保留选择但跳过自动配置。")
                continue
            }

            didRun = true
            let tokenFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".openclaw/secrets/\(channel.definition.id).token")
                .path
            let command = channel.definition.id == "nostr" ? nostrAddCommand(channel: channel.definition.id) : tokenAddCommand(channel: channel.definition.id, tokenFile: tokenFile)
            var channelEnv = env
            channelEnv["OPENCLAW_CHANNEL_TOKEN"] = channel.token
            append(.command, "配置频道：\(channel.definition.name)")
            let result = await run(command, env: channelEnv, secrets: secrets)
            if result.exitCode != 0 {
                append(.warning, "\(channel.definition.name) 自动配置未成功；可运行 openclaw channels add --channel \(channel.definition.id) --help 查看该频道最新参数。")
            }
        }

        if !didRun {
            append(.info, "没有需要自动 token 配置的频道。")
        }
    }

    private func tokenAddCommand(channel: String, tokenFile: String) -> String {
        """
        \(nvmShellPrelude)
        set +e
        openclaw channels add --channel \(shellQuote(channel)) --token "$OPENCLAW_CHANNEL_TOKEN"
        STATUS=$?
        if [ "$STATUS" -ne 0 ]; then openclaw channels add --channel \(shellQuote(channel)) --bot-token "$OPENCLAW_CHANNEL_TOKEN"; STATUS=$?; fi
        if [ "$STATUS" -ne 0 ]; then openclaw channels add --channel \(shellQuote(channel)) --app-token "$OPENCLAW_CHANNEL_TOKEN"; STATUS=$?; fi
        if [ "$STATUS" -ne 0 ]; then openclaw channels add --channel \(shellQuote(channel)) --token-file \(shellQuote(tokenFile)); STATUS=$?; fi
        exit "$STATUS"
        """
    }

    private func nostrAddCommand(channel: String) -> String {
        """
        \(nvmShellPrelude)
        set +e
        openclaw channels add --channel \(shellQuote(channel)) --private-key "$OPENCLAW_CHANNEL_TOKEN"
        STATUS=$?
        if [ "$STATUS" -ne 0 ]; then openclaw channels add --channel \(shellQuote(channel)) --token "$OPENCLAW_CHANNEL_TOKEN"; STATUS=$?; fi
        exit "$STATUS"
        """
    }

    private func installAgencyAgentsIfNeeded(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        guard config.installAgencyAgents else {
            append(.info, "已跳过 agency-agents 技能安装。")
            return
        }

        let repoDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/source/agency-agents")
            .path

        let command = """
        set -e
        \(nvmShellPrelude)
        mkdir -p \(shellQuote((repoDir as NSString).deletingLastPathComponent))
        if [ -d \(shellQuote(repoDir + "/.git")) ]; then
          echo "agency-agents 源目录已存在，跳过 clone 与安装脚本。"
          exit 0
        fi
        if [ -d \(shellQuote(repoDir)) ]; then
          echo "agency-agents 目录已存在，跳过安装以避免覆盖。"
          exit 0
        else
          git clone https://github.com/hotjp/agency-agents.git \(shellQuote(repoDir))
        fi
        cd \(shellQuote(repoDir))
        ./scripts/convert.sh --tool openclaw
        ./scripts/install.sh --tool openclaw
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "install agency-agents")
    }

    private func startAndVerifyGateway(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        let dashboardLine = config.openDashboard ? "openclaw dashboard >/dev/null 2>&1 &" : ""
        let installLine = config.installGatewayDaemon ? "openclaw gateway install || true" : ""
        let command = """
        set +e
        \(nvmShellPrelude)
        openclaw gateway status --require-rpc
        STATUS=$?
        if [ "$STATUS" -ne 0 ]; then
          \(installLine)
          openclaw gateway start || openclaw gateway restart || true
          sleep 2
          openclaw gateway status --require-rpc
          STATUS=$?
        fi
        if [ "$STATUS" -ne 0 ]; then
          mkdir -p "$HOME/.openclaw/logs"
          nohup openclaw gateway run --allow-unconfigured --force > "$HOME/.openclaw/logs/gateway-fallback.log" 2>&1 &
          sleep 2
          openclaw gateway status --require-rpc
          STATUS=$?
        fi
        openclaw gateway status || true
        openclaw channels status --probe || openclaw channels status || true
        \(dashboardLine)
        exit 0
        """
        let result = await run(command, env: env, secrets: secrets)
        if result.exitCode != 0 {
            append(.warning, "Gateway 启动状态未确认；已避免让部署流程在 restart 上硬失败。")
        }
    }

    private func deploymentEnvironment(config: DeployConfig) -> [String: String] {
        var extra: [String: String] = [
            "OPENCLAW_NO_PROMPT": "1",
            "OPENCLAW_NO_ONBOARD": "1",
            "SHARP_IGNORE_GLOBAL_LIBVIPS": "1",
            "NVM_DIR": "\(FileManager.default.homeDirectoryForCurrentUser.path)/.nvm"
        ]

        let mirror = config.mirrorURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesBuiltinMirrors(config) {
            extra["NVM_SOURCE"] = ToolchainDefaults.nvmSource
            extra["NVM_NODEJS_ORG_MIRROR"] = ToolchainDefaults.nodeMirror
            extra["HOMEBREW_BREW_GIT_REMOTE"] = ToolchainDefaults.homebrewBrewGitRemote
            extra["HOMEBREW_CORE_GIT_REMOTE"] = ToolchainDefaults.homebrewCoreGitRemote
            extra["HOMEBREW_BOTTLE_DOMAIN"] = ToolchainDefaults.homebrewBottleDomain
            extra["HOMEBREW_API_DOMAIN"] = ToolchainDefaults.homebrewAPIDomain
        }
        if !mirror.isEmpty {
            extra["NPM_CONFIG_REGISTRY"] = mirror
            extra["npm_config_registry"] = mirror
            extra["COREPACK_NPM_REGISTRY"] = mirror
        }

        return Shell.baseEnvironment(extra: extra)
    }

    private func output(_ command: String) async -> String {
        let result = await Shell.runShell(command)
        guard result.exitCode == 0 else { return "" }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func userToolchainCommand(_ command: String) -> String {
        """
        \(nvmShellPrelude)
        \(command)
        """
    }

    private func fetchLatestNodeLTS() async -> String {
        guard let url = URL(string: "https://nodejs.org/dist/index.json") else { return "" }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let releases = try JSONDecoder().decode([NodeRelease].self, from: data)
            return releases.first(where: { $0.isLTS })?.version ?? ""
        } catch {
            append(.warning, "无法获取最新 Node LTS，部署时会继续使用 nvm 安装 Node 24。")
            return ""
        }
    }

    private func run(_ command: String, env: [String: String], secrets: [String]) async -> CommandResult {
        append(.command, "$ \(Shell.redact(command, secrets: secrets))")
        return await Shell.runShell(
            command,
            environment: env,
            redactedSecrets: secrets,
            log: { chunk in Task { @MainActor in self.appendOutput(chunk, .command) } }
        )
    }

    private func ensureSuccess(_ result: CommandResult, command: String) throws {
        if result.exitCode != 0 {
            throw ShellError.nonZeroExit(command: command, exitCode: result.exitCode)
        }
    }

    private func append(_ level: LogLine.Level, _ message: String) {
        logs.append(LogLine(level: level, message: message))
    }

    private func appendOutput(_ text: String, _ level: LogLine.Level) {
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            append(level, line)
        }
    }

    private func writePrivateFile(_ url: URL, contents: String) throws {
        try contents.data(using: .utf8)?.write(to: url, options: .atomic)
        chmod(url.path, S_IRUSR | S_IWUSR)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shouldRetryCCSwitchWithGitAcceleration(_ result: CommandResult) -> Bool {
        guard result.exitCode != 0 else { return false }
        let output = result.output.lowercased()
        return output.contains("failed to download resource")
            || output.contains("error: download failed")
            || output.contains("release-assets.githubusercontent.com")
            || output.contains("github.com/")
            || output.contains("ssl_error_syscall")
            || output.contains("curl:")
    }

    private func openCCSwitchGitAccelerationFallback() async -> CCSwitchGitAccelerationFallback {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appCandidates = [
            (path: "/Applications/Watt Toolkit.app", name: "Watt Toolkit"),
            (path: "/Applications/Steam++.app", name: "Steam++"),
            (path: "\(home)/Applications/Watt Toolkit.app", name: "Watt Toolkit"),
            (path: "\(home)/Applications/Steam++.app", name: "Steam++")
        ]

        for candidate in appCandidates where FileManager.default.fileExists(atPath: candidate.path) {
            let result = await Shell.run(
                executable: "/usr/bin/open",
                arguments: [candidate.path]
            )
            if result.exitCode == 0 {
                return .openedApp(candidate.name)
            }
        }

        return .failed
    }

    private func usesBuiltinMirrors(_ config: DeployConfig) -> Bool {
        !config.mirrorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shellProfileHelpers: String {
        """
        append_zshrc_line() {
          local line="$1"
          touch "$HOME/.zshrc"
          grep -Fqx "$line" "$HOME/.zshrc" || printf '\\n%s\\n' "$line" >> "$HOME/.zshrc"
        }
        """
    }

    private var nvmShellPrelude: String {
        """
        export NVM_DIR="$HOME/.nvm"
        if [ -s "$NVM_DIR/nvm.sh" ]; then
          . "$NVM_DIR/nvm.sh"
          nvm use --delete-prefix \(ToolchainDefaults.nodeMajorVersion) >/dev/null 2>&1 || true
        fi
        """
    }

    private var homebrewShellPrelude: String {
        """
        if [ -x /opt/homebrew/bin/brew ]; then
          eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -x /usr/local/bin/brew ]; then
          eval "$(/usr/local/bin/brew shellenv)"
        fi
        """
    }
}

private enum ToolchainDefaults {
    static let nvmSource = "https://gitee.com/mirrors/nvm-sh.git"
    static let nvmMirrorInstallScriptURL = "https://gitee.com/mirrors/nvm-sh/raw/v0.40.4/install.sh"
    static let nvmOfficialInstallScriptURL = "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh"
    static let nodeMirror = "https://npmmirror.com/mirrors/node"
    static let nodeMajorVersion = "24"
    static let claudeCodePackage = "@anthropic-ai/claude-code"
    static let homebrewBrewGitRemote = "https://mirrors.ustc.edu.cn/brew.git"
    static let homebrewCoreGitRemote = "https://mirrors.ustc.edu.cn/homebrew-core.git"
    static let homebrewBottleDomain = "https://mirrors.ustc.edu.cn/homebrew-bottles"
    static let homebrewAPIDomain = "https://mirrors.ustc.edu.cn/homebrew-bottles/api"
    static let ccSwitchManualDownloadPage = "https://github.com/farion1231/cc-switch/releases"
}

private struct DeploymentStep {
    let title: String
    let action: () async throws -> Void
}

private enum CCSwitchGitAccelerationFallback {
    case openedApp(String)
    case failed
}

private struct ValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct NodeRelease: Decodable {
    let version: String
    let lts: LTSValue

    var isLTS: Bool {
        switch lts {
        case .bool(let value): return value
        case .string: return true
        }
    }
}

private enum LTSValue: Decodable {
    case bool(Bool)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .string((try? container.decode(String.self)) ?? "")
        }
    }
}

private extension String {
    func emptyFallback(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
