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
SimpleMinimapClose
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
