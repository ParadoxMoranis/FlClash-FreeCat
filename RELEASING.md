# GitHub 与 AUR 发布

项目仓库：`ParadoxMoranis/FlClash-FreeCat`。上游来源与固定依赖见 `UPSTREAM.md`。
本分支保留 FlClash 的应用 ID、配置目录和普通订阅行为；自由猫是额外的订阅来源。

## CI 触发与产物

- 分支推送及 Actions 手动运行：执行检查并构建所有平台，安装包保存在 Actions Artifacts。
- Pull request：执行代码与原生模块检查，不使用发布凭证。
- `v*` 标签：版本必须与 `pubspec.yaml` 去掉 `+build` 后完全一致；全部检查和构建成功后发布 GitHub Release。
- 稳定标签（例如 `v0.9.4`）：同时生成两架构 Linux bundle、AUR 源码包及 `SHA256SUMS`。
- 预发布标签（例如 `v0.9.5-pre.1`）：`pubspec.yaml` 必须先写为 `0.9.5-pre.1+构建号`，不会生成稳定版 AUR 包。

| 平台 | 架构 | 产物 |
| --- | --- | --- |
| Android | arm64-v8a、armeabi-v7a、x86_64 | APK |
| Windows | amd64、arm64 | 安装 EXE、便携 ZIP |
| macOS | Intel amd64、Apple Silicon arm64 | DMG |
| Linux | amd64、arm64 | DEB、RPM、AppImage、完整 bundle TAR.GZ |

首次推送后可在 GitHub 的 Actions → build 查看，或执行：

```bash
gh run list --repo ParadoxMoranis/FlClash-FreeCat --workflow build.yaml
gh run watch RUN_ID --repo ParadoxMoranis/FlClash-FreeCat
gh run download RUN_ID --repo ParadoxMoranis/FlClash-FreeCat --dir dist/ci
```

CI 的客户端更新地址来自 `GITHUB_REPOSITORY`，打包时写入 `APP_REPOSITORY`；不会下载上游 FlClash 的更新覆盖本分支。
可下载测试构件不等于正式发布，AUR 只引用稳定 Release 的固定版本文件。

## 签名与仓库设置

GitHub Release 使用工作流的 `GITHUB_TOKEN`，不需要个人访问令牌。允许仓库运行 Actions；不要把面板账号等运行时凭证配置进 CI。

Android 正式更新需要持久的签名密钥。设置四个 repository secrets：

- `KEYSTORE`：JKS 文件的 base64 内容。
- `KEY_ALIAS`、`STORE_PASSWORD`、`KEY_PASSWORD`：对应别名和密码。

四项齐全才启用正式签名。缺少任一项时生成使用临时 debug key 的 `.dev` 应用，CI 会警告并随产物附带
`ANDROID-SIGNING.txt`。临时密钥可能跨构建变化，不能保证直接覆盖安装。不要提交 JKS 或密码。
Windows 和 macOS 当前未配置商业代码签名/Apple notarization；系统可能提示未知发布者。

Pages 默认关闭。`site/` 保留上游站点，仍含上游下载链接，未进行本分支适配；完成站点审查后才设置
repository variable `ENABLE_PAGES=true`。构建和发布不依赖 Pages、Telegram、Homebrew 或 F-Droid 凭证。

## 发布稳定版

先确认版本号及构建号递增，完成测试并提交；不要复用上游的 `0.9.3`。

```bash
git push origin main
git tag v0.9.4
git push origin v0.9.4
```

只有显式推送标签才创建 Release。需要下一版时先更新 `pubspec.yaml`，再创建对应的新标签。
`SHA256SUMS` 覆盖发行安装包和 AUR 源码包；Core/Helper 在打包时不得被 strip 或改写，清单会验证 Core 的 SHA-256。

## 发布 AUR

稳定版 Release 中下载 `flclash-freecat-bin-版本.tar.gz`。其中包含最终的 `PKGBUILD`、`.SRCINFO`、桌面文件和卸载脚本，
两架构下载 URL 及 SHA-256 来自该次 CI 生成的真实 Linux bundle，不使用 `SKIP`。

```bash
gh release download v0.9.4 --repo ParadoxMoranis/FlClash-FreeCat \
  --pattern 'flclash-freecat-bin-0.9.4.tar.gz' --pattern SHA256SUMS --dir dist/release
cd dist/release
sha256sum --ignore-missing --check SHA256SUMS
tar -xzf flclash-freecat-bin-0.9.4.tar.gz
cd flclash-freecat-bin
makepkg --verifysource
makepkg
```

AUR 发布需要自己的 AUR 账号与已登记的 SSH 公钥；GitHub CLI 登录不会授予 AUR 权限。首次发布前确认包名尚无人维护：

```bash
ssh -T aur@aur.archlinux.org
git clone ssh://aur@aur.archlinux.org/flclash-freecat-bin.git aur-release
cp PKGBUILD .SRCINFO flclash.desktop flclash-freecat.install aur-release/
cd aur-release
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO flclash.desktop flclash-freecat.install
git commit -m 'initial release: 0.9.4'
git push origin master
```

后续版本重复下载新 Release 的 AUR 源码包并更新同一 AUR 仓库。AUR 只上传配方及其本地小文件，不上传二进制包、
Flutter SDK、账号凭证或本机源码归档。`packaging/aur/` 说明配方生成器和输出结构。

本地生成与 CI 使用相同命令：

```bash
python3 tool/release_aur.py --repository ParadoxMoranis/FlClash-FreeCat \
  --tag v0.9.4 --dist dist --output dist/aur
```

它要求两个真实 bundle 已在 `dist/` 中，并在任何输出前验证归档及 Core 清单。
