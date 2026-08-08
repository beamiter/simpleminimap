set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
call delete(s:root .. '/tests/vim-errors.log')
execute 'set runtimepath^=' .. fnameescape(s:root)
let g:simpleminimap_daemon_path = s:root .. '/tests/mock_daemon.py'
let g:simpleminimap_debounce = 0
let g:simpleminimap_width = 10
let g:simpleminimap_set_default_mapping = 0
let g:simpleminimap_auto_close = 0
let g:simpleminimap_side = 'left'
runtime plugin/simpleminimap.vim

" Every command has a <Plug> target, so a user who turns the default mapping
" off never has to hand-write a <Cmd>SimpleMinimap...<CR> literal.
for s:target in ['toggle', 'open', 'close', 'focus', 'pin', 'unpin',
      \ 'toggle-pin', 'refresh', 'refresh-all', 'style', 'restart', 'health',
      \ 'log']
  call assert_notequal('',
        \ maparg('<Plug>(simpleminimap-' .. s:target .. ')', 'n'),
        \ '<Plug>(simpleminimap-' .. s:target .. ') is defined')
endfor
call assert_match('SimpleMinimapRefresh!',
      \ maparg('<Plug>(simpleminimap-refresh-all)', 'n'))
call assert_notmatch('!', maparg('<Plug>(simpleminimap-refresh)', 'n'))
call assert_match('SimpleMinimapUnpin', maparg('<Plug>(simpleminimap-unpin)', 'n'))

" Filetypes can be excluded without special-casing their buftype.
let g:simpleminimap_ignore_filetypes = ['simpleminimap-test-ignore']
set filetype=simpleminimap-test-ignore
SimpleMinimapOpen
call assert_equal(0, len(simpleminimap#DebugStatus().sessions))
set filetype=
let g:simpleminimap_ignore_filetypes = []

" Closing the source can leave the minimap as Vim's final window.  Closing the
" plugin must restore a usable normal window instead of throwing E444.
call setline(1, ['source one', 'source two'])
let s:source = win_getid()
SimpleMinimapOpen
let s:session = values(simpleminimap#DebugStatus().sessions)[0]
call assert_equal(1, win_id2win(s:session.winid))
call win_gotoid(s:source)
close!
sleep 50m
call assert_equal(1, winnr('$'))
call assert_equal('simpleminimap', &filetype)
SimpleMinimapClose
call assert_equal(0, len(simpleminimap#DebugStatus().sessions))
call assert_equal(1, winnr('$'))
call assert_equal('', &filetype)
call assert_equal('', &buftype)
call assert_equal(0, &winfixwidth)
call assert_true(winwidth(0) > g:simpleminimap_width)

" The minimap defends its window-local options.  Any statusline manager that
" rewrites &l:statusline on WinEnter used to blank the title permanently.
call setline(1, ['source one', 'source two'])
let s:defend_source = win_getid()
SimpleMinimapOpen
let s:session = values(simpleminimap#DebugStatus().sessions)[0]
call assert_match('simpleminimap#Statusline()', simpleminimap#StatuslineExpr())
call assert_equal(simpleminimap#StatuslineExpr(),
      \ getwinvar(s:session.winid, '&statusline'))
call win_gotoid(s:session.winid)
call setwinvar(s:session.winid, '&statusline', 'stolen')
call setwinvar(s:session.winid, '&winfixwidth', 0)
call setwinvar(s:session.winid, '&wincolor', '')
doautocmd WinEnter
call assert_equal(simpleminimap#StatuslineExpr(),
      \ getwinvar(s:session.winid, '&statusline'),
      \ 'WinEnter restores the minimap statusline')
call assert_equal(1, getwinvar(s:session.winid, '&winfixwidth'),
      \ 'WinEnter restores winfixwidth')
call assert_equal('SimpleMinimapNormal', getwinvar(s:session.winid, '&wincolor'),
      \ 'WinEnter restores wincolor')
" A colour-scheme reload re-asserts the same state without a window change.
call setwinvar(s:session.winid, '&wincolor', '')
doautocmd ColorScheme
call assert_equal('SimpleMinimapNormal', getwinvar(s:session.winid, '&wincolor'),
      \ 'ColorScheme restores wincolor')
" Entering an ordinary window leaves it alone.
call win_gotoid(s:defend_source)
call setwinvar(s:defend_source, '&statusline', 'user statusline')
doautocmd WinEnter
call assert_equal('user statusline', getwinvar(s:defend_source, '&statusline'),
      \ 'non-minimap windows keep their own statusline')
call setwinvar(s:defend_source, '&statusline', '')
SimpleMinimapClose

" Auto-open is opt-in and uses the same eligibility/session safeguards.
let g:simpleminimap_auto_open = 1
call simpleminimap#MaybeAutoOpen()
call assert_equal(1, len(simpleminimap#DebugStatus().sessions))
SimpleMinimapClose
let g:simpleminimap_auto_open = 0

" Sessions are scoped per tab while sharing one backend process.
call setline(1, ['tab one'])
SimpleMinimapOpen
call assert_equal(1, len(simpleminimap#DebugStatus().sessions))
tabnew
call setline(1, ['tab two'])
SimpleMinimapOpen
call assert_equal(2, len(simpleminimap#DebugStatus().sessions))
call assert_true(simpleminimap#DebugStatus().backend_running)
let s:refresh_all_origin = win_getid()
let s:refresh_ids = {}
for [s:key, s:tab_session] in items(simpleminimap#DebugStatus().sessions)
  let s:refresh_ids[s:key] = s:tab_session.request_id
endfor
SimpleMinimapRefresh!
call assert_equal(s:refresh_all_origin, win_getid(),
      \ 'Refresh! does not visit a background tab or steal focus')
for [s:key, s:tab_session] in items(simpleminimap#DebugStatus().sessions)
  call assert_true(s:tab_session.request_id > s:refresh_ids[s:key],
        \ 'Refresh! forces every live session past the signature cache')
endfor
let s:resize_origin = win_getid()
SimpleMinimapResize 16
call assert_equal(s:resize_origin, win_getid(),
      \ 'resizing background sessions does not steal focus')
for s:tab_session in values(simpleminimap#DebugStatus().sessions)
  call assert_equal(16, getwininfo(s:tab_session.winid)[0].width,
        \ 'runtime width changes reach minimaps in every tab')
endfor
call simpleminimap#AdjustWidth(2)
call assert_equal(s:resize_origin, win_getid(),
      \ '+/- keeps focus while resizing every tab')
for s:tab_session in values(simpleminimap#DebugStatus().sessions)
  call assert_equal(18, getwininfo(s:tab_session.winid)[0].width,
        \ 'minimap +/- width changes retain global multi-tab scope')
endfor
let s:closed_minimap = values(filter(copy(simpleminimap#DebugStatus().sessions),
      \ {_, session -> getwininfo(session.winid)[0].tabnr == tabpagenr()}))[0].winid
SimpleMinimapClose
call assert_equal(1, len(simpleminimap#DebugStatus().sessions))
SimpleMinimapRefresh!
call assert_equal(0, win_id2win(s:closed_minimap),
      \ 'Refresh! neither recreates nor resurrects a closed session')
call assert_equal(1, len(simpleminimap#DebugStatus().sessions))
tabprevious
call assert_equal(1, len(simpleminimap#DebugStatus().sessions))
SimpleMinimapClose
call assert_equal(0, len(simpleminimap#DebugStatus().sessions))
call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
