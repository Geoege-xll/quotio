# QuotioPlus 发布维护

首个独立版本为 **1.0.0**，发行说明位于 [docs/releases/1.0.0.md](docs/releases/1.0.0.md)。

发布前提交版本配置、CHANGELOG 和对应的 `docs/releases/<version>.md`。标签必须与已提交版本一致；工作流只构建并发布，不再自动追加版本提交。未配置 Sparkle 公私钥时允许发布手动更新安装包，部分配置仍会报错。Apple 签名和公证状态会按实际构建结果写入发行说明。

# Quotio Release Guide

## Automated Release

Use the GitHub **Release** workflow. It can be triggered from the Actions page with a version such as `1.2.3` or `1.2.3-beta-1`.

工作流会：

1. 验证标签、已提交版本及 `docs/releases/<version>.md` 一致；既有标签必须指向当前提交。
2. 配齐 Apple 凭据后，在临时钥匙串导入 Developer ID 证书并执行签名和公证。
3. 创建 ZIP 和 DMG，并验证构建没有改写版本与 CHANGELOG。
4. 根据仓库变量或版本配置读取本项目 Sparkle 公钥；公私钥齐全才生成签名 appcast。
5. 手动触发时创建缺失标签，使用已提交的发行说明发布 GitHub Release。
6. 不追加版本提交；仅在配置自有 Homebrew tap 时发送稳定版本通知。

GitHub Actions reads release credentials only from repository secrets:

| Name | Purpose |
|------|---------|
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application certificate and private key (`.p12`) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APP_STORE_CONNECT_API_KEY_BASE64` | Base64-encoded App Store Connect API private key (`.p8`) |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API issuer ID |
| `SPARKLE_PRIVATE_KEY` | This repository’s Sparkle EdDSA private signing key |
| `POSTHOG_PROJECT_TOKEN` | Optional PostHog project token embedded at build time |
| `TAP_TOKEN` | Dispatch the stable release to the Homebrew tap |

The five Apple signing secrets are an optional all-or-none group. When all five are absent, the workflow still builds the existing ad-hoc artifacts, which keeps forks usable without access to the upstream credentials. When any Apple signing secret is set, all five must be set so a partially configured release cannot silently fall back to ad-hoc signing.

Create a **Developer ID Application** certificate from the Apple Developer portal or Xcode, install it together with its private key, and export both from Keychain Access as a password-protected `.p12`. Create a team App Store Connect API key under **Users and Access > Integrations** and download its `.p8` file. The private key can only be downloaded once.

Encode the two files before adding them as GitHub Actions secrets:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
base64 -i AuthKey_KEY_ID.p8 | pbcopy
```

Do not commit either file. The workflow validates all credentials before building and deletes its temporary keychain and key files after the build.

当前生产 Bundle ID 为 `com.app.george.quotioplus`。首次启动从 `app.bytrong.quotio`、`dev.quotio.desktop` 等旧身份补齐偏好，凭据继续沿用现有按需迁移流程。已关闭自动检查的选择会保留；旧发行源的跳过版本、检查时间和 Atom 缓存不会继承。Bundle ID 与更新源更换后的首次安装应单独验证，不能假定旧上游安装包可以直接自动更新到本应用；系统权限和登录项可能需要按新身份重新确认。

## Local Artifacts

Build the current project version without changing source files:

```bash
./scripts/build_dmg.sh
```

Artifacts are written to `build/release/`:

- `QuotioPlus-<version>.dmg`
- `QuotioPlus-<version>.zip`

Install `create-dmg` for the custom DMG layout; otherwise the script falls back to `hdiutil`:

```bash
brew install create-dmg
```

## Local Signed Release

Install the Developer ID Application certificate and private key in Keychain, then store the notarization API credentials once:

```bash
xcrun notarytool store-credentials quotio-notarization \
  --key /path/to/AuthKey_KEY_ID.p8 \
  --key-id KEY_ID \
  --issuer ISSUER_ID
```

Run the same signed and notarized packaging path as CI:

```bash
NOTARYTOOL_KEYCHAIN_PROFILE=quotio-notarization \
SPARKLE_PUBLIC_ED_KEY=... \
SPARKLE_PRIVATE_KEY=... \
  ./scripts/build_dmg.sh --version 1.2.3 --distribution --generate-appcast
```

`SIGNING_IDENTITY` defaults to `Developer ID Application`; set it to the identity's SHA-1 hash if multiple Developer ID certificates are installed. `--version` modifies `CHANGELOG.md` and `Quotio.xcodeproj/project.pbxproj`. `--generate-appcast` creates `build/release/appcast.xml`; the script does not create a tag, push, or publish a GitHub Release.

Pre-release versions containing `alpha`, `beta`, or `rc` are added to the Sparkle beta channel.

## Verification

After a release:

- Download and open the DMG on a Mac that has not built Quotio locally.
- 对已公证发行包验证 Gatekeeper 能正常打开；临时签名包必须明确标注未公证状态。
- 已公证发行包应通过 `spctl --assess --type execute --verbose=2 /Applications/Quotio.app`，显示 `accepted` 与 `Notarized Developer ID`。
- 确认 ZIP 和 DMG 已上传；只有启用 Sparkle 签名的发行版才要求提供 `appcast.xml`。
- Check stable and beta update channels as applicable.

## 二开版发行身份与 Sparkle 公钥

当前应用 Bundle ID 为 `com.app.george.quotioplus`，发布仓库为 `Config/Updates.xcconfig` 中的 `Geoege-xll/quotio`。在 GitHub Repository Variables 配置 `SPARKLE_PUBLIC_ED_KEY`，并在 Secrets 配置同一密钥对的 `SPARKLE_PRIVATE_KEY`。公钥也可以写入受版本管理的 `Config/Updates.xcconfig`，它不属于秘密。

未配置公钥时，本地构建只提供自有发布页，不进行自动安装。公私钥都未配置时，发布流程生成安装包并在发行说明中标明手动更新；只配置其中一个时失败。两者齐全时生成 appcast，并在 ZIP 生成后验证签名与应用内公钥一致。自动更新需要另行验证实际下载与安装路径；不要把源码编译通过当成线上更新验收。

Homebrew 通知为可选项：只有设置 `HOMEBREW_TAP_REPOSITORY` Repository Variable 后才触发，而且必须属于当前仓库所有者。默认不会向原上游的 tap 发送发布事件。
