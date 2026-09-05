# 本机 macOS Application

Codex Director 现在提供标准的 `Codex Director.app` 构建目标。它是普通 Dock 应用，不依赖终端、本地服务器、LaunchAgent 或后台 Helper。

## 构建

在项目根目录执行：

```sh
zsh scripts/build-local-app.sh
```

Release Bundle 会生成在 `/tmp/codex-director-xcode/Build/Products/Release/Codex Director.app`。也可以直接用 Xcode 打开 `CodexDirector.xcodeproj`，选择共享 Scheme `Codex Director` 后运行或构建。

## 安装到 Applications

确认应用已退出后执行：

```sh
zsh scripts/install-local-app.sh
```

脚本会重新构建并验证 Bundle，然后要求明确确认是否替换已有版本。安装步骤需要向 `/Applications` 写入文件；脚本不会静默删除旧版本，确认替换时会先把旧 Bundle 移到临时目录，便于回滚。安装完成后会通过 Finder 的 LaunchServices 打开应用。

本期使用本机 Ad Hoc / Sign to Run Locally 签名，不包含 Developer ID、公证、DMG、自动更新或 Mac App Store 分发。应用关闭 App Sandbox，以便只读访问 `~/.codex`；它不会修改 Session、Agent、Skill、Plugin、源文件或全局配置。

派生数据库位置仍为 `~/Library/Application Support/CodexDirector/codex-director.sqlite`。删除 `/Applications/Codex Director.app` 可以回滚应用安装，不会删除数据库或 `~/.codex` 源数据。`swift run` 仍保留为开发调试备用入口。
