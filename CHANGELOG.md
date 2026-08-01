# Changelog

All notable changes to SimpleMinimap are documented here.

## Unreleased - 2026-08-01

### 新增

- `:SimpleMinimapLog`:后端事件进入环形缓冲区,启动与崩溃时的关键信息不再
  依赖用户提前打开 `g:simpleminimap_debug` 才能看到。

### 可靠性:统一 daemon 监督层 (simplecore)

- 进程生命周期改由 vendored `simplecore` 监督层接管(`autoload/simpleminimap/core.vim`,
  从 `.simplecore/` 同步,请勿直接编辑)。九个插件共用同一份实现:
  - 存活判定一律走 `job_status()`。`job_start()` 即使 exec 失败也会返回 job
    对象,所以 `job != null` 并不能说明进程还活着。
  - 代际守卫:被替换掉的旧 daemon 的 `exit_cb` 迟到时,不会再清掉接替它的新
    进程的状态。
  - 停止栅栏:显式停止后仍在管道里的事件会被丢弃,不会把刚拆掉的状态又写回去。
  - 指数退避自动重启;同一时间窗内反复崩溃则熔断,只报错一次而不是无限重启。
    手动 `:SimpleMinimapRestart` 会重新合闸。
  - 请求按 id 关联并支持超时,卡死的 daemon 不会让回调永远悬着。
- 新增 `:SimpleMinimapHealth`、`:SimpleMinimapRestart`、`:SimpleMinimapLog`,全套插件命名一致。

### 测试

- 新增 `tests/vim_core.vim`:监督层回归套件(存活判定、代际守卫、停止栅栏、
  退避重启、崩溃熔断、请求超时、协议握手、raw/json 两种编解码),由
  `tests/fake_daemon.py` 驱动——一个可以按需应答/静默/乱码/崩溃/忽略 SIGTERM
  的假 daemon。
- 新增 `make defcompile`:强制编译所有 Vim9 `def`。Vim9 惰性编译会把冷分支里的
  语法/类型错误一直藏到用户真正踩中为止。
- `make check` 现在包含以上两项。

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
