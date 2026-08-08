vim9script

if exists('g:loaded_simpleminimap')
  finish
endif
g:loaded_simpleminimap = 1

if !has('job') || !has('channel')
  echohl WarningMsg
  echom '[SimpleMinimap] Vim must be compiled with +job and +channel.'
  echohl None
  finish
endif

def ClampNumber(value: any, fallback: number, minimum: number, maximum: number): number
  if type(value) != v:t_number
    return fallback
  endif
  return min([maximum, max([minimum, value])])
enddef


def Flag(value: any, fallback: number): number
  if type(value) == v:t_bool
    return value ? 1 : 0
  endif
  if type(value) == v:t_number
    return value == 0 ? 0 : 1
  endif
  return fallback
enddef


def Choice(value: any, fallback: string, allowed: list<string>): string
  if type(value) == v:t_string && index(allowed, value) >= 0
    return value
  endif
  return fallback
enddef


g:simpleminimap_width = ClampNumber(get(g:, 'simpleminimap_width', 18), 18, 6, 80)
g:simpleminimap_max_columns = ClampNumber(get(g:, 'simpleminimap_max_columns', 120), 120, 20, 1000)
g:simpleminimap_debounce = ClampNumber(get(g:, 'simpleminimap_debounce', 80), 80, 0, 2000)
# With no explicit setting, scroll the source at the rate Vim scrolls a buffer,
# so the wheel feels the same over the minimap as over the code.  'mousescroll'
# arrived in 8.2.4358 and is missing from builds without mouse support, and
# ver:0 means "half a window", which has no fixed line count -- fall back to
# Vim's own historical default in both cases.  Vim9 resolves &option names at
# compile time and raises E113 for an unknown one even inside a guard, so the
# option has to be read through eval().
def DefaultScrollLines(): number
  if exists('+mousescroll')
    var setting: string = eval('&mousescroll')
    var vertical = str2nr(matchstr(setting, '\<ver:\zs\d\+'))
    if vertical > 0
      return vertical
    endif
  endif
  return 3
enddef

g:simpleminimap_mouse_scroll_lines = ClampNumber(get(g:, 'simpleminimap_mouse_scroll_lines', DefaultScrollLines()), 3, 1, 50)
g:simpleminimap_drag_thumb = Flag(get(g:, 'simpleminimap_drag_thumb', 1), 1)
g:simpleminimap_render_style = Choice(get(g:, 'simpleminimap_render_style', 'braille'), 'braille', ['braille', 'blocks', 'ascii'])
g:simpleminimap_sampling = Choice(get(g:, 'simpleminimap_sampling', 'adaptive'), 'adaptive', ['adaptive', 'uniform'])
g:simpleminimap_fill = Choice(get(g:, 'simpleminimap_fill', 'proportional'), 'proportional', ['proportional', 'compact'])
g:simpleminimap_side = Choice(get(g:, 'simpleminimap_side', 'right'), 'right', ['left', 'right'])
var configured_daemon_path = get(g:, 'simpleminimap_daemon_path', '')
g:simpleminimap_daemon_path = type(configured_daemon_path) == v:t_string ? configured_daemon_path : ''
g:simpleminimap_set_default_mapping = Flag(get(g:, 'simpleminimap_set_default_mapping', 1), 1)
g:simpleminimap_debug = Flag(get(g:, 'simpleminimap_debug', 0), 0)
g:simpleminimap_show_statusline = Flag(get(g:, 'simpleminimap_show_statusline', 1), 1)
g:simpleminimap_show_signs = Flag(get(g:, 'simpleminimap_show_signs', 1), 1)
g:simpleminimap_show_search = Flag(get(g:, 'simpleminimap_show_search', 1), 1)
g:simpleminimap_shading = Flag(get(g:, 'simpleminimap_shading', 1), 1)
g:simpleminimap_incremental = Flag(get(g:, 'simpleminimap_incremental', 1), 1)
g:simpleminimap_auto_close = Flag(get(g:, 'simpleminimap_auto_close', 0), 0)
g:simpleminimap_auto_open = Flag(get(g:, 'simpleminimap_auto_open', 0), 0)
g:simpleminimap_auto_restart = Flag(get(g:, 'simpleminimap_auto_restart', 1), 1)
# 0 disables the deadline entirely; anything else is clamped to a sane range.
g:simpleminimap_request_timeout_ms = type(get(g:, 'simpleminimap_request_timeout_ms', 5000)) == v:t_number
  && get(g:, 'simpleminimap_request_timeout_ms', 5000) <= 0
  ? 0
  : ClampNumber(get(g:, 'simpleminimap_request_timeout_ms', 5000), 5000, 100, 600000)
