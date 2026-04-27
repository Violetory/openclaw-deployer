import Foundation

enum ChannelSetupKind: String, Codable {
    case token
    case qr
    case oauth
    case webhook
    case manual

    var label: String {
        switch self {
        case .token: return "Token"
        case .qr: return "QR 登录"
        case .oauth: return "OAuth"
        case .webhook: return "Webhook"
        case .manual: return "手动配置"
        }
    }
}

struct ChannelDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let setupKind: ChannelSetupKind
    let tokenLabel: String
    let summary: String
    let isAutomatable: Bool

    static let supported: [ChannelDefinition] = [
        .init(id: "telegram", name: "Telegram", setupKind: .token, tokenLabel: "BotFather Token", summary: "Bot API，使用 openclaw channels add --token 配置", isAutomatable: true),
        .init(id: "discord", name: "Discord", setupKind: .token, tokenLabel: "Discord Bot Token", summary: "Discord Bot API + Gateway", isAutomatable: true),
        .init(id: "slack", name: "Slack", setupKind: .token, tokenLabel: "Slack Bot Token / App Token", summary: "Slack App，需要 token 或 app token", isAutomatable: true),
        .init(id: "mattermost", name: "Mattermost", setupKind: .token, tokenLabel: "Personal Access Token", summary: "Bot API + WebSocket", isAutomatable: true),
        .init(id: "line", name: "LINE", setupKind: .token, tokenLabel: "Channel Access Token", summary: "LINE Messaging API", isAutomatable: true),
        .init(id: "feishu", name: "Feishu / Lark", setupKind: .token, tokenLabel: "App Token", summary: "飞书/Lark WebSocket bot", isAutomatable: true),
        .init(id: "qq", name: "QQ Bot", setupKind: .token, tokenLabel: "QQ Bot Token", summary: "QQ Bot API", isAutomatable: true),
        .init(id: "twitch", name: "Twitch", setupKind: .token, tokenLabel: "OAuth Token", summary: "Twitch IRC chat", isAutomatable: true),
        .init(id: "zalo", name: "Zalo", setupKind: .token, tokenLabel: "Zalo Access Token", summary: "Zalo Bot API", isAutomatable: true),
        .init(id: "nostr", name: "Nostr", setupKind: .token, tokenLabel: "Private Key", summary: "NIP-04 私信，命令会尝试 --private-key", isAutomatable: true),
        .init(id: "google-chat", name: "Google Chat", setupKind: .webhook, tokenLabel: "Webhook / Service Account", summary: "HTTP webhook 或服务账号，需按项目配置", isAutomatable: false),
        .init(id: "microsoft-teams", name: "Microsoft Teams", setupKind: .oauth, tokenLabel: "Bot Framework Auth", summary: "企业 Bot Framework，通常需要 Azure 配置", isAutomatable: false),
        .init(id: "whatsapp", name: "WhatsApp", setupKind: .qr, tokenLabel: "QR Pairing", summary: "Baileys，需要扫码配对", isAutomatable: false),
        .init(id: "wechat", name: "WeChat", setupKind: .qr, tokenLabel: "QR Login", summary: "外部插件/扫码登录，私聊为主", isAutomatable: false),
        .init(id: "zalo-personal", name: "Zalo Personal", setupKind: .qr, tokenLabel: "QR Login", summary: "个人账号扫码登录", isAutomatable: false),
        .init(id: "signal", name: "Signal", setupKind: .manual, tokenLabel: "signal-cli", summary: "依赖 signal-cli 与手机号", isAutomatable: false),
        .init(id: "matrix", name: "Matrix", setupKind: .manual, tokenLabel: "Homeserver + Token", summary: "Matrix homeserver / access token", isAutomatable: false),
        .init(id: "bluebubbles", name: "BlueBubbles", setupKind: .manual, tokenLabel: "REST API", summary: "推荐 iMessage 路径，需要 BlueBubbles server", isAutomatable: false),
        .init(id: "imessage", name: "iMessage Legacy", setupKind: .manual, tokenLabel: "imsg CLI", summary: "旧版 macOS 集成，官方已建议新装用 BlueBubbles", isAutomatable: false),
        .init(id: "irc", name: "IRC", setupKind: .manual, tokenLabel: "Server / Nick", summary: "传统 IRC server/channel 配置", isAutomatable: false),
        .init(id: "nextcloud-talk", name: "Nextcloud Talk", setupKind: .manual, tokenLabel: "Nextcloud Auth", summary: "自托管 Nextcloud Talk", isAutomatable: false),
        .init(id: "synology-chat", name: "Synology Chat", setupKind: .webhook, tokenLabel: "Incoming/Outgoing Webhooks", summary: "群晖 Chat webhook", isAutomatable: false),
        .init(id: "tlon", name: "Tlon", setupKind: .manual, tokenLabel: "Ship / Code", summary: "Urbit messenger", isAutomatable: false),
        .init(id: "webchat", name: "WebChat", setupKind: .manual, tokenLabel: "Gateway WebChat", summary: "Gateway WebSocket UI，无第三方 token", isAutomatable: false)
    ]
}

struct ChannelFormState: Identifiable {
    let definition: ChannelDefinition
    var isEnabled: Bool = false
    var token: String = ""

    var id: String { definition.id }
}

