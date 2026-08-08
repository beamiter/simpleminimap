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
- 在 minimap 上滚动鼠标滚轮此前**完全没有效果**:`ScrollSource()` 用
  `winrestview({'topline': …})` 滚动,而 Vim 会立刻把 topline 拉回去以保证没动过
  的光标可见。这个功能在 README、help 和缓冲区按键表里都写着,却一行断言都没有。
  改用 Vim 真正认账的 `<C-E>` / `<C-Y>`,并补上前后对比 `topline` 的回归测试。
- `g:simpleminimap_mouse_scroll_lines` 未显式设置时改为跟随 `'mousescroll'` 的
  `ver:`,滚轮在 minimap 上和在代码上的手感一致。

- 渲染请求此前没有任何超时。daemon 只要还接受输入却不再回复(卡死、被 SIGSTOP、
  阻塞在慢文件系统上),`job_status()` 依然是 `run`、握手也早已成功,于是 minimap
  永远停在编辑前的内容上,而 `:SimpleMinimapHealth` 一路绿灯——只能靠
  `:SimpleMinimapRestart` 恢复。现在每个请求都会 arm 一个 deadline
  (`g:simpleminimap_request_timeout_ms`,默认 5000ms,设 0 关闭),超时即拒绝该请求
  并在 minimap 上说明;连续两次超时会重启 daemon。
- 崩溃循环熔断此前形同虚设:`backend_restart_attempts` 在每次成功渲染后被清零,
  于是“最多重启 3 次”变成了“每成功一次就重新计 3 次”。每渲染一次就崩一次的
  daemon 会被每 100ms 重新 fork 一遍,直到会话结束(实测 8 秒内 57 次)。改为
  60 秒滚动窗口内的固定预算;用尽后熔断,并且熔断后 *任何* 路径都不再启动进程
  (此前渲染路径会绕过定时器直接再 fork 一个),`:SimpleMinimapRestart` 才能复位。
- 超时触发的重启此前走的是面向用户的 `Restart()`,而它会清零重启预算、滚动窗口和
  熔断状态。于是“卡死后重启”这条路径完全不受预算约束:它绕过
  `g:simpleminimap_auto_restart = 0`(`StopBackend(true)` 把这次退出标成显式重启,
  于是 `BackendExit()` 根本不去看这个选项),还会把崩溃路径已经花掉的预算退回去——
  先崩两次再卡死的 daemon 又拿回满额预算。实测:握手成功后不再回复的 daemon,
  10 秒内 fork 了 28 个进程,`backend_restart_attempts` 始终是 0,熔断永远不跳。
  现在超时重启与崩溃重启共用同一份 60 秒滚动预算,用尽即熔断并停掉卡死的进程;
  `g:simpleminimap_auto_restart` 为 0 时则完全不重启,只记录日志。
- 熔断现在记录跳闸原因,`:SimpleMinimapHealth` 与 minimap 上的提示会区分
  `crash loop` 与 `no response`,不再把卡死一律说成崩溃循环。
- `:SimpleMinimapHealth` 现在报告请求超时设置与累计超时次数、重启预算用量与熔断
  状态。help 里关于 daemon 监管的那一节此前描述的是 simplecore + JSON over stdio,
  而实际跑的是本仓库自己的 supervisor + TAB 分隔行协议;已按实际实现重写。

- 搜索投影不再把整个 buffer 交给 `matchbufline()`。它按 *每个匹配* 返回一个
  字典,而这里最终只需要“每一行区间里有没有命中”这 `len(rows)` 个比特:在
  5 万行、模式为 `.` 的 buffer 上,旧实现在 `CursorMoved` 回调里同步分配约 200 万
  个字典并做 4400 万次行号比较(实测 3.6 秒,每次按键一遍)。现在按行区间分段扫描
  并在首个命中处离开该区间,同样的场景降到几十毫秒,并且不再需要“超过 10 万行
  就跳过搜索投影”这条限制——大文件的搜索投影现在是可用的。扫描预算耗尽时(比如
  几百万行且模式无命中)标记为部分结果,状态栏显示 `~`。
- `RowForSourceLine()` 由线性扫描改为除法(带校验,必要时二分回退)。这个函数在
  每个 sign 上都要调用一次,带 4000 个 git sign 的文件每次 `CursorHold` 要做
  约 24 万次比较。`UpdateSigns()` 同时在所有行都升到最高严重级时提前退出。

- `:SimpleMinimapHealth` 此前用 `systemlist()` 同步执行 `daemon --version`。也就是
  说,daemon 卡在慢文件系统上时,你用来诊断卡顿的那条命令自己会先把 Vim 冻住。改成
  用 job 探测并缓存,Health 在结果到达前显示 `probing…`。
