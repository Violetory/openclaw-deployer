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
    private var didConfigureModelProviderThisRun = false
    private var didInstallAgencyAgentsThisRun = false

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
            snapshot = await buildEnvironmentSnapshot()
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
        didConfigureModelProviderThisRun = false
        didInstallAgencyAgentsThisRun = false

        Task {
            do {
                try validate(config)
                try await deploy(config)
                snapshot = await buildEnvironmentSnapshot()
                progress = 1
                currentStep = "部署完成"
                append(.ok, "部署流程完成。OpenClaw 模型/API 配置、频道配置与 Gateway 校验已按当前部署参数执行。")
            } catch {
                currentStep = "部署失败"
                append(.error, error.localizedDescription)
            }
            isRunning = false
        }
    }

    func startUninstall() {
        guard !isRunning else { return }
        logs.removeAll()
        isRunning = true
        progress = 0
        currentStep = "准备卸载"

        Task {
            do {
                let uninstallSnapshot = await buildEnvironmentSnapshot()
                try await uninstall(snapshot: uninstallSnapshot)
                snapshot = await buildEnvironmentSnapshot()
                progress = 1
                currentStep = "卸载完成"
                append(.ok, "卸载流程完成。已按检测结果清理 OpenClaw 及关联环境。")
            } catch {
                currentStep = "卸载失败"
                append(.error, error.localizedDescription)
            }
            isRunning = false
        }
    }

    private func validate(_ config: DeployConfig) throws {
        if config.existingAPIKeyAction != .skipExisting,
           config.modelAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("请填写\(config.modelAPIKeyLabel)。")
        }
        for channel in config.enabledChannels where channel.definition.isAutomatable {
            if channel.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("已启用 \(channel.definition.name)，请填写 \(channel.definition.tokenLabel)。")
            }
        }
    }

    func detectExistingOpenClawAPIKeyConfiguration() async -> ExistingOpenClawAPIKeyConfiguration? {
        return existingOpenClawAPIKeyConfiguration()
    }

    private func deploy(_ config: DeployConfig) async throws {
        let secrets = config.secretsForRedaction
        let env = deploymentEnvironment(config: config)
        let claudeStepTitle = config.forceReinstall ? "重新安装 Claude Code" : "检查/安装 Claude Code"
        let openClawStepTitle = config.forceReinstall ? "重新安装 OpenClaw" : "检查/安装 OpenClaw"
        let pnpmStepTitle = config.forceReinstall ? "重新安装 pnpm" : "检查/安装 pnpm"
        let steps: [DeploymentStep] = [
            .init(title: "检查系统架构") { try await self.preflight(config: config, env: env, secrets: secrets) },
            .init(title: "准备 Git 连接加速提示") { try await self.prepareGitAccelerationHint(config: config) },
            .init(title: "检查/安装 Xcode 命令行工具 / Git") { try await self.ensureCommandLineTools(env: env, secrets: secrets) },
            .init(title: "检查/安装 nvm / Node 24") { try await self.installNodeWithNVM(config: config, env: env, secrets: secrets) },
            .init(title: "配置 nvm / Node 全局环境变量") { try await self.configureNVMGlobalEnvironment(config: config, env: env, secrets: secrets) },
            .init(title: "验证 Node / npm 环境") { try await self.verifyNodeAndNPMEnvironment(env: env, secrets: secrets) },
            .init(title: claudeStepTitle) { try await self.installClaudeCode(config: config, env: env, secrets: secrets) },
            .init(title: openClawStepTitle) { try await self.installOpenClaw(config: config, env: env, secrets: secrets) },
            .init(title: "初始化 OpenClaw local 配置") { try await self.setupOpenClaw(env: env, secrets: secrets) },
            .init(title: "配置 OpenClaw 模型 / API") { try await self.configureOpenClawModelProvider(config: config, env: env, secrets: secrets) },
            .init(title: pnpmStepTitle) { try await self.installPNPM(config: config, env: env, secrets: secrets) },
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
        has_apple_dev_tools() {
          local developer_dir=""
          developer_dir="$(xcode-select -p 2>/dev/null || true)"

          if [ -n "$developer_dir" ] && [ -d "$developer_dir" ]; then
            if git --version >/dev/null 2>&1 || xcodebuild -version >/dev/null 2>&1; then
              return 0
            fi
          fi

          if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
            if DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" xcodebuild -version >/dev/null 2>&1; then
              return 0
            fi
          fi

          if pkgutil --pkg-info=com.apple.pkg.CLTools_Executables >/dev/null 2>&1; then
            if git --version >/dev/null 2>&1; then
              return 0
            fi
          fi

          return 1
        }

        if has_apple_dev_tools; then
          xcode-select -p 2>/dev/null || true
          git --version 2>/dev/null || true
          xcodebuild -version 2>/dev/null | head -n 1 || true
          exit 0
        fi

        echo "未检测到 Xcode Command Line Tools，正在打开系统安装器..."
        install_output="$(xcode-select --install 2>&1 || true)"
        [ -n "$install_output" ] && echo "$install_output"

        if has_apple_dev_tools; then
          xcode-select -p 2>/dev/null || true
          git --version 2>/dev/null || true
          exit 0
        fi

        if printf '%s' "$install_output" | grep -qi "already installed"; then
          echo "系统报告开发者工具已安装，但当前会话未检测到可用工具。"
        fi

        if ! has_apple_dev_tools; then
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

    private func configureNVMGlobalEnvironment(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        let zshrcLines = (usesBuiltinMirrors(config) ? nvmZshrcLines : directNvmZshrcLines)
            .map { "append_zshrc_line \(shellQuote($0))" }
            .joined(separator: "\n")
        let cleanupCommands = usesBuiltinMirrors(config) ? "" : """
        remove_zshrc_line \(shellQuote("export NVM_SOURCE=\"\(ToolchainDefaults.nvmSource)\""))
        remove_zshrc_line \(shellQuote("export NVM_NODEJS_ORG_MIRROR=\"\(ToolchainDefaults.nodeMirror)\""))
        """
        let validationCommand = """
        source "$HOME/.zshrc"
        if [ -n "\(usesBuiltinMirrors(config) ? "1" : "")" ]; then
          export NVM_SOURCE="\(ToolchainDefaults.nvmSource)"
          export NVM_NODEJS_ORG_MIRROR="\(ToolchainDefaults.nodeMirror)"
        else
          unset NVM_SOURCE
          unset NVM_NODEJS_ORG_MIRROR
        fi
        command -v nvm >/dev/null 2>&1
        nvm use --delete-prefix \(ToolchainDefaults.nodeMajorVersion) >/dev/null 2>&1 || true
        node -v
        npm -v
        """
        let command = """
        set -euo pipefail
        \(shellProfileHelpers)
        export NVM_DIR="$HOME/.nvm"

        if [ ! -s "$NVM_DIR/nvm.sh" ]; then
          echo "未找到 $NVM_DIR/nvm.sh，请先完成 nvm 安装。"
          exit 1
        fi

        touch "$HOME/.zshrc"
        \(cleanupCommands)
        \(zshrcLines)

        /bin/zsh -lc \(shellQuote(validationCommand))
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "configure nvm/node global environment")
    }

    private func verifyNodeAndNPMEnvironment(env: [String: String], secrets: [String]) async throws {
        let command = """
        set -euo pipefail
        /bin/zsh -lc \(shellQuote("""
        source "$HOME/.zshrc"
        export NVM_SOURCE="\(ToolchainDefaults.nvmSource)"
        export NVM_NODEJS_ORG_MIRROR="\(ToolchainDefaults.nodeMirror)"
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        nvm use \(ToolchainDefaults.nodeMajorVersion) >/dev/null 2>&1 || true
        which node
        which npm
        node -v
        npm -v
        """))
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "verify node/npm environment")
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
        if [ -n "\(config.forceReinstall ? "1" : "")" ]; then
          echo "重新安装 Claude Code..."
          if command -v npm >/dev/null 2>&1 && npm list -g \(ToolchainDefaults.claudeCodePackage) --depth=0 >/dev/null 2>&1; then
            npm uninstall -g \(ToolchainDefaults.claudeCodePackage) || true
          fi
          hash -r || true
        fi
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

    private func preflight(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        let result = await run("uname -s && uname -m && sw_vers -productVersion", env: env, secrets: secrets)
        try ensureSuccess(result, command: "system preflight")
        if config.forceReinstall {
            append(.info, "已启用重新安装模式：会刷新 OpenClaw，以及当前勾选的 Claude Code / pnpm 组件。")
        }
        if usesBuiltinMirrors(config) {
            append(.info, "已设置 npm/pnpm 镜像源：\(config.mirrorURL)")
        } else {
            append(.info, "镜像源为空，将使用直连；不会注入 nvm/Homebrew 内置镜像，也不会提示 Git 加速。")
        }
    }

    private func installOpenClaw(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        let registryLine: String
        if config.mirrorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            registryLine = ""
        } else {
            registryLine = "npm config set registry \(shellQuote(config.mirrorURL))"
        }

        let installCommand = """
        set -e
        \(nvmShellPrelude)
        if [ -n "\(config.forceReinstall ? "1" : "")" ]; then
          echo "重新安装 OpenClaw..."
          if command -v npm >/dev/null 2>&1 && npm list -g openclaw --depth=0 >/dev/null 2>&1; then
            npm uninstall -g openclaw || true
          fi
          hash -r || true
        fi
        if command -v openclaw >/dev/null 2>&1; then
          openclaw --version
        else
          \(registryLine)
          npm install -g openclaw@latest
        fi
        node -v
        npm -v
        git --version
        openclaw --version
        """
        append(.command, "检查 OpenClaw；如已安装则跳过，缺失时通过 npm 全局安装。")
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

    private func configureOpenClawModelProvider(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        if config.existingAPIKeyAction == .skipExisting,
           let existingConfig = existingOpenClawAPIKeyConfiguration() {
            append(.info, "检测到本机已有 \(existingConfig.summary) API Key 配置，按用户选择跳过覆盖，沿用现有配置。")
            return
        }

        let stateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw", isDirectory: true)
        let configURL = stateDir.appendingPathComponent("openclaw.json")
        let agentDir = stateDir.appendingPathComponent("agents/main/agent", isDirectory: true)
        let modelsURL = agentDir.appendingPathComponent("models.json")
        let authProfilesURL = agentDir.appendingPathComponent("auth-profiles.json")

        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)

        var openClawConfig = try loadJSONObject(at: configURL)
        applyModelProviderConfig(&openClawConfig, deployConfig: config)
        try writeJSONObject(openClawConfig, to: configURL)

        var modelsConfig = try loadJSONObject(at: modelsURL)
        applyAgentModelsConfig(&modelsConfig, deployConfig: config)
        try writeJSONObject(modelsConfig, to: modelsURL)

        var authProfiles = try loadJSONObject(at: authProfilesURL)
        applyAuthProfilesConfig(&authProfiles, deployConfig: config)
        try writeJSONObject(authProfiles, to: authProfilesURL)

        didConfigureModelProviderThisRun = true

        let providerSummary = config.modelProvider == .qwenCloud
            ? "\(config.modelProvider.title)（\(config.qwenAuthChoice.title)）"
            : config.modelProvider.title
        append(.info, "已写入 \(providerSummary) 模型配置：主模型 \(config.effectivePrimaryModel)。")

        let command = """
        set -e
        \(nvmShellPrelude)
        openclaw config validate
        openclaw models status --json || openclaw models status
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "configure openclaw model/api")
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
        if [ -n "\(config.forceReinstall ? "1" : "")" ]; then
          echo "重新安装 pnpm..."
          if command -v npm >/dev/null 2>&1 && npm list -g pnpm --depth=0 >/dev/null 2>&1; then
            npm uninstall -g pnpm || true
          fi
          hash -r || true
        fi
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
        let willInstallAgencyAgents = !FileManager.default.fileExists(atPath: repoDir)
        let shouldRefreshExistingInstall = config.forceReinstall

        let command = """
        set -e
        \(nvmShellPrelude)
        mkdir -p \(shellQuote((repoDir as NSString).deletingLastPathComponent))
        if [ -d \(shellQuote(repoDir + "/.git")) ]; then
          echo "agency-agents 源目录已存在。"
          if [ -z "\(shouldRefreshExistingInstall ? "1" : "")" ]; then
            echo "跳过 clone 与安装脚本。"
            exit 0
          fi
          echo "重新安装模式下会刷新 agency-agents 安装脚本。"
        fi
        if [ -d \(shellQuote(repoDir)) ]; then
          if [ -z "\(shouldRefreshExistingInstall ? "1" : "")" ] && [ ! -d \(shellQuote(repoDir + "/.git")) ]; then
            echo "agency-agents 目录已存在，跳过安装以避免覆盖。"
            exit 0
          fi
        else
          git clone \(shellQuote(ToolchainDefaults.agencyAgentsRepoURL)) \(shellQuote(repoDir))
        fi
        cd \(shellQuote(repoDir))
        ./scripts/convert.sh --tool openclaw
        ./scripts/install.sh --tool openclaw
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "install agency-agents")
        didInstallAgencyAgentsThisRun = willInstallAgencyAgents
    }

    private func startAndVerifyGateway(config: DeployConfig, env: [String: String], secrets: [String]) async throws {
        let dashboardLine = (config.openDashboard || config.forceRestartAndOpenDashboard) ? "openclaw dashboard >/dev/null 2>&1 &" : ""
        let installLine = config.installGatewayDaemon ? "openclaw gateway install || true" : ""
        let reloadReasons = [
            didConfigureModelProviderThisRun ? "模型/API 配置" : nil,
            didInstallAgencyAgentsThisRun ? "agency-agents" : nil,
            (!didConfigureModelProviderThisRun && config.forceRestartAndOpenDashboard) ? "沿用现有 API Key 配置" : nil
        ].compactMap { $0 }
        let restartGatewayFunction = """
        restart_gateway() {
          openclaw gateway stop || true
          pkill -f openclaw || true
          PIDS="$(lsof -ti :18789 || true)"
          [ -n "$PIDS" ] && kill -9 $PIDS || true
          openclaw gateway start || true
          openclaw gateway status || true
        }
        """
        let reloadGatewayLine = reloadReasons.isEmpty ? "" : """
        if openclaw gateway status --require-rpc >/dev/null 2>&1; then
          echo "\(reloadReasons.joined(separator: "、")) 已更新，正在重启 Gateway 以应用最新配置。"
          restart_gateway
          sleep 2
        fi
        """
        let command = """
        set +e
        \(nvmShellPrelude)
        \(restartGatewayFunction)
        \(reloadGatewayLine)
        openclaw gateway status --require-rpc
        STATUS=$?
        if [ "$STATUS" -ne 0 ]; then
          \(installLine)
          restart_gateway
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

    private func uninstall(snapshot: EnvironmentSnapshot) async throws {
        guard snapshot.installState.hasManagedArtifacts else {
            append(.warning, "未检测到 OpenClaw 或部署器关联环境，跳过卸载命令。")
            return
        }

        let env = uninstallEnvironment()
        let secrets: [String] = []
        let steps: [DeploymentStep] = [
            .init(title: "停止 Gateway 与后台进程") { try await self.stopOpenClawProcesses(env: env, secrets: secrets) },
            .init(title: "执行 OpenClaw 官方卸载") { try await self.runOfficialOpenClawUninstall(env: env, secrets: secrets) },
            .init(title: "卸载全局 npm 包") { try await self.uninstallManagedGlobalPackages(snapshot: snapshot, env: env, secrets: secrets) },
            .init(title: "清理残留目录与 LaunchAgent") { try await self.cleanupOpenClawResidues(env: env, secrets: secrets) },
            .init(title: "清理 Shell 与 nvm 环境") { try await self.cleanupManagedShellEnvironment(snapshot: snapshot, env: env, secrets: secrets) }
        ]

        append(.info, "检测到以下可清理项目：\(snapshot.installState.uninstallSummary)")

        for (index, step) in steps.enumerated() {
            currentStep = step.title
            progress = Double(index) / Double(steps.count)
            append(.info, "▶ \(step.title)")
            try await step.action()
            append(.ok, "完成：\(step.title)")
        }
    }

    private func buildEnvironmentSnapshot() async -> EnvironmentSnapshot {
        let osVersion = await output("sw_vers -productVersion")
        let arch = await output("uname -m")
        let node = await output(userToolchainCommand("node -v"))
        let npm = await output(userToolchainCommand("npm -v"))
        let pnpm = await output(userToolchainCommand("pnpm -v"))
        let git = await output("git --version")
        let openclaw = await output(userToolchainCommand("openclaw --version"))
        let latest = await fetchLatestNodeLTS()
        let installState = await detectManagedInstallState(
            openClawInstalled: !openclaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            pnpmInstalled: !pnpm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )

        return EnvironmentSnapshot(
            osName: "macOS",
            osVersion: osVersion.emptyFallback("-"),
            architecture: arch.emptyFallback("-"),
            latestNodeLTS: latest.emptyFallback("Node 24 LTS"),
            nodeVersion: node.emptyFallback("未安装"),
            npmVersion: npm.emptyFallback("未安装"),
            pnpmVersion: pnpm.emptyFallback("未安装"),
            gitVersion: git.emptyFallback("未安装"),
            openclawVersion: openclaw.emptyFallback("未安装"),
            installState: installState
        )
    }

    private func detectManagedInstallState(openClawInstalled: Bool, pnpmInstalled: Bool) async -> ManagedInstallState {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let stateDirectory = homeDirectory.appendingPathComponent(".openclaw", isDirectory: true)
        let agencyAgentsDirectory = stateDirectory.appendingPathComponent("source/agency-agents", isDirectory: true)
        let nvmDirectory = homeDirectory.appendingPathComponent(".nvm", isDirectory: true)
        let zshrcURL = homeDirectory.appendingPathComponent(".zshrc")
        let launchAgentsDirectory = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let zshrcContents = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        let managedZshrcLines = Array(Set(nvmZshrcLines + directNvmZshrcLines))
        let claude = await output(userToolchainCommand("claude --version"))

        return ManagedInstallState(
            openClawCLIInstalled: openClawInstalled,
            openClawStateDirectoryExists: fileManager.fileExists(atPath: stateDirectory.path),
            agencyAgentsInstalled: fileManager.fileExists(atPath: agencyAgentsDirectory.path),
            gatewayServiceInstalled: !openClawLaunchAgentURLs(in: launchAgentsDirectory).isEmpty,
            claudeCodeInstalled: !claude.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            pnpmInstalled: pnpmInstalled,
            nvmDirectoryExists: fileManager.fileExists(atPath: nvmDirectory.path),
            managedNodeVersionInstalled: hasManagedNodeVersionInstalled(in: nvmDirectory),
            managedZshrcConfigured: managedZshrcLines.contains { line in
                zshrcContents.contains(line)
            }
        )
    }

    private func stopOpenClawProcesses(env: [String: String], secrets: [String]) async throws {
        let command = """
        set +e
        \(nvmShellPrelude)
        if command -v openclaw >/dev/null 2>&1; then
          openclaw gateway stop || true
        fi
        pkill -f 'openclaw gateway' || true
        pkill -f openclaw || true
        PIDS="$(lsof -ti :18789 || true)"
        [ -n "$PIDS" ] && kill -9 $PIDS || true
        exit 0
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "stop openclaw processes")
    }

    private func runOfficialOpenClawUninstall(env: [String: String], secrets: [String]) async throws {
        let command = """
        set +e
        \(nvmShellPrelude)
        if command -v openclaw >/dev/null 2>&1; then
          openclaw gateway uninstall || true
          openclaw uninstall --service --state --workspace --yes --non-interactive || true
        else
          echo "未检测到 openclaw 命令，跳过 OpenClaw 官方卸载命令。"
        fi
        exit 0
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "run openclaw uninstall")
    }

    private func uninstallManagedGlobalPackages(snapshot: EnvironmentSnapshot, env: [String: String], secrets: [String]) async throws {
        let optionalPackageCleanup = snapshot.installState.shouldRemoveOptionalGlobalPackages ? """
        if npm list -g \(ToolchainDefaults.claudeCodePackage) --depth=0 >/dev/null 2>&1; then
          npm uninstall -g \(ToolchainDefaults.claudeCodePackage) || true
        else
          echo "未检测到全局 \(ToolchainDefaults.claudeCodePackage) npm 包。"
        fi
        if npm list -g pnpm --depth=0 >/dev/null 2>&1; then
          npm uninstall -g pnpm || true
        else
          echo "未检测到全局 pnpm npm 包。"
        fi
        """ : """
        echo "未检测到部署器管理的 Claude Code / pnpm 安装痕迹，跳过这两项卸载。"
        """
        let command = """
        set +e
        \(nvmShellPrelude)
        if ! command -v npm >/dev/null 2>&1; then
          echo "未检测到 npm，跳过全局 npm 包卸载。"
          exit 0
        fi
        if npm list -g openclaw --depth=0 >/dev/null 2>&1; then
          npm uninstall -g openclaw || true
        else
          echo "未检测到全局 openclaw npm 包。"
        fi
        \(optionalPackageCleanup)
        exit 0
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "uninstall managed npm packages")
    }

    private func cleanupOpenClawResidues(env: [String: String], secrets: [String]) async throws {
        let command = """
        set +e
        launch_agents_dir="$HOME/Library/LaunchAgents"
        if [ -d "$launch_agents_dir" ]; then
          for plist in "$launch_agents_dir"/*openclaw*.plist; do
            [ -e "$plist" ] || continue
            launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
            rm -f "$plist"
            echo "已移除 LaunchAgent: $plist"
          done
        fi
        if [ -d "$HOME/.openclaw" ]; then
          rm -rf "$HOME/.openclaw"
          echo "已删除 $HOME/.openclaw"
        else
          echo "未检测到 $HOME/.openclaw"
        fi
        exit 0
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "cleanup openclaw residues")
    }

    private func cleanupManagedShellEnvironment(snapshot: EnvironmentSnapshot, env: [String: String], secrets: [String]) async throws {
        let zshrcCleanup = Array(Set(nvmZshrcLines + directNvmZshrcLines))
            .map { "remove_zshrc_line \(shellQuote($0))" }
            .joined(separator: "\n")
        let nvmCleanup = snapshot.installState.hasManagedToolchainArtifacts ? """
        if [ -s "$NVM_DIR/nvm.sh" ]; then
          . "$NVM_DIR/nvm.sh"
          nvm deactivate >/dev/null 2>&1 || true
          if nvm ls \(ToolchainDefaults.nodeMajorVersion) >/dev/null 2>&1; then
            nvm uninstall \(ToolchainDefaults.nodeMajorVersion) || true
          fi
        fi

        can_remove_nvm_dir=1
        if [ -d "$NVM_DIR/versions/node" ]; then
          for version_dir in "$NVM_DIR"/versions/node/*; do
            [ -e "$version_dir" ] || continue
            version_name="$(basename "$version_dir")"
            case "$version_name" in
              v\(ToolchainDefaults.nodeMajorVersion).*) ;;
              *) can_remove_nvm_dir=0 ;;
            esac
          done
        fi
        if [ -d "$NVM_DIR/versions/io.js" ]; then
          for version_dir in "$NVM_DIR"/versions/io.js/*; do
            [ -e "$version_dir" ] || continue
            can_remove_nvm_dir=0
            break
          done
        fi
        if [ "$can_remove_nvm_dir" -eq 1 ] && [ -d "$NVM_DIR" ]; then
          rm -rf "$NVM_DIR"
          echo "已移除部署器管理的 nvm 目录。"
        elif [ -d "$NVM_DIR" ]; then
          echo "检测到 .nvm 中仍有其他 Node 版本，已保留 nvm 目录，仅尝试移除 Node \(ToolchainDefaults.nodeMajorVersion)。"
        else
          echo "未检测到 .nvm 目录。"
        fi
        """ : """
        echo "未检测到部署器管理的 Node / nvm 痕迹，保留现有 .nvm 环境。"
        """
        let command = """
        set +e
        \(shellProfileHelpers)
        \(zshrcCleanup)
        export NVM_DIR="$HOME/.nvm"
        \(nvmCleanup)
        exit 0
        """
        let result = await run(command, env: env, secrets: secrets)
        try ensureSuccess(result, command: "cleanup shell environment")
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
        }
        if !mirror.isEmpty {
            extra["NPM_CONFIG_REGISTRY"] = mirror
            extra["npm_config_registry"] = mirror
            extra["COREPACK_NPM_REGISTRY"] = mirror
        }

        return Shell.baseEnvironment(extra: extra)
    }

    private func uninstallEnvironment() -> [String: String] {
        Shell.baseEnvironment(extra: [
            "OPENCLAW_NO_PROMPT": "1",
            "OPENCLAW_NO_ONBOARD": "1",
            "SHARP_IGNORE_GLOBAL_LIBVIPS": "1",
            "NVM_DIR": "\(FileManager.default.homeDirectoryForCurrentUser.path)/.nvm"
        ])
    }

    private func loadJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ValidationError("\(url.lastPathComponent) 不是合法的 JSON 对象。")
        }
        return dictionary
    }

    private func existingOpenClawAPIKeyConfiguration() -> ExistingOpenClawAPIKeyConfiguration? {
        let stateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw", isDirectory: true)
        let authProfilesURL = stateDir.appendingPathComponent("agents/main/agent/auth-profiles.json")
        let agentModelsURL = stateDir.appendingPathComponent("agents/main/agent/models.json")
        let configURL = stateDir.appendingPathComponent("openclaw.json")

        var providers = Set<OpenClawModelProvider>()

        if let authProfiles = try? loadJSONObject(at: authProfilesURL),
           let profiles = authProfiles["profiles"] as? [String: Any] {
            collectConfiguredProviders(fromAuthProfiles: profiles, into: &providers)
        }

        if let models = try? loadJSONObject(at: agentModelsURL),
           let providerMap = models["providers"] as? [String: Any] {
            collectConfiguredProviders(fromProviderMap: providerMap, into: &providers)
        }

        if let config = try? loadJSONObject(at: configURL) {
            if let env = config["env"] as? [String: Any] {
                collectConfiguredProviders(fromEnv: env, into: &providers)
            }
            if let models = config["models"] as? [String: Any],
               let providerMap = models["providers"] as? [String: Any] {
                collectConfiguredProviders(fromProviderMap: providerMap, into: &providers)
            }
        }

        let orderedProviders = OpenClawModelProvider.allCases.filter { providers.contains($0) }
        guard !orderedProviders.isEmpty else { return nil }
        return ExistingOpenClawAPIKeyConfiguration(providers: orderedProviders)
    }

    private func collectConfiguredProviders(
        fromAuthProfiles profiles: [String: Any],
        into providers: inout Set<OpenClawModelProvider>
    ) {
        for rawProfile in profiles.values {
            guard let profile = rawProfile as? [String: Any],
                  let providerID = profile["provider"] as? String,
                  hasSecretValue(profile["key"]) || hasSecretValue(profile["keyRef"]) ||
                      hasSecretValue(profile["token"]) || hasSecretValue(profile["tokenRef"]),
                  let provider = managedProviderFamily(providerID: providerID, provider: nil) else {
                continue
            }
            providers.insert(provider)
        }
    }

    private func collectConfiguredProviders(
        fromProviderMap providerMap: [String: Any],
        into providers: inout Set<OpenClawModelProvider>
    ) {
        for (providerID, rawProvider) in providerMap {
            guard let provider = rawProvider as? [String: Any],
                  hasSecretValue(provider["apiKey"]) || hasSecretValue(provider["apiKeyRef"]),
                  let family = managedProviderFamily(providerID: providerID, provider: provider) else {
                continue
            }
            providers.insert(family)
        }
    }

    private func collectConfiguredProviders(fromEnv env: [String: Any], into providers: inout Set<OpenClawModelProvider>) {
        for (key, value) in env {
            guard hasSecretValue(value),
                  let provider = managedProviderFamily(envKey: key) else {
                continue
            }
            providers.insert(provider)
        }
    }

    private func managedProviderFamily(providerID: String, provider: [String: Any]?) -> OpenClawModelProvider? {
        let normalizedID = providerID.lowercased()
        if normalizedID == ToolchainDefaults.qwenProviderID {
            return .qwenCloud
        }
        if normalizedID == "openai" {
            return .openAI
        }

        let baseURL = normalizedBaseURL(provider?["baseUrl"] as? String)
        if ToolchainDefaults.qwenManagedBaseURLs.contains(baseURL) {
            return .qwenCloud
        }
        if isManagedOpenAIBaseURL(baseURL) {
            return .openAI
        }

        return nil
    }

    private func managedProviderFamily(envKey: String) -> OpenClawModelProvider? {
        let normalizedKey = envKey.uppercased()

        if normalizedKey == "OPENAI_API_KEY" ||
            normalizedKey == "OPENAI_API_KEYS" ||
            normalizedKey == "OPENCLAW_LIVE_OPENAI_KEY" ||
            normalizedKey.hasPrefix("OPENAI_API_KEY_") {
            return .openAI
        }

        if normalizedKey == "QWEN_API_KEY" ||
            normalizedKey == "QWEN_API_KEYS" ||
            normalizedKey == "MODELSTUDIO_API_KEY" ||
            normalizedKey == "MODELSTUDIO_API_KEYS" ||
            normalizedKey == "DASHSCOPE_API_KEY" ||
            normalizedKey == "DASHSCOPE_API_KEYS" ||
            normalizedKey == "OPENCLAW_LIVE_QWEN_KEY" ||
            normalizedKey.hasPrefix("QWEN_API_KEY_") ||
            normalizedKey.hasPrefix("MODELSTUDIO_API_KEY_") ||
            normalizedKey.hasPrefix("DASHSCOPE_API_KEY_") {
            return .qwenCloud
        }

        return nil
    }

    private func hasSecretValue(_ value: Any?) -> Bool {
        switch value {
        case let string as String:
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let dictionary as [String: Any]:
            return !dictionary.isEmpty
        case let array as [Any]:
            return !array.isEmpty
        default:
            return value != nil
        }
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard var contents = String(data: data, encoding: .utf8) else {
            throw ValidationError("无法写入 \(url.lastPathComponent)。")
        }
        contents += "\n"
        try writePrivateFile(url, contents: contents)
    }

    private func applyModelProviderConfig(_ config: inout [String: Any], deployConfig: DeployConfig) {
        var agents = config["agents"] as? [String: Any] ?? [:]
        var defaults = agents["defaults"] as? [String: Any] ?? [:]
        defaults["model"] = [
            "primary": deployConfig.effectivePrimaryModel,
            "fallbacks": deployConfig.effectiveFallbackModels
        ]
        defaults["models"] = managedAllowedModels(for: deployConfig)
        agents["defaults"] = defaults
        config["agents"] = agents

        var auth = config["auth"] as? [String: Any] ?? [:]
        var profiles = auth["profiles"] as? [String: Any] ?? [:]
        removeManagedProfiles(from: &profiles)
        profiles[deployConfig.modelProvider.profileID] = [
            "provider": deployConfig.modelProvider.providerID,
            "mode": "api_key"
        ]
        auth["profiles"] = profiles
        var order = auth["order"] as? [String: Any] ?? [:]
        order.removeValue(forKey: "openai")
        order.removeValue(forKey: ToolchainDefaults.qwenProviderID)
        if order.isEmpty {
            auth.removeValue(forKey: "order")
        } else {
            auth["order"] = order
        }
        config["auth"] = auth

        var env = config["env"] as? [String: Any] ?? [:]
        removeManagedEnvKeys(from: &env)
        if env.isEmpty {
            config.removeValue(forKey: "env")
        } else {
            config["env"] = env
        }

        var models = config["models"] as? [String: Any] ?? [:]
        models["mode"] = "merge"
        var providers = models["providers"] as? [String: Any] ?? [:]
        removeManagedProviders(from: &providers)
        if deployConfig.modelProvider == .qwenCloud {
            providers[ToolchainDefaults.qwenProviderID] = qwenConfigProvider(authChoice: deployConfig.qwenAuthChoice)
        }
        models["providers"] = providers
        config["models"] = models

        var plugins = config["plugins"] as? [String: Any] ?? [:]
        var entries = plugins["entries"] as? [String: Any] ?? [:]
        entries.removeValue(forKey: ToolchainDefaults.qwenProviderID)
        if deployConfig.modelProvider == .qwenCloud {
            entries[ToolchainDefaults.qwenProviderID] = ["enabled": true]
        }
        if entries.isEmpty {
            plugins.removeValue(forKey: "entries")
        } else {
            plugins["entries"] = entries
        }
        if plugins.isEmpty {
            config.removeValue(forKey: "plugins")
        } else {
            config["plugins"] = plugins
        }
    }

    private func applyAgentModelsConfig(_ config: inout [String: Any], deployConfig: DeployConfig) {
        var providers = config["providers"] as? [String: Any] ?? [:]
        removeManagedProviders(from: &providers)
        if deployConfig.modelProvider == .qwenCloud {
            providers[ToolchainDefaults.qwenProviderID] = qwenAgentProvider(
                apiKey: deployConfig.modelAPIKey,
                authChoice: deployConfig.qwenAuthChoice
            )
        }
        config["providers"] = providers
    }

    private func applyAuthProfilesConfig(_ config: inout [String: Any], deployConfig: DeployConfig) {
        config["version"] = 1
        var profiles = config["profiles"] as? [String: Any] ?? [:]
        removeManagedProfiles(from: &profiles)
        profiles[deployConfig.modelProvider.profileID] = [
            "type": "api_key",
            "provider": deployConfig.modelProvider.providerID,
            "key": deployConfig.modelAPIKey
        ]
        config["profiles"] = profiles
        var order = config["order"] as? [String: Any] ?? [:]
        order.removeValue(forKey: "openai")
        order.removeValue(forKey: ToolchainDefaults.qwenProviderID)
        if order.isEmpty {
            config.removeValue(forKey: "order")
        } else {
            config["order"] = order
        }
    }

    private func removeManagedProfiles(from profiles: inout [String: Any]) {
        for profileID in Array(profiles.keys) {
            guard let profile = profiles[profileID] as? [String: Any],
                  let providerID = profile["provider"] as? String,
                  managedProviderFamily(providerID: providerID, provider: nil) != nil else {
                continue
            }
            profiles.removeValue(forKey: profileID)
        }
    }

    private func removeManagedProviders(from providers: inout [String: Any]) {
        for providerID in Array(providers.keys) {
            guard let provider = providers[providerID] as? [String: Any],
                  managedProviderFamily(providerID: providerID, provider: provider) != nil else {
                continue
            }
            providers.removeValue(forKey: providerID)
        }
    }

    private func removeManagedEnvKeys(from env: inout [String: Any]) {
        for key in Array(env.keys) where managedProviderFamily(envKey: key) != nil {
            env.removeValue(forKey: key)
        }
    }

    private func managedAllowedModels(for deployConfig: DeployConfig) -> [String: Any] {
        deployConfig.effectiveAllowedModels
    }

    private func qwenConfigProvider(authChoice: QwenCloudAuthChoice) -> [String: Any] {
        [
            "baseUrl": authChoice.baseURL,
            "api": ToolchainDefaults.qwenAPIType,
            "models": qwenModels(authChoice: authChoice, includeCompat: false)
        ]
    }

    private func qwenAgentProvider(apiKey: String, authChoice: QwenCloudAuthChoice) -> [String: Any] {
        [
            "baseUrl": authChoice.baseURL,
            "api": ToolchainDefaults.qwenAPIType,
            "apiKey": apiKey,
            "models": qwenModels(authChoice: authChoice, includeCompat: true)
        ]
    }

    private func qwenModels(authChoice: QwenCloudAuthChoice, includeCompat: Bool) -> [[String: Any]] {
        authChoice.defaultAllowedModelIDs
            .map { $0.replacingOccurrences(of: "qwen/", with: "") }
            .map { qwenModel(id: $0, includeCompat: includeCompat) }
    }

    private func qwenModel(id: String, includeCompat: Bool) -> [String: Any] {
        var model: [String: Any] = [
            "id": id,
            "name": id,
            "reasoning": false,
            "input": ["text", "image"],
            "cost": [
                "input": 0,
                "output": 0,
                "cacheRead": 0,
                "cacheWrite": 0
            ],
            "contextWindow": 1_000_000,
            "maxTokens": 65_536,
            "api": ToolchainDefaults.qwenAPIType
        ]
        if includeCompat {
            model["compat"] = ["supportsUsageInStreaming": true]
        }
        return model
    }

    private func normalizedBaseURL(_ rawValue: String?) -> String {
        guard let rawValue else { return "" }
        return rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func isManagedOpenAIBaseURL(_ baseURL: String) -> Bool {
        guard !baseURL.isEmpty else { return false }
        return ToolchainDefaults.openAIBaseURLMarkers.contains { marker in
            baseURL.contains(marker)
        }
    }

    private func hasManagedNodeVersionInstalled(in nvmDirectory: URL) -> Bool {
        let versionsDirectory = nvmDirectory.appendingPathComponent("versions/node", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }

        return contents.contains { url in
            url.lastPathComponent.hasPrefix("v\(ToolchainDefaults.nodeMajorVersion).")
        }
    }

    private func openClawLaunchAgentURLs(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return contents.filter { url in
            url.pathExtension == "plist" && url.lastPathComponent.lowercased().contains("openclaw")
        }
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

    private func usesBuiltinMirrors(_ config: DeployConfig) -> Bool {
        !config.mirrorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shellProfileHelpers: String {
        """
        append_zshrc_line() {
          local line="$1"
          touch "$HOME/.zshrc"
          grep -Fqx "$line" "$HOME/.zshrc" || printf '%s\\n' "$line" >> "$HOME/.zshrc"
        }
        remove_zshrc_line() {
          local line="$1"
          touch "$HOME/.zshrc"
          python3 -c 'from pathlib import Path; import sys; path = Path(sys.argv[1]); line = sys.argv[2]; text = path.read_text() if path.exists() else ""; lines = [current for current in text.splitlines() if current != line]; path.write_text("\\n".join(lines) + ("\\n" if lines else ""))' "$HOME/.zshrc" "$line"
        }
        """
    }

    private var nvmZshrcLines: [String] {
        [
            "export NVM_SOURCE=\"\(ToolchainDefaults.nvmSource)\"",
            "export NVM_NODEJS_ORG_MIRROR=\"\(ToolchainDefaults.nodeMirror)\"",
            "export NVM_DIR=\"$HOME/.nvm\"",
            "[ -s \"$NVM_DIR/nvm.sh\" ] && \\. \"$NVM_DIR/nvm.sh\"",
            "[ -s \"$NVM_DIR/bash_completion\" ] && \\. \"$NVM_DIR/bash_completion\""
        ]
    }

    private var directNvmZshrcLines: [String] {
        [
            "export NVM_DIR=\"$HOME/.nvm\"",
            "[ -s \"$NVM_DIR/nvm.sh\" ] && \\. \"$NVM_DIR/nvm.sh\"",
            "[ -s \"$NVM_DIR/bash_completion\" ] && \\. \"$NVM_DIR/bash_completion\""
        ]
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

}

private enum ToolchainDefaults {
    static let nvmSource = "https://gitee.com/mirrors/nvm-sh.git"
    static let nvmMirrorInstallScriptURL = "https://gitee.com/mirrors/nvm-sh/raw/v0.40.4/install.sh"
    static let nvmOfficialInstallScriptURL = "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh"
    static let nodeMirror = "https://npmmirror.com/mirrors/node"
    static let nodeMajorVersion = "24"
    static let claudeCodePackage = "@anthropic-ai/claude-code"
    static let agencyAgentsRepoURL = "https://gitee.com/boomer001/agency-agents.git"
    static let qwenProviderID = "qwen"
    static let qwenAPIType = "openai-completions"
    static let qwenManagedBaseURLs = Set([
        "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        "https://coding.dashscope.aliyuncs.com/v1",
        "https://coding-intl.dashscope.aliyuncs.com/v1"
    ])
    static let openAIBaseURLMarkers = [
        "api.openai.com",
        ".openai.azure.com",
        ".services.ai.azure.com",
        ".cognitiveservices.azure.com"
    ]
}

private struct DeploymentStep {
    let title: String
    let action: () async throws -> Void
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
