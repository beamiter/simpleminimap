# Changelog

All notable changes to SimpleMinimap are documented here.

## 0.5.0

- Migrated to Rust edition 2024; minimum supported Rust is now 1.85.
- Internal cleanup (`div_ceil`); no behavior or protocol changes (protocol
  stays at 2). Rerun `./install.sh` after updating.

## 0.4.0

- Protocol v2: the daemon reports a density digit (0..3) per rendered cell
  alongside each row.
- Shade every minimap cell by code density with text properties: dense code
  renders brighter than sparse code through the new `SimpleMinimapShadeLow`,
  `SimpleMinimapShadeMid` and `SimpleMinimapShadeHigh` highlight groups
  (`g:simpleminimap_shading`, requires `+textprop`).
- Show the source cursor position as a percentage in the minimap statusline.
- Report density-shading support in `:SimpleMinimapHealth`.

## 0.3.0

- Project active `hlsearch` matches onto the minimap through
  `SimpleMinimapSearch`, using `matchbufline()` when available
  (`g:simpleminimap_show_search`).
- Classify projected signs by severity and kind (error, warning, info,
  git add/change/delete) with dedicated highlight groups; the most severe
  category wins when several signs share a minimap row.
- Cache the render request signature and skip the daemon round-trip when the
  sampled content, dimensions and style are unchanged; `:SimpleMinimapRefresh`
  forces a real render.
- Measure the backend round-trip latency with a ping after the handshake and
  extend `:SimpleMinimapHealth` with the daemon version, latency, search
  support and per-session render/cache statistics.
- Map `<Esc>` inside the minimap to return focus to the source window.
- Daemon: a new begin record now supersedes an unfinished request (the old
  request receives an `X` response) instead of failing both.

## 0.2.0

- Add adaptive bounded sampling and display-cell-aware handling for CJK, emoji,
  combining characters and tabs.
- Project Vim signs (including common Git and LSP integrations) onto the
  minimap through `SimpleMinimapSign`.
- Add left/right placement, focus, live resize, live render-style switching,
  keyboard preview, mouse-wheel scrolling and mouse drag navigation.
- Gate rendering on the daemon protocol handshake, coalesce stale requests,
  validate responses, and automatically recover from unexpected daemon exits.
- Add daemon input bounds, strict field decoding, strict command validation,
  `--help`, and expanded Rust/Vim regression coverage.
- Improve the statusline, health report, configuration validation and
  filetype exclusion support.

## 0.1.0

- Initial Vim9 frontend and asynchronous Rust renderer release.
