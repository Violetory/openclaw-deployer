# OpenClaw Deployer

一个原生 macOS SwiftUI 一键部署器，用来安装 OpenClaw、Node/Git/pnpm，配置频道 token，并安装 `hotjp/agency-agents` 到 OpenClaw workspaces。

## 当前行为

- 不再收集、写入或配置 API Key。
- 模型/API 配置由用户在 CC switch 中自行维护。
- 所有安装项都会先检查本机状态；已安装时跳过进入下一步，避免重复安装、升级或覆盖。
- GitHub / Git 连接较慢时，会提示先安装并开启 Steam++（Watt Toolkit）：https://steampp.net/。
- 会检查 Xcode Command Line Tools / Git；缺失时执行 `xcode-select --install` 并提示用户完成系统安装器。
- Node 改为通过 nvm 安装；仅在未检测到 Node 24 时，才写入 `~/.zshrc` 并使用 Gitee nvm 源与 npmmirror Node 镜像安装 Node 24。
- 会检查 Homebrew；缺失时才写入 USTC Homebrew 镜像环境变量并安装 Homebrew。
- Claude Code 与 CC Switch 是“部署配置”里的可选安装项，默认选中；如果已安装或用户关闭开关，就跳过安装。
- Claude Code 缺失时通过 npm 全局安装：`npm install -g @anthropic-ai/claude-code`。
- CC Switch 缺失时通过 `brew tap farion1231/ccswitch` + `brew install --cask cc-switch` 安装。
- Telegram 等 token 型频道优先使用 `openclaw channels add --channel <name> --token ...` 配置，并 fallback 到 `--bot-token`、`--app-token`、`--token-file`。
- Gateway 会先运行 `openclaw setup --non-interactive --mode local`，再尝试 `gateway install/start`，必要时 fallback 到 `gateway run --allow-unconfigured --force`。
- 默认部署完成后打开 OpenClaw Dashboard。

## 新机前置流程

部署器的一键流程会按下面顺序处理前置工具。应用内执行时每一步都会先检查，已安装则跳过；下面是新机缺失时的等价命令：

```bash
# GitHub / Git 连接慢时，先安装并开启 Steam++：https://steampp.net/
xcode-select --install

touch ~/.zshrc
export NVM_SOURCE="https://gitee.com/mirrors/nvm-sh.git"
export NVM_NODEJS_ORG_MIRROR="https://npmmirror.com/mirrors/node"
curl -o- https://gitee.com/mirrors/nvm-sh/raw/v0.40.4/install.sh | bash
. "$HOME/.nvm/nvm.sh"
nvm install 24
node -v
npm -v

cat >> ~/.zshrc <<'EOF'
export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"
export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.ustc.edu.cn/homebrew-core.git"
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
EOF

/bin/bash -c "$(curl -fsSL https://github.com/Homebrew/install/HEAD/install.sh)"
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi
brew --version
brew config
brew doctor

npm install -g @anthropic-ai/claude-code
brew tap farion1231/ccswitch
brew install --cask cc-switch
```

## 构建

```bash
chmod +x Scripts/build_app.sh Scripts/package_dmg.sh
./Scripts/build_app.sh
./Scripts/package_dmg.sh
open dist/OpenClaw-Deployer.dmg
```

也可以直接调试运行：

```bash
swift run OpenClawDeployer
```

## macOS 26 UI 预览

macOS 应用没有独立的 macOS Simulator，预览方式是直接运行本机 app，或在 Xcode Canvas 打开 `ContentView` 的 `macOS 26 UI` 预览。

```bash
./Scripts/preview_macos.sh
```

## 说明

第一版没有启用 App Sandbox，因为部署器需要执行 shell、写入用户目录、拉取 GitHub 仓库并管理 LaunchAgent。适合先用 DMG 或内部签名分发，不适合直接走 Mac App Store。
