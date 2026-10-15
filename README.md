# QuotioPlus

<img src="docs/branding/quotio-plus-icon.png" width="128" alt="QuotioPlus cat app icon">

<p align="left">
  <a href="https://github.com/Geoege-xll/quotio/releases"><img src="https://img.shields.io/badge/release-v1.1.01-blue.svg" alt="Release"></a>
  <a href="https://linux.do"><img src="https://img.shields.io/badge/LINUX_DO-Recognized-f0b23d.svg?style=flat&labelColor=1c1c1e" alt="LINUX DO Recognized"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B%20(arm64)-orange.svg" alt="Platform">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License"></a>
</p>

**English** · [简体中文](README.zh.md)

**QuotioPlus 1.1.01** is a native macOS app for managing AI accounts, proxy services, CLI agent configuration, quotas, and usage analytics. It is independently developed from [Quotio](https://github.com/nguyenphutrong/quotio), created by [Trong Nguyen (@nguyenphutrong)](https://github.com/nguyenphutrong).

> **Origin and acknowledgments:** This project is a derivative of the original author's code. Thank you to Trong Nguyen and all Quotio contributors for building and sharing the foundation that makes QuotioPlus possible. We retain the original copyright notices and MIT license. QuotioPlus releases, updates, and issue tracking are maintained independently in this repository.

[Download 1.1.01](https://github.com/Geoege-xll/quotio/releases/tag/v1.1.01) · [Release notes](docs/releases/1.1.01.md) · [LINUX DO Community](https://linux.do) · [Report an issue](https://github.com/Geoege-xll/quotio/issues) · [Original project](https://github.com/nguyenphutrong/quotio)

## Screenshots

Screenshots from **QuotioPlus 1.1.01** running natively on macOS (macOS 15+ Apple Silicon):

**Routing Center — Real-time topology, upstream/downstream request traces, and link metrics**

![QuotioPlus Routing Center: Real-time topology and execution traces](screenshots/v1.1.01/routing-center.png)

| Usage Analytics: Token Trends & Heatmaps | Agent Workspace: Disk Space & Cache |
| --- | --- |
| [![Usage Analytics: Request metrics, Token totals, and trend charts](screenshots/v1.1.01/usage-analytics.png)](screenshots/v1.1.01/usage-analytics.png) | [![Agent Workspace: Client disk usage and cache cleanup](screenshots/v1.1.01/agent-workspace.png)](screenshots/v1.1.01/agent-workspace.png) |

**Account Management — Multi-provider account pool, quota tracking, and reset cycles**

![QuotioPlus Account Management: Multi-provider accounts and quota bars](screenshots/v1.1.01/account-management.png)

> Click any preview to view the full-resolution screenshot.

## What's included in 1.1.01

- **Routing Center & Topology Monitoring:** Visual request flow linking CLI agent clients through the local CPA proxy to upstream providers. Inspect recent executions with direct inline failure diagnostics.
- **Usage Analytics & Multi-Source Dashboard:** Comprehensive usage tracking for Claude Code, Codex CLI, OpenCode, and Pi. Detailed Token counts, request totals, average latency, and activity heatmaps.
- **Agent Workspace & Disk Maintenance:** Transparent disk usage breakdown for CLI clients, session storage tracking, and one-click safe cache cleanup.
- **Accounts & Quota Management:** Unified management of Antigravity, Claude, OpenAI, Copilot, and custom providers with live quota progress, reset countdowns, and IDE binding detection.
- **macOS Design System ("Squircle + Capsule"):** Squircle container cards and Capsule action controls, featuring the single-field inline commit standard (`QuotioInlineApplyField`) with baseline-aware dirty tracking.
- **CPA v8 Proxy Integration:** Full support for CLIProxyAPI 8.x with dynamic session affinity, retry configuration, and hot-reloaded advanced options.
- **Low-Overhead SQLite Engine:** Persistent summary aggregation and incremental log scanning to minimize disk I/O and runtime memory footprint.
- **Independent Updates & Upstream Compatibility:** Standalone releases via this repository while maintaining upstream compatibility inspection tools.

Client Token usage, CPA gateway requests, and tool calls measure different things and are displayed separately. Clearing statistics does not delete the original client logs; retained logs can be imported again during a later scan.

## Installation

Requires **macOS 15 or later and an Apple Silicon Mac (M1 or later)**. Download `QuotioPlus-1.1.01.dmg` or the ZIP from this repository's [Releases](https://github.com/Geoege-xll/quotio/releases). The app's display name is **QuotioPlus**. Release builds contain arm64 only; Intel Macs are no longer supported.

Each release states whether it has Developer ID signing and Apple notarization. Builds made without distribution credentials use ad-hoc signing and may require additional confirmation from macOS. Automatic update installation is enabled only when this project's Sparkle signing configuration is complete; other builds provide manual updates through this repository's release page.

There is currently no official Homebrew installation channel for this derivative. The original author's `nguyenphutrong/tap` installs upstream Quotio.

## Build from source

```bash
git clone https://github.com/Geoege-xll/quotio.git
cd quotio
open Quotio.xcodeproj
```

Use Xcode 26.1 or later and select the `QuotioPlus` scheme. You can also build from the terminal:

```bash
xcodebuild -project Quotio.xcodeproj -scheme QuotioPlus \
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

## Community & Recognition

> 🏅 **This project actively participates in and recognizes the [LINUX DO Community](https://linux.do).**

<p align="left">
  <a href="https://linux.do"><img src="https://ld.xh.do/ld-badge.svg" alt="Recognized by LINUX DO" width="380"></a>
</p>

- **[LINUX DO Community](https://linux.do)**: Welcome to share tips, setups, and feedback about QuotioPlus on the LINUX DO developer community.
- **Issue Tracking**: If you encounter bugs or have feature requests, please report them on [GitHub Issues](https://github.com/Geoege-xll/quotio/issues).

## License and maintenance

The app retains the [MIT License](LICENSE) and the original `Copyright (c) 2025 Trong Nguyen` notice. The AIUsage-derived portions retain their attribution, modification notices, and [Apache License 2.0](docs/licenses/AIUsage-Apache-2.0.txt). Other dependencies remain subject to their respective licenses.

See the [secondary development and upstream maintenance guide](docs/SECONDARY_DEVELOPMENT.md) for source synchronization practices. Please report issues with this derivative in [Geoege-xll/quotio Issues](https://github.com/Geoege-xll/quotio/issues).