var configured_ignored_filetypes = get(g:, 'simpleminimap_ignore_filetypes', [])
g:simpleminimap_ignore_filetypes = type(configured_ignored_filetypes) == v:t_list ? configured_ignored_filetypes : []
# Which overlays paint on top of the rendered rows.  Normalised to a list of
# strings but deliberately NOT filtered against the built-in names: a plugin
# that calls simpleminimap#RegisterOverlay() registers after this file has run,
# and dropping its name here would make the registry useless to everyone but
# this plugin.
var configured_overlays = get(g:, 'simpleminimap_overlays', ['signs', 'search'])
g:simpleminimap_overlays = type(configured_overlays) == v:t_list
  ? filter(copy(configured_overlays), (_, v) => type(v) == v:t_string && v !=# '')
  : ['signs', 'search']

command! SimpleMinimap simpleminimap#Toggle()
command! SimpleMinimapOpen simpleminimap#Open()
command! SimpleMinimapClose simpleminimap#Close()
command! -bang SimpleMinimapRefresh simpleminimap#Refresh(<bang>0 ? true : false)
command! SimpleMinimapFocus simpleminimap#Focus()
command! SimpleMinimapPin simpleminimap#Pin()
command! SimpleMinimapUnpin simpleminimap#Unpin()
command! SimpleMinimapTogglePin simpleminimap#TogglePin()
command! SimpleMinimapRestart simpleminimap#Restart()
command! -nargs=? SimpleMinimapResize simpleminimap#Resize(<q-args>)
command! -nargs=? -complete=customlist,simpleminimap#CompleteStyle SimpleMinimapStyle simpleminimap#SetStyle(<q-args>)
command! SimpleMinimapHealth simpleminimap#Health()
command! SimpleMinimapDebug echo simpleminimap#DebugStatus()
command! SimpleMinimapLog call simpleminimap#ShowLog()

nnoremap <silent> <Plug>(simpleminimap-toggle) <Cmd>SimpleMinimap<CR>
nnoremap <silent> <Plug>(simpleminimap-focus) <Cmd>SimpleMinimapFocus<CR>
nnoremap <silent> <Plug>(simpleminimap-pin) <Cmd>SimpleMinimapPin<CR>
nnoremap <silent> <Plug>(simpleminimap-toggle-pin) <Cmd>SimpleMinimapTogglePin<CR>
# One target per command, so `g:simpleminimap_set_default_mapping = 0` does not
# force users back to hand-written <Cmd>SimpleMinimap...<CR> literals that
# cannot be redefined or deprecated from here.
nnoremap <silent> <Plug>(simpleminimap-open) <Cmd>SimpleMinimapOpen<CR>
nnoremap <silent> <Plug>(simpleminimap-close) <Cmd>SimpleMinimapClose<CR>
nnoremap <silent> <Plug>(simpleminimap-unpin) <Cmd>SimpleMinimapUnpin<CR>
nnoremap <silent> <Plug>(simpleminimap-refresh) <Cmd>SimpleMinimapRefresh<CR>
nnoremap <silent> <Plug>(simpleminimap-refresh-all) <Cmd>SimpleMinimapRefresh!<CR>
nnoremap <silent> <Plug>(simpleminimap-style) <Cmd>SimpleMinimapStyle<CR>
nnoremap <silent> <Plug>(simpleminimap-restart) <Cmd>SimpleMinimapRestart<CR>
nnoremap <silent> <Plug>(simpleminimap-health) <Cmd>SimpleMinimapHealth<CR>
nnoremap <silent> <Plug>(simpleminimap-log) <Cmd>SimpleMinimapLog<CR>
if g:simpleminimap_set_default_mapping && maparg('<leader>m', 'n') ==# ''
  nmap <silent> <leader>m <Plug>(simpleminimap-toggle)
endif

simpleminimap#SetupHighlights()

augroup SimpleMinimap
  autocmd!
  autocmd BufEnter,WinEnter * try | call simpleminimap#OnContextChanged() | catch | endtry
  # Runs after every other plugin's WinEnter handler has had its turn, so a
  # statusline manager that rewrites &l:statusline cannot blank the minimap.
  autocmd BufWinEnter,WinEnter * try | call simpleminimap#ReassertWindow(win_getid()) | catch | endtry
  autocmd TextChanged,TextChangedI,BufWritePost * try | call simpleminimap#OnTextChanged(str2nr(expand('<abuf>'))) | catch | endtry
  autocmd CursorMoved,CursorMovedI * try | call simpleminimap#OnCursorMoved(win_getid()) | catch | endtry
  autocmd TabEnter * try | call simpleminimap#OnContextChanged() | catch | endtry
  autocmd TabEnter * try | call simpleminimap#MaybeAutoOpen() | catch | endtry
  autocmd VimEnter * try | call simpleminimap#MaybeAutoOpen() | catch | endtry
  autocmd CursorHold,CursorHoldI * try | call simpleminimap#OnSignsChanged(str2nr(expand('<abuf>'))) | catch | endtry
  # :grep / :make / :lvimgrep replace a whole overlay source at once; waiting
  # for the next CursorHold would leave the previous result set on screen for
  # up to 'updatetime'.
  autocmd QuickFixCmdPost * try | call simpleminimap#OnOverlaysChanged() | catch | endtry
  autocmd WinClosed * try | call simpleminimap#OnWinClosed(str2nr(expand('<amatch>'))) | catch | endtry
  autocmd BufWipeout * try | call simpleminimap#OnBufferWipeout(str2nr(expand('<abuf>'))) | catch | endtry
  autocmd ColorScheme * try | call simpleminimap#OnColorScheme() | catch | endtry
  autocmd VimLeavePre * try | call simpleminimap#Stop() | catch | endtry
  if exists('##WinScrolled')
    autocmd WinScrolled * try | call simpleminimap#OnWinScrolled(str2nr(expand('<amatch>'))) | catch | endtry
  endif
  if exists('##WinResized')
    autocmd WinResized * try | call simpleminimap#OnResized() | catch | endtry
  endif
  if exists('##TabNewEntered')
    autocmd TabNewEntered * try | call simpleminimap#MaybeAutoOpen() | catch | endtry
  endif
  if exists('##OptionSet')
    autocmd OptionSet tabstop try | call simpleminimap#OnTextChanged(bufnr()) | catch | endtry
    autocmd OptionSet filetype,buftype try | call simpleminimap#OnContextChanged() | catch | endtry
  endif
augroup END
