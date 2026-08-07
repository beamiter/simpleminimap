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
g:simpleminimap_mouse_scroll_lines = ClampNumber(get(g:, 'simpleminimap_mouse_scroll_lines', 3), 3, 1, 50)
g:simpleminimap_render_style = Choice(get(g:, 'simpleminimap_render_style', 'braille'), 'braille', ['braille', 'blocks', 'ascii'])
g:simpleminimap_sampling = Choice(get(g:, 'simpleminimap_sampling', 'adaptive'), 'adaptive', ['adaptive', 'uniform'])
g:simpleminimap_side = Choice(get(g:, 'simpleminimap_side', 'right'), 'right', ['left', 'right'])
var configured_daemon_path = get(g:, 'simpleminimap_daemon_path', '')
g:simpleminimap_daemon_path = type(configured_daemon_path) == v:t_string ? configured_daemon_path : ''
g:simpleminimap_set_default_mapping = Flag(get(g:, 'simpleminimap_set_default_mapping', 1), 1)
g:simpleminimap_debug = Flag(get(g:, 'simpleminimap_debug', 0), 0)
g:simpleminimap_show_statusline = Flag(get(g:, 'simpleminimap_show_statusline', 1), 1)
g:simpleminimap_show_signs = Flag(get(g:, 'simpleminimap_show_signs', 1), 1)
g:simpleminimap_show_search = Flag(get(g:, 'simpleminimap_show_search', 1), 1)
g:simpleminimap_shading = Flag(get(g:, 'simpleminimap_shading', 1), 1)
g:simpleminimap_auto_close = Flag(get(g:, 'simpleminimap_auto_close', 0), 0)
g:simpleminimap_auto_open = Flag(get(g:, 'simpleminimap_auto_open', 0), 0)
g:simpleminimap_auto_restart = Flag(get(g:, 'simpleminimap_auto_restart', 1), 1)
var configured_ignored_filetypes = get(g:, 'simpleminimap_ignore_filetypes', [])
g:simpleminimap_ignore_filetypes = type(configured_ignored_filetypes) == v:t_list ? configured_ignored_filetypes : []

command! SimpleMinimap simpleminimap#Toggle()
command! SimpleMinimapOpen simpleminimap#Open()
command! SimpleMinimapClose simpleminimap#Close()
command! SimpleMinimapRefresh simpleminimap#Refresh()
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
if g:simpleminimap_set_default_mapping && maparg('<leader>m', 'n') ==# ''
  nmap <silent> <leader>m <Plug>(simpleminimap-toggle)
endif

simpleminimap#SetupHighlights()

augroup SimpleMinimap
  autocmd!
  autocmd BufEnter,WinEnter * try | call simpleminimap#OnContextChanged() | catch | endtry
  autocmd TextChanged,TextChangedI,BufWritePost * try | call simpleminimap#OnTextChanged(str2nr(expand('<abuf>'))) | catch | endtry
  autocmd CursorMoved,CursorMovedI * try | call simpleminimap#OnCursorMoved(win_getid()) | catch | endtry
  autocmd TabEnter * try | call simpleminimap#OnContextChanged() | catch | endtry
  autocmd TabEnter * try | call simpleminimap#MaybeAutoOpen() | catch | endtry
  autocmd VimEnter * try | call simpleminimap#MaybeAutoOpen() | catch | endtry
  autocmd CursorHold,CursorHoldI * try | call simpleminimap#OnSignsChanged(str2nr(expand('<abuf>'))) | catch | endtry
  autocmd WinClosed * try | call simpleminimap#OnWinClosed(str2nr(expand('<amatch>'))) | catch | endtry
  autocmd BufWipeout * try | call simpleminimap#OnBufferWipeout(str2nr(expand('<abuf>'))) | catch | endtry
  autocmd ColorScheme * try | call simpleminimap#SetupHighlights() | catch | endtry
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