- daemon 协议不匹配此前只报 “backend protocol version mismatch”,在 18 列宽的窗口
  里等于什么都没说。这几乎总是“更新了插件但没重新构建 `lib/`”,现在直接给出修法:
  minimap 上显示 `daemon is / out of date / run install.sh`,Health 显示
  `[FAIL] daemon protocol: daemon vN, plugin expects vM — run ./install.sh`。
- Health 新增配置检查:`'encoding'` 不是 utf-8 却在用 braille/blocks 时给出告警;
  以及拼错的选项名——`g:simpleminimap_*` 里插件不认识的名字会被列出并给出最接近的
  候选(`g:simpleminimap_widht` → `g:simpleminimap_width`)。此前拼错的选项会被永远
  静默忽略。已知选项表由 `tests/vim_health.vim` 与 `plugin/simpleminimap.vim` 实际
  归一化的名字比对,不会漂移。
- `daemon --version` 的探测结果此前只按路径缓存,而且没有任何路径会清掉它。
  `./install.sh` 恰恰是把新 daemon 覆盖写回同一个路径,于是 Health 在整个会话里
  一直报旧版本——包括它自己刚刚让你去做的那次重建之后,`:SimpleMinimapRestart`
  也不管用。现在缓存键是二进制的身份(路径 + mtime + 大小),原地重建即失效;
  `StopBackend()`(也就是 `:SimpleMinimapRestart` 与 `simpleminimap#Stop()`)
  另外会无条件丢弃缓存,以覆盖“把 `g:simpleminimap_daemon_path` 指向另一个同龄
  同大小的构建”这种 stamp 分辨不出的情况。

- help 里 `|simpleminimap#UnknownOptions()|` 指向一个从未定义过的 tag,在帮助里对它
  按 CTRL-] 只会得到 `E149`。现在补上 `*simpleminimap#UnknownOptions()*` 与
  `*simpleminimap#KnownOptions()*` 两个 tag,并说明它们各自返回什么。
- `g:simpleminimap_auto_restart` 条目里用 `*not*` 做强调,而 `*...*` 在 help 里是
  tag 定义语法:`:helptags` 因此把 `not` 登记成了本插件的 tag,任何装了本插件的用户
  执行 `:help not` 都会跳到这里——在全局共享的 tag 命名空间里劫持了一个通用词。
- 新增 `make test-vim-doc` / `tests/vim_doc.vim`:校验 `doc/tags` 与 help 文件同步、
  本插件定义的每个 tag 都在自己的命名空间内、以及文中每个 `|link|` 都能解析。
  上面两个缺陷都在其他所有测试和肉眼审阅之下不可见,这个测试同时抓到它们。

### 构建与 CI 修复

- CI 的 msrv 作业固定在 `dtolnay/rust-toolchain@1.85.0`,而 `Cargo.toml` 声明的是
  `rust-version = "1.88"`。cargo 把“声明的 rust-version 高于当前工具链”当硬错误,
  所以该作业每次 push 都在编译前失败。现在工具链版本直接从 `Cargo.toml` 里读出来,
  两者不可能再漂移。
- CI 不再手写一份步骤清单,改为只跑 `make check`。手写清单正是
  `make core-verify`(vendored bundle 的 sha256 校验)一直没进 CI 的原因;新增的
  `tests/vim_scroll.vim`、`tests/vim_projection.vim`、`tests/vim_timeout.vim`
  也随之自动纳入。Makefile 现在是门禁的唯一定义处。

### 新增

- 按语法类别着色(`g:simpleminimap_colors`,默认 `0`)。此前 minimap 只有密度一个
  维度:注释块、字符串表和代码在概览里都只是“一片墨”,而“一眼看出哪里是注释、
  哪里是字符串”正是终端 minimap 与编辑器本身差距最大的地方。现在每条样本行按
  首个非空白列的语法项归入 注释 / 字符串 / 关键字 / 类型 / 无 五类之一(取
  `synIDtrans()` 后的高亮组,因此不需要逐语言的映射表),协议升到 v3:`G` 记录多
  一个 4 字符的类别字段,`R` 记录多一个逐单元格的类别字段——后台把一个单元格判给
  在其中留下墨点最多的类别,同分时取更具体的一类。前端用 text property 上色:
  有类别的单元格用 `SimpleMinimapSyn{Comment,String,Keyword,Type}`(默认分别链接
  `Comment` / `String` / `Statement` / `Type`),纯代码单元格仍然按密度分档,所以
  亮度这一维没有丢。代价是每条样本行一次 `synID()`(每行 minimap 最多 4 次),
  类别与采样文本一起缓存;语法状态只会向后传播,因此一次编辑会丢弃它*下方*所有
  区间的类别而保留上方的——在文件顶部打字会重新分类大半个 minimap,这也是它默认
  关闭的原因。需要 `+syntax` 与 `g:simpleminimap_shading`,
  `:SimpleMinimapHealth` 会说明缺哪一个。
