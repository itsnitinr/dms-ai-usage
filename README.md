# AI Usage

Claude Code and Codex subscription limits in the DankBar.

## What it shows

| Provider | Limits | Freshness |
| --- | --- | --- |
| Claude | 5-hour, weekly | Live — queried on a 5 minute timer |
| Codex | whatever windows your plan has (weekly on Plus) | As of your last Codex turn |

The bar shows a single `speed` icon, tinted by the highest utilization across
everything enabled: normal text color under 70%, amber at 70%, red at 90%. It
stays quiet until something needs attention.

Left-click for the detail popout: a meter per limit with percent used and time
to reset, grouped by provider under its logo, with each provider's data age on
the right. Refresh from the header button, or right-click the pill.

## How the data is obtained

`fetch-usage.sh` writes a normalized blob to
`$XDG_CACHE_HOME/dms-ai-usage.json`; the QML watches that file, so several
monitors share a single fetch.

**Claude** — reads the OAuth access token Claude Code already stores in
`~/.claude/.credentials.json` and calls `api.anthropic.com/api/oauth/usage`
with it, the same endpoint the client uses for `/usage`. The token goes
nowhere else. If it 401s (signed out), the provider is simply omitted.

**Codex** — the CLI has no usage endpoint, but it records a `rate_limits`
snapshot into its session rollout log (`~/.codex/sessions/**/rollout-*.jsonl`)
on every turn. The script takes the newest snapshot. That means the numbers
only advance while you use Codex; the popout labels the snapshot age and warns
past 3 hours. Reset times are absolute, so an old snapshot stays directionally
correct until its window rolls over.

Both providers are optional — the widget renders whichever ones report.

## Settings

Settings → Plugins → AI Usage:

- **Show Claude Code** / **Show Codex**

Thresholds live in `AiUsageWidget.qml`: `warnPct` (70, amber), `critPct`
(90, red), `staleMinutes` (180). The bar glyph is the `name:` on the two
`DankIcon`s in the pill components — any Material Symbols name works.

Note that `horizontalBarPill` / `verticalBarPill` should contain **content
only**. `PluginComponent` wraps whatever you supply in a `BasePill`, which
already draws the pill background and outline, applies the bar's configured
`widgetPadding`, and owns hover/ripple/click — and sizes itself from your
content's `implicitWidth`. Wrapping the content in your own `StyledRect` gives
you a second background inside the real one, with padding that ignores the
bar's settings.

## Files

| File | Role |
| --- | --- |
| `plugin.json` | manifest — id, surfaces, permissions |
| `fetch-usage.sh` | both providers → one JSON blob + cache |
| `AiUsageData.qml` | runs the script, watches the cache, parses it |
| `AiUsageWidget.qml` | bar pills (horizontal + vertical) and popout |
| `AiUsageSettings.qml` | settings page |
| `assets/*.svg` | provider logos, normalized to a white fill |

The logos ship with a `#ffffff` fill so `DankSVGIcon`'s `colorOverride` lands
exactly on the theme color — colorization multiplies by source luminance, so a
black-filled source would stay black.

## Development

```sh
sh fetch-usage.sh | jq            # check the data layer alone
dms ipc call plugin-scan scan     # pick up manifest changes
dms ipc call plugins reload aiUsage
qs -p /usr/share/quickshell/dms log | tail   # QML errors land here
```

Requires `jq` and `curl`.
