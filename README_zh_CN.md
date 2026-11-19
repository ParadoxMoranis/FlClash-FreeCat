<div align="center">

<img src="assets/images/icon.png" alt="FlClash" width="88">

# FlClash-FreeCat

基于 [FlClash](https://github.com/chen08209/FlClash) 的社区分支，增加可选的自由猫专属订阅支持。
普通订阅链接、本地配置、规则分流与 TUN 沿用 FlClash 的原有行为。本项目与自由猫服务方及 FlClash 上游维护者无隶属关系。

[English](README.md) · **简体中文**

[![Build](https://github.com/ParadoxMoranis/FlClash-FreeCat/actions/workflows/build.yaml/badge.svg)](https://github.com/ParadoxMoranis/FlClash-FreeCat/actions/workflows/build.yaml)
[![Release](https://img.shields.io/github/v/release/ParadoxMoranis/FlClash-FreeCat)](https://github.com/ParadoxMoranis/FlClash-FreeCat/releases)
[![License](https://img.shields.io/github/license/ParadoxMoranis/FlClash-FreeCat)](LICENSE)

[下载](#下载) · [GitHub 与 AUR 发布指南](RELEASING.md) · [从源码构建](#从源码构建)

</div>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="snapshots/preview-dark.png">
    <img alt="FlClash 在 MacBook 与手机上的仪表盘" src="snapshots/preview.png" width="92%">
  </picture>
</p>

## 功能

- **一个应用覆盖 Android、Windows、macOS 和 Linux**，桌面端同时提供 x64 与 ARM64 版本。
- **mihomo（Clash.Meta）内核**：规则分流、代理组、延迟测试、系统代理与 TUN 模式。
- **配置管理**：通过订阅链接或文件导入配置，内置编辑器，支持覆写脚本以及自定义规则、代理和代理组。
- **实时查看**连接、请求、DNS 查询和日志。
- **Material You 设计，融合 Apple 式交互**：支持动态取色、浅色与深色主题，连续曲率圆角，弹出面板可在几档高度间吸附，布局随屏幕从手机到桌面自适应。
- **备份与恢复**：通过 WebDAV 或本地文件。
- **平台细节**：Android 上有快捷设置磁贴、分应用代理和 Android TV 支持；桌面端有托盘菜单和全局快捷键。
- **开源无广告**，以 GPL-3.0 协议发布。

## 下载

本分支安装包在 [GitHub Releases](https://github.com/ParadoxMoranis/FlClash-FreeCat/releases) 下载。
每次分支推送也会在对应的 [Actions 运行记录](https://github.com/ParadoxMoranis/FlClash-FreeCat/actions/workflows/build.yaml) 中提供测试构件。

| 平台 | 安装包 | 说明 |
| --- | --- | --- |
| Android | `arm64-v8a`、`armeabi-v7a`、`x86_64` 三种 APK | 绝大多数手机选 `arm64-v8a`；没有正式密钥时，CI 使用临时 debug key 和 `com.follow.clash.dev`，后续更新可能需要卸载旧 APK。 |
| Windows 10 及以上 | 安装版（`.exe`）或便携版（`.zip`），分 x64 与 ARM64 | 骁龙等 ARM 架构笔记本选 ARM64；安装包没有发布者代码签名。 |
| macOS 12 及以上 | Apple Silicon 与 Intel 两种 DMG | 使用 ad-hoc 签名，没有 Apple 开发者证书和公证，可能需在“隐私与安全性”中允许运行。 |
| Linux | `.deb`、`.rpm`、AppImage 与 `.tar.gz`，分 x64 与 ARM64 | 稳定版额外提供校验和锁定的 AUR 源码包。 |

发布工作流无需签名 secrets 即可运行；只有标签与 `pubspec.yaml` 版本匹配、全部必要检查和各平台安装包构建成功，
才会发布 Release。发行文件包含 `SHA256SUMS` 和 `ANDROID-SIGNING.txt`。Android 需要完整的四项正式签名 secrets
才能保持签名身份；临时 debug key 可能随构建改变。配置方法见[发布指南](RELEASING.md)。CI 构建的客户端从本分支仓库检查更新。


**Linux 托盘图标**

`.deb` 安装包会自动安装所需依赖。使用 AppImage 或 `.rpm` 时，需要先安装 AyatanaAppIndicator 库，托盘图标才能显示：

```bash
sudo apt-get install libayatana-appindicator3-1   # Debian 与 Ubuntu
sudo dnf install libayatana-appindicator-gtk3     # Fedora
```

**无人值守的桌面环境**

FlClash 要在免责声明被接受后才会启动核心。在容器等无人点击的环境里，可在应用的环境变量中设置
`FLCLASH_ACCEPT_DISCLAIMER=1`，首次启动时即视为接受。

## 使用

**通过链接导入配置。** 打开下面格式的链接，即可把订阅导入 FlClash。`clashmeta://` 和 `flclash://` 开头的链接同样可用。

```text
clash://install-config?url=<经过 URL 编码的订阅链接>
```

**自由猫订阅（附加功能）。** 在 **配置 → 添加 → 自由猫** 中输入自己的邮箱和密码。主机留空会依次尝试
内置面板入口，也可填写自定义 HTTPS 面板。密码仅用于本次登录；token 和订阅地址保存在系统安全存储中。
普通链接和文件导入继续使用原有流程。

刷新和自动更新沿用现有配置控件。重新登录或切换账号时，在该配置的右键或长按菜单中选择 **自由猫**，
更新同一份配置并保留节点选择。在其他设备恢复备份后需重新登录；导出的配置 YAML 仍含节点凭证。
Linux 登录前需要解锁 GNOME Keyring、KWallet 等 Secret Service 密钥环。

自由猫来源的手动测速默认使用官方 3.2.0 实测的 `http://cp.cloudflare.com/generate_204`；未保存过超时时使用 5000 ms。
用户自定义测速 URL 和超时优先；已保存的超时（包括 8000 ms）保持不变，严格对照时请手动选择 5000 ms。
自动选择/故障转移的健康检查保留订阅地址和周期；DNS 与节点字段沿用订阅及用户覆写规则。
自由猫默认 `global-ua` 对齐实测 3.2.0 订阅 User-Agent，显式 `global-ua` 保留。
`chrome120` TLS 默认是本分支的兼容策略，现有证据未证明官方客户端使用的 TLS 指纹。
HTTP 延迟通过不代表所有 HTTPS 访问都可用，取证依据见[测速差异说明](FREECAT_PROBE_FINDINGS.md)。

**Android 自动化。** Tasker、MacroDroid 等应用可以用下面的 Action 启动 Activity，从而启动、停止或切换代理：

```text
com.follow.clash.action.START
com.follow.clash.action.STOP
com.follow.clash.action.TOGGLE
```

在电脑上也可以通过 adb 触发：

```bash
adb shell am start -a com.follow.clash.action.TOGGLE
```

## 从源码构建

需要 [Flutter](https://docs.flutter.dev/get-started/install) 3.47（正式版构建使用 3.47.6）、[Go](https://go.dev/dl/) 1.27，
以及通过 rustup 安装的 [Rust](https://rustup.rs/)。桌面端需要在对应系统上构建，Android 在任意系统上都能构建。

```bash
git clone --recursive https://github.com/ParadoxMoranis/FlClash-FreeCat.git
cd FlClash-FreeCat
flutter pub get
dart setup.dart android   # 或 windows、macos、linux
```

安装包输出到 `dist/`。Go 内核和 Rust 库会在 Flutter 构建过程中一并编译。

| 平台 | 额外依赖 |
| --- | --- |
| Android | 带 NDK 的 Android SDK 与 JDK 17。加上 `--arch arm64` 可以只构建单个 ABI。 |
| Windows | 编译内核用的 GCC（MinGW-w64），以及打包安装程序用的 [Inno Setup](https://jrsoftware.org/isinfo.php) 6。 |
| macOS | Xcode 与 Node.js。脚本会通过 npm 安装 `appdmg`。 |
| Linux | Debian 或 Ubuntu。脚本会用 apt 安装构建所需的软件包，并下载 `appimagetool`。 |

其余选项可以运行 `dart setup.dart --help` 查看，例如用 `--targets` 只构建部分安装包格式。

## 支持

本分支的问题请提交到 [GitHub Issues](https://github.com/ParadoxMoranis/FlClash-FreeCat/issues)。
请勿附带密码、token、订阅地址或完整节点配置。

## 许可证

FlClash-FreeCat 以 [GPL-3.0 协议](LICENSE)发布。FlClash 及第三方组件保留原有版权和许可证声明，
来源与基线见 [UPSTREAM.md](UPSTREAM.md)。
