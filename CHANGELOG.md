# Changelog

All notable changes to SimpleMinimap are documented here.

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
