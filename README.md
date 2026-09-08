# QuotioPlus

<img src="docs/branding/quotio-plus-icon.png" width="128" alt="QuotioPlus cat app icon">

**English** · [简体中文](README.zh.md)

**QuotioPlus 1.0.0** is a native macOS app for managing AI accounts, proxy services, CLI agent configuration, quotas, and usage analytics. It is independently developed from [Quotio](https://github.com/nguyenphutrong/quotio), created by [Trong Nguyen (@nguyenphutrong)](https://github.com/nguyenphutrong).

> **Origin and acknowledgments:** This project is a derivative of the original author's code. Thank you to Trong Nguyen and all Quotio contributors for building and sharing the foundation that makes QuotioPlus possible. We retain the original copyright notices and MIT license. QuotioPlus releases, updates, and issue tracking are maintained independently in this repository.

[Download 1.0.0](https://github.com/Geoege-xll/quotio/releases/tag/v1.0.0) · [Release notes](docs/releases/1.0.0.md) · [Report an issue](https://github.com/Geoege-xll/quotio/issues) · [Original project](https://github.com/nguyenphutrong/quotio)

## Screenshots

Screenshots from QuotioPlus 1.0.0 with the Simplified Chinese interface. Displayed statistics depend on the locally collected history; unavailable metrics remain unknown.

**Dashboard — collapsible filters, primary metrics, and compact secondary statistics.**

![QuotioPlus dashboard with collapsible filters and usage overview](screenshots/v1.0.0/dashboard.png)

| Client usage | Agent configuration |
| --- | --- |
| [![Client usage with source filters, Token summaries, and activity heatmaps](screenshots/v1.0.0/client-usage.png)](screenshots/v1.0.0/client-usage.png) | [![Agent configuration for Claude Code, Codex CLI, and Pi](screenshots/v1.0.0/agent-setup.png)](screenshots/v1.0.0/agent-setup.png) |

Click either preview to view the full screenshot.

## What's included in 1.0.0

- **Accounts and proxies:** Manage accounts from multiple providers, OAuth/API keys, local proxy services, and quota monitoring, with quick access from the menu bar.
- **Dashboard:** Review requests, Tokens, success rates, caching, and latency with collapsible filters and a complete advanced filter sheet.
- **Client usage:** Read local Claude Code, Codex, OpenCode, and Pi records and explore Token usage by period, source, and model.
- **Call analytics:** Explore tool, MCP, skill, and agent calls using source, category, and date filters.
- **Request details and pricing:** Inspect collected CPA requests, configure model prices, and estimate costs. Missing values are explicitly treated as unknown.
- **Agent configuration:** Manage model mappings, default models, and providers, including Pi installations from Homebrew, npm, and other supported paths.
- **Lower statistics overhead:** Use shared SQLite storage, persisted summaries, and incremental processing to reduce repeated loading of large histories and memory use.
- **Storage maintenance:** Clear caches, remove statistics by module, or reclaim database space under **Settings → Diagnostics & Maintenance → Maintenance → Storage & Data**.
- **Independent updates:** Check this repository for app updates. Check the original project's releases separately in Diagnostics & Maintenance when preparing to synchronize upstream code.

Client Token usage, CPA gateway requests, and tool calls measure different things and are displayed separately. Clearing statistics does not delete the original client logs; retained logs can be imported again during a later scan.

## Installation

Requires **macOS 14 or later**. Download `Quotio-1.0.0.dmg` or the ZIP from this repository's [Releases](https://github.com/Geoege-xll/quotio/releases). The app's display name is **QuotioPlus**. Release builds support both Apple Silicon and Intel Macs.

Each release states whether it has Developer ID signing and Apple notarization. Builds made without distribution credentials use ad-hoc signing and may require additional confirmation from macOS. Automatic update installation is enabled only when this project's Sparkle signing configuration is complete; other builds provide manual updates through this repository's release page.

There is currently no official Homebrew installation channel for this derivative. The original author's `nguyenphutrong/tap` installs upstream Quotio.

## Build from source

```bash
git clone https://github.com/Geoege-xll/quotio.git
cd quotio
open Quotio.xcodeproj
```

Use Xcode 26.1 or later and select the `Quotio` scheme. You can also build from the terminal:

```bash
xcodebuild -project Quotio.xcodeproj -scheme Quotio \
  -configuration Debug -destination 'platform=macOS' build
```

The Bundle ID is `com.app.george.quotioplus`. Keep local signing and development overrides in the untracked `Config/Local.xcconfig`; see [Local.xcconfig.example](Config/Local.xcconfig.example). Publishing instructions are in [RELEASE.md](RELEASE.md).

## Open-source credits

| Project | Role in QuotioPlus |
| --- | --- |
| [Quotio · Trong Nguyen and contributors](https://github.com/nguyenphutrong/quotio) | The primary codebase for this derivative, including the native app, accounts, quotas, proxies, and client management. |
| [CLIProxyAPI · router-for-me](https://github.com/router-for-me/CLIProxyAPI) | The proxy service managed by the app. |
| [EasyCLIProxyAPI · router-for-me](https://github.com/router-for-me/EasyCLIProxyAPI) | A reference for the dashboard's usage calculations, filters, and presentation behavior. |
| [AIUsage · sylearn and contributors](https://github.com/sylearn/AIUsage) | Ported and referenced usage analytics, call analytics, and native interface components. See the [attribution notice](docs/licenses/AIUsage-attribution.md). |
| [cc-switch · farion1231 and contributors](https://github.com/farion1231/cc-switch) | A reference for client configuration and model mapping behavior. |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | The macOS application update framework. |

Thank you to these authors and their communities. We preserve upstream Git history and consolidate our development work before the first release into a single `1.0.0` commit, making the initial release easier to review and maintain.

## License and maintenance

The app retains the [MIT License](LICENSE) and the original `Copyright (c) 2025 Trong Nguyen` notice. The AIUsage-derived portions retain their attribution, modification notices, and [Apache License 2.0](docs/licenses/AIUsage-Apache-2.0.txt). Other dependencies remain subject to their respective licenses.

See the [secondary development and upstream maintenance guide](docs/SECONDARY_DEVELOPMENT.md) for source synchronization practices. Please report issues with this derivative in [Geoege-xll/quotio Issues](https://github.com/Geoege-xll/quotio/issues).
