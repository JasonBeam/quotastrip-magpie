# QuotaStrip

[简体中文](README.zh-CN.md)

QuotaStrip turns the MacBook Pro Touch Bar into a compact dashboard for Codex and
AI token usage. It is a personal, local-first fork of
[hohocf/QuotaStrip](https://github.com/hohocf/QuotaStrip), focused on the Codex
desktop app and a local [Magpie](https://github.com/yetone/magpie) gateway.

![QuotaStrip on the Touch Bar](docs/touchbar-magpie.png)

The Touch Bar shows:

- Codex 5-hour and 7-day **remaining** quota.
- Token Plan remaining percentage, today's token count, active model, cache-hit
  rate, and output speed.
- Optional Kimi Code quota rows when Magpie exposes a valid quota bucket.
- The system Control Strip on the right.

The menu-bar panel adds the detailed usage view: DeepSeek balance, Token Plan
credits, Magpie provider/model breakdowns, Kimi Code quota, and a complete Magpie
usage heatmap. Hovering a heatmap cell shows its local date, weekday, and token
count.

## Before installing

- A MacBook Pro with a physical Touch Bar.
- macOS 11 or later. Start-at-login requires macOS 13 or later.
- The ChatGPT/Codex desktop app at `/Applications/ChatGPT.app` for live Codex
  quota. Older fallbacks also read `~/.codex/sessions`.
- Magpie is optional. Without it, QuotaStrip falls back to Codex app-server or
  local session logs and the Magpie-specific rows stay unavailable.

The app uses the private `DFRFoundation` Touch Bar API, the same technique used by
MTMR and Pock. It is not distributed through the Mac App Store and is not
notarized.

## Install

1. Download `QuotaStrip.zip` and `SHA256SUMS.txt` from
   [Releases](https://github.com/JasonBeam/quotastrip-magpie/releases).
2. Verify the archive:

   ```bash
   shasum -a 256 QuotaStrip.zip
   ```

3. Unzip it and move `QuotaStrip.app` to `/Applications`.
4. Quit any older QuotaStrip process, then open the app once with
   **Control-click → Open** to accept the unnotarized developer signature.
5. Open the menu-bar QuotaStrip icon and choose **重新显示 Touch Bar** if the
   Touch Bar is managed by another app.

No Accessibility permission, Claude hooks, Codex configuration change, or
LaunchAgent is required. QuotaStrip itself may optionally be enabled as a login
item from its menu.

## Building from source

```bash
git clone https://github.com/JasonBeam/quotastrip-magpie.git
cd quotastrip-magpie
./build.sh
```

The build requires Xcode and its command-line tools. It creates a universal
Intel/Apple Silicon app at `/tmp/QuotaStrip.app`.

## Data sources

- **Codex quota:** Magpie's local read-only API first; app-server
  `account/rateLimits/read` and `~/.codex/sessions` are fallbacks. Only the
  `codex` limit bucket is used.
- **Magpie usage:** local Magpie endpoints and its read-only cache/history files.
- **DeepSeek:** optional official API balance lookup after the user explicitly
  stores a key in macOS Keychain.

The UI refreshes every 20 seconds. Requests are serialized and cached to avoid
overlapping refreshes. Missing or incomplete values are shown as unavailable;
QuotaStrip never treats an unknown percentage as 100%.

## Behaviour

- Codex/ChatGPT launch shows the Touch Bar; complete exit hides it.
- Wake from sleep rechecks whether ChatGPT/Codex is running.
- The menu-bar process stays available when the Touch Bar is hidden.
- Codex percentages show remaining quota, not consumed quota.
- Remaining values above 50% are green, 21–50% are yellow, and 20% or less are
  red.

## Limitations

- The Touch Bar API is private and can change with macOS.
- Release builds are signed but not notarized, so first launch requires an
  explicit open action.
- Magpie-specific cards require Magpie and its local service to be available.
- Quota values depend on data exposed by Codex, Magpie, and each provider. A
  provider changing its endpoint can temporarily leave a row unavailable.
- The release is verified locally on the maintainer's Touch Bar Mac. Downloaders
  still need to confirm their own physical Touch Bar layout and provider data.

## Privacy

QuotaStrip reads local Codex session data and Magpie's local-only interfaces. It
does not modify `~/.codex/config.toml`, inject memories, install hooks, or send
conversation bodies anywhere. Optional provider keys are stored only in macOS
Keychain and are not included in this repository or release archive.

## Credits and license

Based on [hohocf/QuotaStrip](https://github.com/hohocf/QuotaStrip), licensed under
the MIT License. Product names and logos belong to their respective owners and
are used only to identify the data source.
