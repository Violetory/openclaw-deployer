<div align="center">

<img src="Assets/AppIcon.png" alt="LOGO" width="120" />


# OpenClaw Deployer

### 一个原生 MacOS 一键部署工具，专为非技术人员打造，妈妈再也不用担心我看不懂命令行啦！

鸣谢：https://github.com/hotjp

</div>

---

## 运行截图

![运行截图](Assets/runtime-screenshot.png)

## 项目目标

- 一键检查并安装 OpenClaw 所需工具链（Node、npm、pnpm、Git、Homebrew 等）。
- 支持国内镜像场景（nvm Gitee 源、Node 镜像、Homebrew 镜像、npm 镜像）。
- 支持频道 token 保存与自动配置。
- 支持可选安装 Claude Code、CC Switch、agency-agents。
- 支持打包 `.app` 与 `.dmg`，方便分发给非开发同学。

## 部署工作流程

应用点击“一键部署”后，按顺序执行以下流程：

1. 系统预检：检测 macOS、架构、Node、npm、pnpm、Git、OpenClaw。
2. Git 连接加速提示：提示可使用 Steam++（Watt Toolkit）提升 GitHub 连接速度。
3. Xcode Command Line Tools/Git：缺失时执行 `xcode-select --install`。
4. nvm/Node 24：缺失时安装，已安装则跳过。
5. Homebrew：缺失时安装并写入镜像变量，已安装则跳过。
6. 可选安装项：Claude Code、CC Switch（默认开启，可在界面关闭）。
7. OpenClaw：缺失时安装，已安装则跳过。
8. OpenClaw 本地初始化：`setup`、workspace、gateway 默认配置。
9. pnpm：缺失时安装，已安装则跳过。
10. 频道密钥与账号配置：自动保存 token 并尝试频道参数 fallback。
11. agency-agents：按开关执行，已存在目录时跳过避免覆盖。
12. Gateway 启动校验：必要时 fallback 到 `gateway run`。

说明：所有安装项都先检查本机状态，已安装默认跳过，避免重复安装或覆盖。

## 从 GitHub 下载并首次打开

1. 在 GitHub Release 页面下载 `OpenClaw-Deployer.dmg`。
2. 拖动 `OpenClaw Deployer.app` 到 `Applications`。
3. 首次打开若被系统拦截，可执行以下命令进行本机放行（常被称为“开发者签名放行”）：

```bash
xattr -dr com.apple.quarantine "/path/to/OpenClaw Deployer.app"
open "/path/to/OpenClaw Deployer.app"
```

## 构建与打包

### 本地构建 App

```bash
chmod +x Scripts/build_app.sh Scripts/package_dmg.sh Scripts/preview_macos.sh
./Scripts/build_app.sh
open "dist/OpenClaw Deployer.app"
```

### 打包 DMG

```bash
./Scripts/package_dmg.sh
open "dist/OpenClaw-Deployer.dmg"
```

### 调试运行

```bash
swift run OpenClawDeployer
```

### UI 预览（macOS 26）

```bash
./Scripts/preview_macos.sh
```

## Skill来源

- https://github.com/hotjp/agency-agents

## 备注

- 当前版本未启用 App Sandbox，适合 DMG 或内部签名分发。
- 模型/API 配置已从部署器中剥离，请在 CC Switch 中维护。
