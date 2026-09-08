# Scripts

Quotio has two self-contained script entrypoints:

- `build_and_run.sh`: build Debug, stop any running Quotio process, and launch the fresh app. Optional flags: `--debug`, `--logs`, `--telemetry`, `--verify`.
- `build_dmg.sh`: build a Release archive, verify the bundled proxy, and create ZIP and DMG artifacts. Pass `--distribution` to require Developer ID signing, notarization, stapling, and Gatekeeper validation.

`build_and_run.sh` respects the Xcode signing configuration. To sign local Debug builds with an Apple Development certificate, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` to your Apple team ID.

For a local release build:

```bash
./scripts/build_dmg.sh
```

When the complete Apple credential set is present, the release workflow enables distribution mode to notarize the artifacts. Without those secrets it builds ad-hoc artifacts, so forks do not need the upstream signing credentials. A partially configured credential set fails instead of silently publishing unsigned artifacts.

Run the distribution path locally with:

```bash
NOTARYTOOL_KEYCHAIN_PROFILE=quotio-notarization \
SPARKLE_PUBLIC_ED_KEY=... \
SPARKLE_PRIVATE_KEY=... \
  ./scripts/build_dmg.sh --version 1.2.3 --distribution --generate-appcast
```

`SIGNING_IDENTITY` defaults to `Developer ID Application`. Set it to the certificate's SHA-1 hash when more than one matching identity is installed. See `RELEASE.md` for credential setup.

应用发行仓库在 `Config/Updates.xcconfig` 统一配置。Sparkle 公钥通过该文件或构建参数 `SPARKLE_PUBLIC_ED_KEY` 提供，CI 使用同名 Repository Variable；私钥仍由 `SPARKLE_PRIVATE_KEY` Secret 提供。公钥缺失时，普通本地构建可以运行并打开自有发布页；生成 appcast 的发布构建必须具有配套公私钥，脚本会验证签名后再生成 appcast。不要填写上游公钥。

本地启动脚本从构建后的 Info.plist 读取 Bundle ID，日志筛选会自动跟随新身份 `com.app.george.quotioplus`。
