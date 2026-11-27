# Changelog

## 1.2.0 - 2026-11-27

### Added

- Add a Magpie live Touch Bar module for Token Plan remaining percentage, today's
  tokens, active model, cache-hit rate, and output speed.
- Feed the overview from Magpie's merged usage view while keeping DSH as a
  non-overlapping fallback.
- Add Qwen and Kimi Code provider cards, Kimi quota windows, and the current
  week's usage in the Codex card.
- Add a full-history Magpie usage heatmap with month headings, weekday rows, and
  four-level color scaling.
- Add a hover tooltip that follows each heatmap date cell, clamps at window
  edges, and shows local date, weekday, and daily tokens.

### Changed

- Prefer Magpie's Codex quota view, then fall back to Codex app-server and local
  session logs.
- Show remaining Codex quota consistently for the 5-hour and 7-day windows.
- Preserve complete heatmap history when Magpie temporarily rewrites its cache.

### Fixed

- Keep the last valid heatmap history during a cache rebuild.
- Prevent stale hover exits from hiding the newly selected date tooltip.
- Avoid placing the heatmap tooltip at the card's top-left corner when SwiftUI has
  not yet reported the card width.

## 1.1.1

- Use the original 24-hour clock consistently in full reset dates and compact 5h
  reset clocks.
- Expand the Codex-only Touch Bar panel to show each reset countdown alongside its
  local date, 24-hour time, and abbreviated English weekday. Keep the compact
  layout when both services are enabled.

## 1.1.0

- Add persistent service-selection menu items.
- Detect the Codex plan from local session logs and render actual quota windows.
- Add an About QuotaStrip panel with the app version, build number, and project
  link.
- Add regression coverage for service selection, local-only reads, account
  switching, and quota-window mapping.

[1.2.0]: https://github.com/JasonBeam/quotastrip-magpie/compare/v1.1.1...v1.2.0
