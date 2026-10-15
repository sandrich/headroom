<p align="center"><img src="docs/banner.png" alt="Headroom" width="100%"></p>

<p align="center">
  <a href="https://github.com/sandrich/headroom/releases/latest"><img src="https://img.shields.io/github/v/release/sandrich/headroom?label=release" alt="Latest release"></a>
  <a href="https://github.com/sandrich/headroom/actions/workflows/test.yml"><img src="https://github.com/sandrich/headroom/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 or newer">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.9 or newer">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/sandrich/headroom" alt="MIT license"></a>
</p>

# Headroom

A tiny macOS menu bar app that shows how much headroom you have left: on your machine (CPU, GPU, memory, battery) and on your AI coding plans (Claude Code and Grok), plus your Claude spend on AWS Bedrock.

One compact, native-looking item in the menu bar. Click it for a dashboard with live graphs; hover an item to see what is using it.

<p align="center"><img src="docs/screenshot.png" alt="Headroom menu bar item and dashboard" width="720"></p>

## Features

**Menu bar**
- One line, monochrome, tinted by macOS like every other menu bar item
- CPU and GPU with live sparklines, memory, battery
- Claude Code limits as three slim gauges (5h session, weekly, per-model weekly such as Fable)
- Grok credits gauge
- Each item can be switched on or off; sampling every 0.5 to 5 seconds

**Hover**
- CPU, GPU, memory, battery: top apps (helper processes are grouped under their app)
- Claude, Grok: exact limit percentages and reset times

