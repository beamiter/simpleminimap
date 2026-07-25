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
- 高亮当前编辑窗口的可见范围和光标所在的 minimap 行，并把 Git、LSP、
  lint 等插件放置的 Vim signs 聚合投影到概览中；signs 按名称自动分类为
  error/warning/info/git add/change/delete 并使用各自的高亮组，同一行取最高严重级。
- `hlsearch` 激活时把搜索匹配投影到 minimap（需要 Vim 9.1.0009+ 的
  `matchbufline()`，不满足时静默禁用）。
- 跟随当前标签页最近进入的普通编辑窗口；切换缓冲区、编辑、保存、改变 `tabstop` 或调整窗口大小时自动更新。
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
| Rust | Rust 1.85 或更新版本及 Cargo，仅从源码构建后台时需要 |
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
:SimpleMinimapRefresh   " 立即重绘
:SimpleMinimapFocus     " 聚焦 minimap；尚未打开时先打开
:SimpleMinimapResize 22 " 实时调整宽度（6..80）
:SimpleMinimapStyle     " 循环 braille → blocks → ascii
:SimpleMinimapStyle ascii
:SimpleMinimapRestart   " 重启后台并保留当前 session
:SimpleMinimapHealth    " 环境和后台状态（含 daemon 版本、往返延迟、渲染统计）
:SimpleMinimapDebug     " 完整内部状态字典
```

默认全局映射是 `<leader>m`，但仅在该按键尚未被占用且
`g:simpleminimap_set_default_mapping` 为 `1` 时安装。插件还提供：

```vim
<Plug>(simpleminimap-toggle)
<Plug>(simpleminimap-focus)
```

例如：

```vim
let g:simpleminimap_set_default_mapping = 0
nmap <silent> <leader>u <Plug>(simpleminimap-toggle)
```

minimap 缓冲区内的按键：

| 按键 | 操作 |
|---|---|
| `<CR>` | 跳到当前 minimap 行对应源代码范围的中点 |
| `<Space>` | 预览当前范围并保持 minimap 焦点 |
| 左键单击/拖动 | 跳到目标范围；拖动时连续移动视口 |
| 鼠标滚轮 | 滚动源代码窗口 |
| `r` | 立即刷新 |
| `s` | 循环切换渲染风格 |
| `+` / `-` | 每次增加/减少 2 列宽度 |
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
| `g:simpleminimap_sampling` | `'adaptive'` | `'adaptive'` 会在每个采样带中选择更有信息量的代码行；`'uniform'` 固定取中点 |
| `g:simpleminimap_side` | `'right'` | 新建 minimap 的位置：`'right'` 或 `'left'` |
| `g:simpleminimap_daemon_path` | `''` | 后台可执行文件绝对路径；空值时自动查找 |
| `g:simpleminimap_show_statusline` | `1` | 是否显示 minimap 状态栏标题 |
| `g:simpleminimap_show_signs` | `1` | 是否把源缓冲区中的 Vim signs 聚合显示到 minimap |
| `g:simpleminimap_show_search` | `1` | 是否把 `hlsearch` 匹配投影到 minimap（需要 `matchbufline()`） |
| `g:simpleminimap_shading` | `1` | 是否按密度给 minimap 单元格分档着色（需要 `+textprop`） |
| `g:simpleminimap_ignore_filetypes` | `[]` | 不跟随的 filetype 列表 |
| `g:simpleminimap_auto_close` | `0` | 当前标签页没有普通编辑窗口时是否自动关闭 |
| `g:simpleminimap_auto_open` | `0` | Vim 启动或进入标签页时自动打开 |
| `g:simpleminimap_auto_restart` | `1` | 后台异常退出时限次自动重启 |
| `g:simpleminimap_mouse_scroll_lines` | `3` | 在 minimap 上滚动一格滚轮时源窗口移动的行数，限制为 `1..50` |
| `g:simpleminimap_set_default_mapping` | `1` | 是否在 `<leader>m` 空闲时安装默认映射 |
| `g:simpleminimap_debug` | `0` | 是否通过 `:messages` 输出调试日志 |

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
| `SimpleMinimapShadeLow` | `NonText` | 稀疏密度单元格 |
| `SimpleMinimapShadeMid` | `Comment` | 中等密度单元格 |
| `SimpleMinimapShadeHigh` | `Normal` | 高密度单元格 |
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
6. 每个渲染单元格附带一个 0..3 的密度档位数字；Vim 把相邻同档单元格合并成
   text property，实现密集更亮、稀疏更暗的分档着色。
7. Vim 收到 `{start, end, text, shade}` 后更新 scratch buffer，并叠加视口、光标、sign 与搜索高亮。

因此，Vim 与后台之间传输的数据量由窗口高度和列数限制，而不是直接随文件总行数增长。

## 后台协议

协议（v2）是 UTF-8、TAB 分隔、逐行传输。TAB、换行、回车和 `%` 使用 `%XX` 转义。

```text
READY <version>
B <id> <width> <height> <max_columns> <tabstop> <style> <source_lines> <groups> <version>
G <id> <start> <end> <sample1> <sample2> <sample3> <sample4>
E <id>

B <id> <source_lines> <rows>
R <id> <start> <end> <rendered_text> <shade_digits>
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

- 这是字符密度概览，不包含 Tree-sitter/语法组颜色，也不渲染真实字体像素。
- minimap 使用独立垂直分屏，因此会占用 Vim 的一个窗口，而不是覆盖在编辑窗口内部。
- signs 会聚合到对应 minimap 行并使用同一个高亮组，不保留每种 sign 的原始颜色。

## 许可证

MIT
