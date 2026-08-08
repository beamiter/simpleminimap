# SimpleMinimap

SimpleMinimap 是一个面向 **Vim 9** 的右侧代码缩略图插件。它参考
[SimpleTree](https://github.com/beamiter/simpletree) 的 Vim9 前端 + Rust 后台分层，
但把后台任务改成代码密度压缩：Vim 负责窗口、缓冲区状态和交互，Rust 负责把有限的代码样本渲染成终端友好的 Braille/Block/ASCII 缩略图。

> 这不是像素级复刻 VS Code。终端字符网格无法完整重现语法着色的小像素画布；
> SimpleMinimap 提供的是相同的使用方式：最右侧概览、当前视口标记、光标标记、点击或回车跳转，以及编辑时自动刷新。

```text
┌──────────────────────────── 编辑窗口 ────────────────────────────┬── minimap ──┐
│ fn main() {                                                       │ ⡇⠉⡇⣿⡀   │
│     let answer = 42;                                              │ ⡇⣀⡇⢸⡇   │
│     println!("{}", answer);                                       │ ████████   │ ← 当前视口
│ }                                                                 │ ⠁⠉⠉⠉⠁   │
└───────────────────────────────────────────────────────────────────┴────────────┘
```

## 特性

- 在当前标签页最右侧创建固定宽度的垂直分屏；每个标签页最多一个 minimap。
- Rust 常驻后台异步渲染，不在 Vim 主线程执行密集字符压缩。
- 默认使用 Unicode Braille：一个字符承载 `2 × 4` 个密度点；也可切换为 Block 或纯 ASCII。
- 按单元格的代码密度分三档着色（text properties 实现）：密集代码更亮、稀疏代码更暗，
  minimap 呈现出层次感；需要 `+textprop`，可用 `g:simpleminimap_shading` 关闭。
- 可选按语法类别着色：打开 `g:simpleminimap_colors` 后，每条样本行按首个非空白列的语法
  归入注释/字符串/关键字/类型四类之一，后台按每个单元格里贡献墨点最多的类别上色，
  注释块、字符串表和代码因此一眼可辨；纯代码单元格仍沿用密度分档。需要 `+syntax`。
- 高亮当前编辑窗口的可见范围和光标所在的 minimap 行，并把 Git、LSP、
  lint 等插件放置的 Vim signs 聚合投影到概览中；signs 按名称自动分类为
  error/warning/info/git add/change/delete 并使用各自的高亮组，同一行取最高严重级。
- `hlsearch` 激活时把搜索匹配投影到 minimap（需要 Vim 9.1.0009+ 的
  `matchbufline()`，不满足时静默禁用）。
- 跟随当前标签页最近进入的普通编辑窗口；切换缓冲区、编辑、保存、改变 `tabstop` 或调整窗口大小时自动更新。
- 多分屏时可把 minimap 锁定到当前源分屏，查看其他窗口不会带走概览；源分屏失效时自动安全解锁。
- 支持键盘预览/跳转、鼠标滚轮滚动，以及按住左键拖动视口；跳转会进入 Vim jump list。
- 运行时可切换 Braille/Block/ASCII、调整宽度，也可把 minimap 放到左侧。
- 带防抖、协议握手和请求合并；旧响应不会覆盖新状态，后台异常退出可自动恢复，
  后台侧新请求可直接抢占未完成的旧请求。
- 请求体签名缓存：内容未变化时跳过后台往返，只刷新视口/光标/sign/搜索叠加层。
- 大文件使用有界自适应采样；CJK、emoji、组合字符和 tab 按 Vim 实际显示单元归一化。
- Rust 后台只使用标准库，没有运行时依赖，也不需要联网拉取 crate。

## 要求

| 组件 | 要求 |
|---|---|
| Vim | Vim 9.0 或更新版本，编译时包含 `+job` 和 `+channel` |
| Rust | Rust 1.88 或更新版本及 Cargo，仅从源码构建后台时需要 |
| 编码 | 推荐 UTF-8；不支持 Braille 的终端可使用 `blocks` 或 `ascii` |
| Neovim | 不支持；插件使用 Vim9 script 与 Vim job/channel API |

检查 Vim：

```vim
:echo v:version
:echo has('job')
:echo has('channel')
```

后两项应返回 `1`。

## 安装

### Vim 原生 package

把目录放入 Vim 的 `pack/*/start/`，然后构建本机后台：

```sh
mkdir -p ~/.vim/pack/plugins/start
unzip simpleminimap.zip -d ~/.vim/pack/plugins/start
~/.vim/pack/plugins/start/simpleminimap/install.sh
```

Windows PowerShell：

```powershell
New-Item -ItemType Directory -Force "$HOME\vimfiles\pack\plugins\start" | Out-Null
Expand-Archive .\simpleminimap.zip "$HOME\vimfiles\pack\plugins\start"
& "$HOME\vimfiles\pack\plugins\start\simpleminimap\install.ps1"
```

### vim-plug

```vim
call plug#begin()
Plug 'beamiter/simpleminimap', { 'do': './install.sh' }
call plug#end()
```

### 手动构建

```sh
cargo build --release --locked
mkdir -p lib
cp target/release/simpleminimap-daemon lib/
```

推荐使用 `install.sh` / `install.ps1`：脚本固定本机 Rust target、使用独立构建目录、运行后台自测，并在同一目录内替换最终可执行文件。

插件按以下顺序查找后台：

1. `g:simpleminimap_daemon_path`
2. 插件目录的 `lib/simpleminimap-daemon`
3. 插件目录的 `target/release/` 与 `target/debug/`
4. `runtimepath` 中各插件的 `lib/`
5. `$PATH`

## 使用

```vim
:SimpleMinimap          " 打开/关闭
:SimpleMinimapOpen      " 打开
:SimpleMinimapClose     " 关闭
:SimpleMinimapRefresh   " 立即重绘当前 tab
:SimpleMinimapRefresh!  " 强制重绘所有已打开 tab session
:SimpleMinimapFocus     " 聚焦 minimap；尚未打开时先打开
:SimpleMinimapPin       " 锁定当前源分屏，不再随焦点切换
:SimpleMinimapUnpin     " 恢复跟随当前活动分屏
:SimpleMinimapTogglePin " 切换锁定状态
:SimpleMinimapResize 22 " 实时调整所有标签页的宽度（6..80）
:SimpleMinimapStyle     " 循环 braille → blocks → ascii
:SimpleMinimapStyle ascii
:SimpleMinimapRestart   " 重启后台并保留当前 session
:SimpleMinimapHealth    " 环境与后台诊断（daemon 版本/协议、往返延迟、请求超时与熔断、配置拼写检查）
:SimpleMinimapDebug     " 完整内部状态字典
```

默认全局映射是 `<leader>m`，但仅在该按键尚未被占用且
`g:simpleminimap_set_default_mapping` 为 `1` 时安装。插件还提供：

```vim
<Plug>(simpleminimap-toggle)
<Plug>(simpleminimap-open)
<Plug>(simpleminimap-close)
<Plug>(simpleminimap-focus)
<Plug>(simpleminimap-pin)         " 幂等锁定
<Plug>(simpleminimap-unpin)
<Plug>(simpleminimap-toggle-pin)  " 切换锁定状态
<Plug>(simpleminimap-refresh)
<Plug>(simpleminimap-refresh-all) " 等价于 :SimpleMinimapRefresh!
<Plug>(simpleminimap-style)
<Plug>(simpleminimap-restart)
<Plug>(simpleminimap-health)
<Plug>(simpleminimap-log)
```

每条命令都有对应的 `<Plug>` 目标：关掉默认映射后不必再手写
`<Cmd>SimpleMinimap...<CR>` 字面量。

例如：

```vim
let g:simpleminimap_set_default_mapping = 0
nmap <silent> <leader>u <Plug>(simpleminimap-toggle)
nmap <silent> <leader>up <Plug>(simpleminimap-pin)
```

`<Plug>(simpleminimap-pin)` 可重复调用而不会解锁；需要单键来回切换时请映射
`<Plug>(simpleminimap-toggle-pin)`。

minimap 缓冲区内的按键：

| 按键 | 操作 |
|---|---|
| `<CR>` | 跳到当前 minimap 行对应源代码范围的中点 |
| `<Space>` | 预览当前范围并保持 minimap 焦点 |
| 左键单击 | 跳到目标范围 |
| 左键拖动 | 从视口高亮带内起手 = 拖动视口（把 minimap 当滚动条用）；从带外起手 = 连续预览 |
| 鼠标滚轮 | 滚动源代码窗口 |
| `r` | 立即刷新 |
| `s` | 循环切换渲染风格 |
| `p` | 锁定/解锁当前源分屏；锁定时状态栏显示 `pinned` |
| `+` / `-` | 所有标签页的 minimap 每次增加/减少 2 列宽度 |
| `<Esc>` | 焦点返回源代码窗口 |
| `q` | 关闭当前标签页的 minimap |

鼠标交互需要 Vim 已启用相应终端/GUI 鼠标事件，例如 `set mouse=a`。

## 配置

在插件加载前设置：

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `g:simpleminimap_width` | `18` | minimap 宽度，限制为 `6..80` |
| `g:simpleminimap_max_columns` | `120` | 每条样本最多分析的逻辑列数，限制为 `20..1000` |
| `g:simpleminimap_debounce` | `80` | 编辑后的重绘防抖，单位毫秒，限制为 `0..2000` |
| `g:simpleminimap_render_style` | `'braille'` | `'braille'`、`'blocks'` 或 `'ascii'` |
| `g:simpleminimap_fill` | `'proportional'` | minimap 行数策略：`'proportional'` 每行源码占一行（直到行数用完），`'compact'` 保持历史上固定的“4 行源码 = 1 行 minimap” |
| `g:simpleminimap_sampling` | `'adaptive'` | `'adaptive'` 会在每个采样带中选择更有信息量的代码行；`'uniform'` 固定取中点 |
| `g:simpleminimap_display` | `'split'` | minimap 的呈现方式：`'split'` 独立窗口（可进入、有按键表与状态栏），`'popup'` 浮在被跟踪窗口之上、不占用任何窗口（只读展示，无法进入，需要 `+popupwin`） |
| `g:simpleminimap_side` | `'right'` | 新建 minimap 的位置：`'right'` 或 `'left'` |
| `g:simpleminimap_daemon_path` | `''` | 后台可执行文件绝对路径；空值时自动查找 |
| `g:simpleminimap_show_statusline` | `1` | 是否显示 minimap 状态栏标题 |
| `g:simpleminimap_overlays` | `['signs', 'search']` | 哪些叠加层会画在渲染结果之上；内置名字为 `signs` / `search` / `quickfix` / `loclist` / `marks` / `diff`，也可以是 `simpleminimap#RegisterOverlay()` 注册的第三方名字 |
| `g:simpleminimap_show_signs` | `1` | 是否把源缓冲区中的 Vim signs 聚合显示到 minimap |
| `g:simpleminimap_show_search` | `1` | 是否把 `hlsearch` 匹配投影到 minimap（需要 `matchbufline()`）；按行区间扫描并在首个命中处停止，不再跳过大文件 |
| `g:simpleminimap_incremental` | `1` | 是否按行区间缓存采样文本，并用 `listener_add()` 只失效被编辑触及的区间；设为 `0` 则每次渲染都重读整个 buffer |
| `g:simpleminimap_shading` | `1` | 是否按密度给 minimap 单元格分档着色（需要 `+textprop`） |
| `g:simpleminimap_colors` | `0` | 是否按语法类别（注释/字符串/关键字/类型）给单元格上色；纯代码单元格仍用密度分档。需要 `+syntax` 和 `g:simpleminimap_shading`。每条样本行一次 `synID()`，且编辑会失效其下方所有区间的分类，因此默认关闭 |
| `g:simpleminimap_ignore_filetypes` | `[]` | 不跟随的 filetype 列表 |
| `g:simpleminimap_auto_close` | `0` | 当前标签页没有普通编辑窗口时是否自动关闭 |
| `g:simpleminimap_auto_open` | `0` | Vim 启动或进入标签页时自动打开 |
| `g:simpleminimap_auto_restart` | `1` | 后台异常退出（或连续超时卡死）时自动重启，60 秒滚动窗口内最多 3 次；用尽后熔断，只有 `:SimpleMinimapRestart` 能恢复；设为 `0` 时任何路径都不会自动拉起进程 |
| `g:simpleminimap_request_timeout_ms` | `5000` | 单次渲染请求的超时（毫秒，限制 `100..600000`）；连续两次超时会重启 daemon，且与崩溃共用同一份重启预算，设为 `0` 关闭 |
| `g:simpleminimap_mouse_scroll_lines` | 跟随 `'mousescroll'` | 在 minimap 上滚动一格滚轮时源窗口移动的行数，限制为 `1..50`；未显式设置时取 `'mousescroll'` 的 `ver:`，没有该选项或为 `ver:0` 时回退到 `3` |
| `g:simpleminimap_drag_thumb` | `1` | 从视口高亮带内起手的左键拖动是否滚动源窗口（滚动条式）；设为 `0` 恢复“拖动即预览” |
| `g:simpleminimap_set_default_mapping` | `1` | 是否在 `<leader>m` 空闲时安装默认映射 |
| `g:simpleminimap_debug` | `0` | 是否通过 `:messages` 输出调试日志 |

`g:simpleminimap_width` 是全局配置：运行时执行
`:SimpleMinimapResize`，或在任一 minimap 内按 `+` / `-`，会同步调整所有已打开
标签页的 minimap；之后新开的 session 也使用同一宽度。

`:SimpleMinimapRefresh` 只强制刷新当前标签页并绕过内容签名缓存；加 `!`
会以相同方式刷新所有存活 session，同时保持当前 tab/window 不变。已经关闭或
失效的 session 只会被清理，不会因全局刷新而重新打开。

minimap 窗口的 `statusline`、`wincolor`、`winfixwidth` 由插件自己负责：在
`BufWinEnter` / `WinEnter` 上会重新断言一次，因此逐窗口改写 `&l:statusline`
的状态栏插件不会再把 minimap 标题清空。想主动配合而不是被纠正的状态栏管理器，
可以直接取用规范值，不必硬编码：

```vim
if &filetype ==# 'simpleminimap'
  let &l:statusline = simpleminimap#StatuslineExpr()
endif
```

`g:simpleminimap_show_statusline` 为 0 时它返回空串。

示例：

```vim
let g:simpleminimap_width = 16
let g:simpleminimap_max_columns = 160
let g:simpleminimap_debounce = 120
let g:simpleminimap_render_style = 'blocks'
let g:simpleminimap_side = 'left'
let g:simpleminimap_ignore_filetypes = ['startify', 'dashboard']
let g:simpleminimap_set_default_mapping = 0
```

### 高亮

默认链接：

| 高亮组 | 默认链接 | 用途 |
|---|---|---|
| `SimpleMinimapNormal` | `Comment` | minimap 正文 |
| `SimpleMinimapViewport` | `Visual` | 当前可见范围 |
| `SimpleMinimapCursor` | `Search` | 光标所在范围 |
| `SimpleMinimapSearch` | `IncSearch` | 搜索匹配所在范围 |
| `SimpleMinimapSign` | `WarningMsg` | 未分类 sign 所在范围 |
| `SimpleMinimapSignError` | `ErrorMsg` | error 类 sign |
| `SimpleMinimapSignWarning` | `WarningMsg` | warning 类 sign |
| `SimpleMinimapSignInfo` | `MoreMsg` | info/hint/note 类 sign |
| `SimpleMinimapSignAdd` | `DiffAdd` | Git 新增行 sign |
| `SimpleMinimapSignChange` | `DiffChange` | Git 修改行 sign |
| `SimpleMinimapSignDelete` | `DiffDelete` | Git 删除行 sign |
| `SimpleMinimapMark` | `Identifier` | 标记(`'a`-`'z` / `'A`-`'Z`)所在范围 |
| `SimpleMinimapShadeLow` | `NonText` | 稀疏密度单元格 |
| `SimpleMinimapShadeMid` | `Comment` | 中等密度单元格 |
| `SimpleMinimapShadeHigh` | `Normal` | 高密度单元格 |
| `SimpleMinimapSynComment` | `Comment` | 注释贡献墨点最多的单元格（`g:simpleminimap_colors`） |
| `SimpleMinimapSynString` | `String` | 字符串等字面量贡献墨点最多的单元格 |
| `SimpleMinimapSynKeyword` | `Statement` | 关键字、预处理行贡献墨点最多的单元格 |
| `SimpleMinimapSynType` | `Type` | 类型、标识符声明贡献墨点最多的单元格 |
| `SimpleMinimapTitle` | `Title` | 状态栏标题 |

自定义示例：

```vim
augroup MySimpleMinimapColors
  autocmd!
  autocmd ColorScheme * highlight SimpleMinimapViewport cterm=NONE gui=NONE ctermbg=238 guibg=#3a3a3a
  autocmd ColorScheme * highlight SimpleMinimapCursor cterm=bold gui=bold ctermbg=24 guibg=#005f87
augroup END
```

## 渲染模型

1. Vim 根据 minimap 实际高度把整个源缓冲区切成等比例范围。
2. 每个范围被分成 4 个采样带；自适应模式在每带的起点、中点和终点中选择信息密度最高的代码行。范围不超过 4 行时不会跳过任何行。
3. 每条样本只截取 `g:simpleminimap_max_columns` 范围内的内容，并按 Vim 的显示宽度展开宽字符、忽略零宽组合字符。
4. Rust 把非空白字符转换为占用点，并按水平比例压缩。
5. Braille 模式把 4 条样本映射为字符的 4 个点行，把相邻逻辑列映射为 2 个点列。
6. 每个渲染单元格附带一个 0..3 的密度档位数字，以及一个语法类别字符；Vim 把相邻同类单元格
   合并成 text property，实现密集更亮、稀疏更暗的分档着色，以及按语法类别的上色。
7. Vim 收到 `{start, end, text, shade, classes}` 后更新 scratch buffer，并叠加视口、光标、sign 与搜索高亮。

因此，Vim 与后台之间传输的数据量由窗口高度和列数限制，而不是直接随文件总行数增长。

## 后台协议

协议（v3）是 UTF-8、TAB 分隔、逐行传输。TAB、换行、回车和 `%` 使用 `%XX` 转义。

```text
READY <version>
B <id> <width> <height> <max_columns> <tabstop> <style> <source_lines> <groups> <version>
G <id> <start> <end> <sample1> <sample2> <sample3> <sample4> <classes>
E <id>

B <id> <source_lines> <rows>
R <id> <start> <end> <rendered_text> <shade_digits> <class_chars>
E <id>
X <id> <message>
```

后台对宽度、高度、列数、tabstop 和组数做边界检查。标准输出只写协议记录；诊断写标准错误。
前端只有在收到匹配版本的 `READY` 后才发送渲染请求，并会验证响应范围连续性、
尺寸和最新请求 ID。后台限制单条协议记录大小，并严格校验转义和 UTF-8。
在旧请求尚未完成时收到新的 `B` 记录，后台会对旧请求回复 `X`（superseded）
并直接处理新请求。前端在发送前会对请求体做 `sha256()` 签名，与上次已应用
的渲染一致时跳过本次后台往返。

## 开发与测试

```sh
make fmt             # rustfmt --check
make lint            # clippy -D warnings
make test-rust       # Rust 单元测试
make test-daemon     # release 后台 CLI 与内置自测
make test-vim        # Vim + Python mock 后台
make test-vim-real   # Vim + release Rust 后台
make test            # 全部测试
```

Vim 集成测试会验证：异步握手、左右侧 session、重复打开防重、行范围映射、
视口/光标/sign match、预览与跳转、运行时 resize/style、编辑合并、后台重启，
以及源窗口消失后的生命周期恢复。

## 已知限制

- 这是字符密度概览，不渲染真实字体像素。语法着色（`g:simpleminimap_colors`）基于 Vim 自身的
  syntax，按行取首个非空白列的语法组，不是 Tree-sitter 的逐 token 着色。
- 默认的 `'split'` 模式使用独立垂直分屏，因此会占用 Vim 的一个窗口；
  `g:simpleminimap_display = 'popup'` 改为浮在编辑窗口之上、不占窗口，代价是 Vim 不允许
  把光标移进 popup，因此该模式没有按键表、没有鼠标导航，是纯展示的概览。
- signs 会聚合到对应 minimap 行并使用同一个高亮组，不保留每种 sign 的原始颜色。
- `diff` 叠加层只能标出本缓冲区里*存在*的差异行；相对另一侧被删除的行在 Vim 里
  是 filler，没有行号，因此两侧的 minimap 都不会显示它——和 diff 本身一致。

## 许可证

MIT