**Dashboard**
- Live charts for CPU (with per-core bars), GPU and memory; battery state, power draw, health and cycles
- Claude Code plan limits with reset countdowns and a pace marker (where you would be if usage were spread evenly)
- Grok weekly credits
- AWS Bedrock: account-wide Claude tokens and estimated cost from CloudWatch, or, without AWS access, the Claude Code sessions that ran through Bedrock
- Combined token usage for Claude Code, Grok and Bedrock: today, last 7 days, last 30 days, tokens and cost, a 30-day chart by model family, and a per-model table, similar to [ccusage](https://github.com/ryoppippi/ccusage)

Providers you do not use are hidden automatically.

**Keep awake** (like Amphetamine or `caffeinate`)
- Keep the Mac from idle sleeping for 1, 2, 4 or 8 hours, or indefinitely, from the cup menu in the dashboard footer
- Option-click the menu bar item to toggle it; a cup appears in the menu bar while it is on
- Optional: stay awake while Claude Code or Grok is working (any transcript written in the last 10 minutes), so long agent runs are not cut off by sleep
- Optionally keep the display on too
- Uses a standard power assertion (visible in `pmset -g assertions`), released automatically if Headroom quits; closing the lid still sleeps

## Requirements

- macOS 14 or newer (built and tested on Apple Silicon)
- Xcode command line tools (Swift 5.9+)
- Optional: [Claude Code](https://claude.com/claude-code) signed in with a Claude subscription
- Optional: the [Grok CLI](https://x.ai/cli) signed in (`grok login`)
- Optional: the [AWS CLI](https://aws.amazon.com/cli/) with a profile that can call `cloudwatch:GetMetricData` in your Bedrock regions

## Install

1. Download the latest **Headroom-x.y.dmg** from [Releases](https://github.com/sandrich/headroom/releases/latest).
2. Open it and drag **Headroom** onto **Applications**.
3. Launch Headroom. It lives in the menu bar, not the Dock.

Headroom is not notarized by Apple yet, so macOS blocks the first launch once. Open **System Settings > Privacy & Security** and click **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Headroom.app`.

## Build from source

```bash
./build.sh            # builds build/Headroom.app
./build.sh install    # copies it to /Applications and launches it
./build.sh dmg        # packages build/Headroom-<version>.dmg
```

Builds are universal (Apple Silicon and Intel). To publish a release, bump `CFBundleShortVersionString` in `Resources/Info.plist`, then push a matching tag such as `v1.1`; the release workflow builds the DMG and attaches it.

Headroom registers itself as a login item on first launch. Turn that off under Settings in the dashboard footer.

## How it works

Everything is sampled locally and cheaply. Steady-state cost is around 1% of one core with the dashboard closed.

| Data | Source |
| --- | --- |
| CPU | `host_processor_info` tick deltas |
| Memory | `host_statistics64` (app + wired + compressed, like Activity Monitor), memory pressure via `sysctl` |
| GPU | IOKit `IOAccelerator` `PerformanceStatistics` |
| Battery | IOKit power sources and `AppleSmartBattery` |
| Top apps | `libproc` (`proc_pid_rusage`) and per-client GPU time from the GPU driver's IORegistry entries; only sampled while a hover panel is open |
| Claude Code limits | The usage endpoint Claude Code itself uses, authenticated with Claude Code's OAuth token from the login keychain (read via `/usr/bin/security`; never stored, logged or refreshed by Headroom) |
| Claude Code tokens | `~/.claude/projects/**/*.jsonl`, plus Cowork sessions from the desktop app (`~/Library/Application Support/Claude*/local-agent-mode-sessions/**/.claude/projects`), tailed incrementally by byte offset and cached in `~/Library/Application Support/Headroom` |
| Grok credits | The billing endpoint the Grok CLI's `/usage` uses, with the CLI's token from `~/.grok/auth.json`. If that token has expired, Headroom runs `grok models` once so the CLI refreshes it; Headroom never writes the file. |
| Grok tokens | `~/.grok/sessions/*/*/usage.json` |
| Bedrock (Claude Code) | Claude Code and Cowork transcripts whose message ids start with `msg_bdrk_`, kept apart from subscription usage |
| Bedrock (account-wide) | `aws cloudwatch get-metric-data` with a `SEARCH` over the `AWS/Bedrock` token and invocation metrics for every Claude model id, hourly sums for 30 days, refreshed every 30 minutes and cached per region. Credentials stay with the AWS CLI (SSO, `credential_process` and so on all work). When CloudWatch has data it replaces the local Bedrock figures, since it already includes them. |
| Prices | [LiteLLM's model price list](https://github.com/BerriAI/litellm), refreshed daily |

### Accuracy notes

- Token totals follow ccusage's rules: deduplicated by message id and request id (message id alone when the request id is missing, as it often is for Bedrock and Cowork), keeping the final counts of messages that were logged several times while streaming, and including advisor sub-calls. Days are local calendar days; "7 days" and "30 days" include today. Totals include cache reads and writes, so they are far higher than the input + output figures the Claude desktop app shows under Settings > Usage.
- Cost can differ slightly from ccusage because Headroom prices 1-hour cache writes at their own (higher) rate.
- Grok cost comes from the CLI's own per-turn cost figures.
- Bedrock cost is estimated from token counts with LiteLLM's Bedrock prices (regional and geo inference profiles such as `au.` or `eu.` include their premium). CloudWatch does not split 5-minute and 1-hour cache writes, so all cache writes are priced at the 5-minute rate. Application inference profiles (ARNs) cannot be mapped to a model and are skipped. It is an estimate, not your AWS bill.
- Bedrock turns read from Claude Code transcripts do not record their region, so they are priced at Anthropic's list price.
- Energy in the battery hover panel is shown as each app's share of energy used, because the kernel counters do not have a documented unit.
- Root-owned processes (for example `WindowServer` CPU or `kernel_task`) cannot be read without elevated rights and are missing from the CPU, memory and energy lists.

### AWS Bedrock setup

Headroom picks an AWS profile and region from `AWS_PROFILE` and `AWS_REGION` when it is launched from a terminal, otherwise from `~/.aws/config` (the `default` profile, or the only profile there is). Usually you will want to set them explicitly under **Settings > AWS Bedrock...** in the dashboard footer: enter the profile and one or more comma-separated regions where you call Bedrock (cross-region inference is metered in the region you call). The same values can be set with `defaults write`, for example `defaults write dev.headroom.Headroom bedrock.regions "ap-southeast-2"` (keys `bedrock.profile` and `bedrock.regions`).

CloudWatch charges $0.01 per 1,000 metrics requested. Each refresh requests one metric per model and counter, which comes to roughly $0.30 a month per region.

### Caveats

The Claude and Grok usage endpoints are not public APIs. They may change without notice, in which case those sections show the last known values and an error until Headroom is updated.

## Development

```bash
swift build                                     # debug build
swift test                                      # unit tests (Swift Testing)
.build/release/Headroom --snapshot /tmp/shots   # renders the menu bar strip and dashboard to PNGs, then exits
```

Source layout (`Sources/Headroom`):

- `main.swift`: app delegate, timers, status item, popover
- `SystemSampler.swift`: CPU, GPU, memory, battery
- `Consumers.swift`: per-app top consumers for the hover panels
- `Clients.swift`: Claude Code and Grok plan limits, Bedrock CloudWatch usage
- `Ledger.swift`: token ledger, pricing, summaries
- `StatusRenderer.swift`: draws the menu bar strip
- `PopoverView.swift`, `Hover.swift`: SwiftUI dashboard and hover panels
- `KeepAwake.swift`: keep awake power assertion

`scripts/make-icon.swift` regenerates `Resources/AppIcon.icns`, `scripts/make-banner.swift` regenerates `docs/banner.png`.

Tests live in `Tests/HeadroomTests` and run on every push and pull request.

## License

MIT, see [LICENSE](LICENSE).