enum QwenCloudAuthChoice: String, CaseIterable, Codable, Identifiable {
    case standardChina
    case standardGlobal
    case codingChina
    case codingGlobal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standardChina: return "中国 Standard（按量）"
        case .standardGlobal: return "全球 Standard（按量）"
        case .codingChina: return "中国 Coding Plan"
        case .codingGlobal: return "全球 Coding Plan"
        }
    }

    var authChoiceID: String {
        switch self {
        case .standardChina: return "qwen-standard-api-key-cn"
        case .standardGlobal: return "qwen-standard-api-key"
        case .codingChina: return "qwen-api-key-cn"
        case .codingGlobal: return "qwen-api-key"
        }
    }

    var baseURL: String {
        switch self {
        case .standardChina: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .standardGlobal: return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .codingChina: return "https://coding.dashscope.aliyuncs.com/v1"
        case .codingGlobal: return "https://coding-intl.dashscope.aliyuncs.com/v1"
        }
    }

    var defaultPrimaryModel: String {
        switch self {
        case .standardChina, .standardGlobal:
            return "qwen/qwen3.6-plus"
        case .codingChina, .codingGlobal:
            return "qwen/qwen3.5-plus"
        }
    }

    var defaultAllowedModelIDs: [String] {
        [defaultPrimaryModel]
    }

    var summary: String {
        "官方 auth choice：\(authChoiceID)；端点：\(baseURL.replacingOccurrences(of: "https://", with: ""))；默认主模型与 /model picker 只保留 \(defaultPrimaryModel)。"
    }
}

enum OpenClawModelProvider: String, CaseIterable, Codable, Identifiable {
    case qwenCloud
    case openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qwenCloud: return "Qwen Cloud"
        case .openAI: return "OpenAI"
        }
    }

    var apiKeyLabel: String {
        switch self {
        case .qwenCloud: return "Qwen Cloud API Key"
        case .openAI: return "OpenAI API Key"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .qwenCloud: return "sk-请输入 Qwen Cloud API Key"
        case .openAI: return "sk-请输入 OpenAI API Key"
        }
    }

    var providerID: String {
        switch self {
        case .qwenCloud: return "qwen"
        case .openAI: return "openai"
        }
    }

    var profileID: String {
        "\(providerID):default"
    }

    var aliasName: String {
        switch self {
        case .qwenCloud: return "Qwen"
        case .openAI: return "OpenAI"
        }
    }
}

enum ExistingAPIKeyAction: String, Codable {
    case overwriteExisting
    case skipExisting
}

struct ExistingOpenClawAPIKeyConfiguration {
    let providers: [OpenClawModelProvider]

    var summary: String {
        let names = providers.map(\.title)
        guard !names.isEmpty else { return "OpenClaw" }
        return names.joined(separator: " / ")
    }
}

struct DeployConfig {
    var mirrorURL: String
    var modelProvider: OpenClawModelProvider
    var modelAPIKey: String
    var qwenAuthChoice: QwenCloudAuthChoice = .standardChina
    var existingAPIKeyAction: ExistingAPIKeyAction = .overwriteExisting
    var forceRestartAndOpenDashboard = false
    var channels: [ChannelFormState]
    var installClaudeCode: Bool
    var installAgencyAgents: Bool
    var installGatewayDaemon: Bool
    var openDashboard: Bool

    var enabledChannels: [ChannelFormState] {
        channels.filter(\.isEnabled)
    }

    var modelAPIKeyLabel: String {
        modelProvider.apiKeyLabel
    }

    var modelAPIKeyPlaceholder: String {
        modelProvider.apiKeyPlaceholder
    }

    var modelProviderSummary: String {
        switch modelProvider {
        case .qwenCloud:
            return qwenAuthChoice.summary
        case .openAI:
            return "默认主模型 openai/gpt-5.4；会把 API Key 写入 OpenClaw 本地认证配置。"
        }
    }

    var effectivePrimaryModel: String {
        switch modelProvider {
        case .qwenCloud:
            return qwenAuthChoice.defaultPrimaryModel
        case .openAI:
            return "openai/gpt-5.4"
        }
    }

    var effectiveFallbackModels: [String] {
        []
    }

    var effectiveAllowedModels: [String: Any] {
        var models: [String: Any] = [
            effectivePrimaryModel: ["alias": modelProvider.aliasName]
        ]
        for fallback in effectiveFallbackModels {
            models[fallback] = [String: Any]()
        }
        return models
    }

    var effectiveQwenBaseURL: String? {
        guard modelProvider == .qwenCloud else { return nil }
        return qwenAuthChoice.baseURL
    }

    var effectiveQwenModelIDs: [String] {
        guard modelProvider == .qwenCloud else { return [] }
        return qwenAuthChoice.defaultAllowedModelIDs.map { $0.replacingOccurrences(of: "qwen/", with: "") }
    }

    var secretsForRedaction: [String] {
        ([modelAPIKey] + enabledChannels.map(\.token)).filter { !$0.isEmpty }
    }
}

struct EnvironmentSnapshot {
    var osName: String = "-"
    var osVersion: String = "-"
    var architecture: String = "-"
    var latestNodeLTS: String = "-"
    var nodeVersion: String = "未安装"
    var npmVersion: String = "未安装"
    var pnpmVersion: String = "未安装"
    var gitVersion: String = "未安装"
    var openclawVersion: String = "未安装"
}

struct LogLine: Identifiable {
    enum Level {
        case info
        case ok
        case warning
        case error
        case command
    }

    let id = UUID()
    let date = Date()
    let level: Level
    let message: String
}
