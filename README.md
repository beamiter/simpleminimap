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
- 高亮当前编辑窗口的可见范围和光标所在的 minimap 行。
- 跟随当前标签页最近进入的普通编辑窗口；切换缓冲区、编辑、保存、改变 `tabstop` 或调整窗口大小时自动更新。
- 在 minimap 中按 `<CR>` 或单击鼠标，跳到对应源代码范围的中点。
- 带防抖和请求编号；旧的异步响应不会覆盖更新的缓冲区状态。
- 大文件使用有界采样：每个 minimap 行最多读取 4 条代表性源代码行，传输列数也有上限。
- Rust 后台只使用标准库，没有运行时依赖，也不需要联网拉取 crate。

## 要求

| 组件 | 要求 |
|---|---|
| Vim | Vim 9.0 或更新版本，编译时包含 `+job` 和 `+channel` |
| Rust | Rust 1.70 或更新版本及 Cargo，仅从源码构建后台时需要 |
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
:SimpleMinimapHealth    " 环境和后台状态
:SimpleMinimapDebug     " 完整内部状态字典
```

默认全局映射是 `<leader>m`，但仅在该按键尚未被占用且
`g:simpleminimap_set_default_mapping` 为 `1` 时安装。插件还提供：

```vim
<Plug>(simpleminimap-toggle)
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
| 左键单击 | 跳到点击位置对应的源代码范围 |
| `r` | 立即刷新 |
| `q` | 关闭当前标签页的 minimap |

## 配置

在插件加载前设置：

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `g:simpleminimap_width` | `18` | minimap 宽度，限制为 `6..80` |
| `g:simpleminimap_max_columns` | `120` | 每条样本最多分析的逻辑列数，限制为 `20..1000` |
| `g:simpleminimap_debounce` | `80` | 编辑后的重绘防抖，单位毫秒，限制为 `0..2000` |
| `g:simpleminimap_render_style` | `'braille'` | `'braille'`、`'blocks'` 或 `'ascii'` |
| `g:simpleminimap_daemon_path` | `''` | 后台可执行文件绝对路径；空值时自动查找 |
| `g:simpleminimap_show_statusline` | `1` | 是否显示 minimap 状态栏标题 |
| `g:simpleminimap_auto_close` | `0` | 当前标签页没有普通编辑窗口时是否自动关闭 |
| `g:simpleminimap_set_default_mapping` | `1` | 是否在 `<leader>m` 空闲时安装默认映射 |
| `g:simpleminimap_debug` | `0` | 是否通过 `:messages` 输出调试日志 |

示例：

```vim
let g:simpleminimap_width = 16
let g:simpleminimap_max_columns = 160
let g:simpleminimap_debounce = 120
let g:simpleminimap_render_style = 'blocks'
let g:simpleminimap_set_default_mapping = 0
```

### 高亮

默认链接：

| 高亮组 | 默认链接 | 用途 |
|---|---|---|
| `SimpleMinimapNormal` | `Comment` | minimap 正文 |
| `SimpleMinimapViewport` | `Visual` | 当前可见范围 |
| `SimpleMinimapCursor` | `Search` | 光标所在范围 |
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
2. 每个范围最多选取 4 条代表性代码行；范围不超过 4 行时不会跳过任何行。
3. 每条样本只截取 `g:simpleminimap_max_columns` 范围内的内容。
4. Rust 把非空白字符转换为占用点，并按水平比例压缩。
5. Braille 模式把 4 条样本映射为字符的 4 个点行，把相邻逻辑列映射为 2 个点列。
6. Vim 收到 `{start, end, text}` 后更新 scratch buffer，并叠加视口与光标高亮。

因此，Vim 与后台之间传输的数据量由窗口高度和列数限制，而不是直接随文件总行数增长。

## 后台协议

协议是 UTF-8、TAB 分隔、逐行传输。TAB、换行、回车和 `%` 使用 `%XX` 转义。

```text
READY <version>
B <id> <width> <height> <max_columns> <tabstop> <style> <source_lines> <groups> <version>
G <id> <start> <end> <sample1> <sample2> <sample3> <sample4>
E <id>

B <id> <source_lines> <rows>
R <id> <start> <end> <rendered_text>
E <id>
X <id> <message>
```

后台对宽度、高度、列数、tabstop 和组数做边界检查。标准输出只写协议记录；诊断写标准错误。

## 开发与测试

```sh
make fmt             # rustfmt --check
make lint            # clippy -D warnings
make test-rust       # Rust 单元测试
make test-vim        # Vim + Python mock 后台
make test-vim-real   # Vim + release Rust 后台
make test            # 全部测试
```

Vim 集成测试会验证：异步启动、右侧 session 创建、重复打开防重、行范围映射、视口/光标 match、跳转，以及编辑后的新请求。

## 已知限制

- 这是字符密度概览，不包含 Tree-sitter/语法组颜色，也不渲染真实字体像素。
- Rust 当前按 Unicode 标量推进逻辑列；东亚宽字符在结构概览中按一个逻辑列处理。
- minimap 使用独立垂直分屏，因此会占用 Vim 的一个窗口，而不是覆盖在编辑窗口内部。
- 当前点击会跳转，但尚未实现像 VS Code 那样按住并拖动视口框。

## 许可证

MIT