- `simpleminimap#DebugStatus()` 增加 `protocol_version`(本插件说的协议版本),
  `simpleminimap#SampleCacheStats()` 增加 `classified`(至今送进 `synID()` 的行数)。
  前者让版本漂移的断言不必再硬编码一个下次升协议就过期的数字,后者让“这个类别是
  复用的还是重新推导的”可被观测——分类缓存的失效规则就是靠它测的。
- 叠加层(overlay)提供者注册表 `simpleminimap#RegisterOverlay()`,以及在它之上的
  quickfix / location list / marks / diff 四个内置投影。此前 minimap 只能显示
  *别的插件已经放成 Vim sign* 的东西:`:grep` 结果、位置列表、`'a`-`'z` 标记、
  `:diffthis` 一律看不见,而套件里的兄弟插件想喂数据给 minimap 就只能去放它们本来
  并不想放的 sign。provider 是一个函数,拿到 `{bufnr, winid, rows}`,返回
  `[{lnum, category}]`;抛异常的 provider 只会被记进 `:SimpleMinimapLog` 并跳过,
  不会连累这一次重绘。由 `g:simpleminimap_overlays` 决定哪些生效,默认
  `['signs', 'search']`——也就是与此前完全相同的行为。
- quickfix 与 location list 的投影在 `QuickFixCmdPost` 上立即刷新,不必等到下一次
  `CursorHold`(最长 `'updatetime'`)才看到新的 `:grep` 结果。
- 新增高亮组 `SimpleMinimapMark`(默认链接 `Identifier`)。
- 新增 popup 覆盖模式(`g:simpleminimap_display = 'popup'`,默认仍为 `'split'`)。
  minimap 浮在被跟踪窗口之上,贴着 `g:simpleminimap_side` 那一侧、与该窗口等高,
  完全不占用 Vim 的窗口:数窗口的插件看不见它,`<C-w>` 的肌肉记忆不受影响,分屏
  开合与改变大小时它会跟着走。这也是本插件与 satellite.nvim / nvim-scrollview
  之间最大的结构差异,此前 README 的“已知限制”里就写着这一条。
  Vim 不允许把光标移进 popup——这是 Vim 的规则,不是这里的取舍——所以该模式下
  没有缓冲区按键表、没有鼠标导航,`:SimpleMinimapFocus` 会明确告诉你而不是默默
  什么都不做;渲染、密度着色、全部叠加层、视口/光标高亮带、resize/style/refresh
  则与 split 模式完全一致。没有 `+popupwin` 的 Vim 自动回退到 `'split'`,
  `:SimpleMinimapHealth` 会说明。
- 短文件现在按比例铺满 minimap(`g:simpleminimap_fill`,默认 `'proportional'`)。
  此前的刻度固定是“4 行源码 = 1 行 minimap”,于是任何短于 minimap 高度四倍的文件都
  只画在窗口顶部一小块里:50 行高的 minimap 打开一个 40 行的文件,只画 10 行,剩下
  40 行是死的;视口高亮无论光标在哪都盖住整块,滚动位置什么也说明不了,点在空白区
  更是毫无反应。而在高一点的终端上,大多数文件都短于这个门槛——也就是说这是*默认*
  体验。现在默认一行源码占一行 minimap,想要固定刻度可设 `'compact'`。
- 顺带修掉:点击/跳转到已渲染行之下的空白区此前解析为“没有目标”,什么都不做;
  现在解析到最后一行真实的 row。
- 增量采样(`g:simpleminimap_incremental`,默认开)。此前每次渲染都要重读整个
  buffer:每个 minimap 行要取最多 12 行源码并逐字符归一化成显示单元格,60 行的
  minimap 就是 720 次——而且在一行里敲一个字符,这 720 次会在每个防抖周期里原样
  再付一遍,全在主线程上。现在按行区间缓存采样结果,由 `listener_add()` 回调只失效
  被编辑触及的区间;增删行会移动所有区间边界,因此整块丢弃。读缓存前先
  `listener_flush()`,所以缓存里的区间不可能比触发这次渲染的那次编辑更旧——否则
  body 签名会与上一次相同,渲染被当成缓存命中跳过,minimap 就再也不会自己纠正。
  `:SimpleMinimapRefresh!` 同样绕过缓存,`:SimpleMinimapHealth` 报告复用与重采样的
  区间数。
- 每条命令都补齐了 `<Plug>` 目标(open/close/unpin/refresh/refresh-all/style/
  restart/health/log)。此前 14 条命令只有 4 个 `<Plug>`,关掉默认映射的用户只能
  手写 `<Cmd>SimpleMinimap...<CR>` 字面量,插件这边既无法重定义也无法弃用。
- 视口拖拽:按住左键从视口高亮带内起手,拖动的是视口本身——minimap 直接当滚动条
  用,这是它最常见的用途,此前做不到。带外起手仍然是原来的“跳到该带并连续预览”,
  单击(没有变成拖动)的行为在两种情况下都保持不变。可用
  `g:simpleminimap_drag_thumb = 0` 关闭。

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
