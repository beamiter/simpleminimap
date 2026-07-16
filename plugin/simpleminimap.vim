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

g:simpleminimap_width = ClampNumber(get(g:, 'simpleminimap_width', 18), 18, 6, 80)
g:simpleminimap_max_columns = ClampNumber(get(g:, 'simpleminimap_max_columns', 120), 120, 20, 1000)
g:simpleminimap_debounce = ClampNumber(get(g:, 'simpleminimap_debounce', 80), 80, 0, 2000)
g:simpleminimap_render_style = get(g:, 'simpleminimap_render_style', 'braille')
g:simpleminimap_daemon_path = get(g:, 'simpleminimap_daemon_path', '')
g:simpleminimap_set_default_mapping = get(g:, 'simpleminimap_set_default_mapping', 1)
g:simpleminimap_debug = get(g:, 'simpleminimap_debug', 0)
g:simpleminimap_show_statusline = get(g:, 'simpleminimap_show_statusline', 1)
g:simpleminimap_auto_close = get(g:, 'simpleminimap_auto_close', 0)

command! SimpleMinimap simpleminimap#Toggle()
command! SimpleMinimapOpen simpleminimap#Open()
command! SimpleMinimapClose simpleminimap#Close()
command! SimpleMinimapRefresh simpleminimap#Refresh()
command! SimpleMinimapHealth simpleminimap#Health()
command! SimpleMinimapDebug echo simpleminimap#DebugStatus()

nnoremap <silent> <Plug>(simpleminimap-toggle) <Cmd>SimpleMinimap<CR>
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
  if exists('##OptionSet')
    autocmd OptionSet tabstop try | call simpleminimap#OnTextChanged(bufnr()) | catch | endtry
  endif
augroup END
