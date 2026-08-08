# Changelog

All notable changes to SimpleMinimap are documented here.

## Unreleased - 2026-08-08

### 修复

- minimap 窗口的 `statusline` / `wincolor` / `winfixwidth` 此前只在建窗时设置
  一次,之后没有任何路径再写回。任何逐窗口改写 `&l:statusline` 的状态栏插件
  (本套件自己就带一个)都会在 `WinEnter` 上把 minimap 标题永久清空,只能重开
  窗口才恢复。现在这三项在 `BufWinEnter` / `WinEnter` 上重新断言,`ColorScheme`
  也会一并恢复 `wincolor`;非 minimap 窗口只付出一次 dict 查找的代价。
- 新增 `simpleminimap#StatuslineExpr()`,返回 minimap 状态栏的规范值(
  `g:simpleminimap_show_statusline` 为 0 时返回空串)。状态栏管理器不必再硬编码
  那串字面量,也就不会与插件版本漂移。

## Unreleased - 2026-08-05

### 交互演进

- `:SimpleMinimapRefresh!` 可在不切换 tab/window 的情况下强制刷新所有存活
  session，并绕过各自的签名缓存；遍历前固定 session 身份，已关闭或被回调替换
  的窗口不会被复活或误刷新。

- `:SimpleMinimapResize` 及 minimap 内的 `+` / `-` 现在会同步所有已打开
  tab session；`g:simpleminimap_width` 是全局配置，不再出现后台标签页仍保留旧
  宽度、切回去才发现布局不一致的情况。
- 新增 `:SimpleMinimapPin`、`:SimpleMinimapUnpin`、`:SimpleMinimapTogglePin`
  与幂等 `<Plug>(simpleminimap-pin)`、切换用 `<Plug>(simpleminimap-toggle-pin)`。
  多分屏工作时可以把每个标签页的 minimap
  锁定在当前源分屏，进入其他分屏不会再切走概览；源分屏失效时会安全解锁并
  回退到可用窗口；仅源 buffer 被 wipe 且同窗换入普通 buffer 时则保持 window
  pin 并继续跟随。minimap 内按 `p` 可快速切换，状态栏和 health 会显示锁定状态。

### 全套统一

- `.simplecore/` 回来了。10 个仓库里的 supervisor(`autoload/<plugin>/core.vim`
  与三个测试文件)本来就是一套 vendored bundle,但源头目录早已丢失,而每个
  Makefile 都还在引用 `../.simplecore/vendor.sh`。现在 bundle 有了源头,而且
  每个仓库带一份 `.simplecore.manifest` 记录各文件的 sha256,`make core-verify`
  会校验它,`check` 依赖它——手改 vendored 文件会在改它的那个仓库里直接失败,
  不需要 `.simplecore/` 在场。
- 安装器抽成共享的 `install-common.sh`,各仓库的 `install.sh` 只剩配置。
  由此补齐的能力:构建前检查 cargo/rustc 与 MSRV(此前 3 个仓库缺,用户看到的
  是一屏 trait 解析错误);原子替换(此前 2 个仓库是就地覆写,Vim 还开着旧 daemon
  时会 ETXTBSY);Windows 的 `.exe` 后缀;安装前用 `--self-test` 验证刚构建的
  二进制;以及生成 helptags。
- `make check` 现在是每个仓库统一的完整门禁。simplemarkdown 与 simpleminimap
  此前叫 `make test`,旧名字保留为别名。
- daemon 的命令行统一为 `--version` / `--help` / `--self-test`。

### 工具链

- `rust-version` 统一到 1.88(此前 1.85 与 1.88 各半)。实测:1.88 能构建全部
  10 个仓库,1.85 只能构建 5 个。
- `cargo update`:全部为补丁级更新。

  注意:这次更新让 `ignore` 从 0.4.27 升到 0.4.30+,而后者用了 let-chains。
  simplefinder 与 simpletree 此前声明的 1.85 在更新前是真实可用的,更新后不再成立
  ——这是这次依赖刷新付出的代价,不是发现了旧的错误声明。
- MSRV 提到 1.88 后,clippy 的 `collapsible_if` 开始建议用 let-chains 合并
  (该 lint 受 MSRV 门控)。已按建议合并,语义不变。

### 构建与 CI 修复

- CI 的 MSRV 作业固定在 Rust 1.70,而本 crate 自 0.5.0 起就是 edition 2024 / `rust-version = 1.85`;该作业自那时起一直失败。现已对齐到 1.85。
- 修复 `doc/simpleminimap.txt` 中重复的 help tag(`:SimpleMinimapHealth`、`:SimpleMinimapRestart`)。

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
