set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
let g:simpleminimap_daemon_path = s:root .. '/tests/mock_daemon.py'
let g:simpleminimap_debounce = 0
let g:simpleminimap_width = 10
let g:simpleminimap_set_default_mapping = 0
let g:simpleminimap_auto_close = 0
runtime plugin/simpleminimap.vim

" Closing the source can leave the minimap as Vim's final window.  Closing the
" plugin must restore a usable normal window instead of throwing E444.
call setline(1, ['source one', 'source two'])
let s:source = win_getid()
SimpleMinimapOpen
let s:session = values(simpleminimap#DebugStatus().sessions)[0]
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

" Sessions are scoped per tab while sharing one backend process.
call setline(1, ['tab one'])
SimpleMinimapOpen
call assert_equal(1, len(simpleminimap#DebugStatus().sessions))
tabnew
call setline(1, ['tab two'])
SimpleMinimapOpen
call assert_equal(2, len(simpleminimap#DebugStatus().sessions))
call assert_true(simpleminimap#DebugStatus().backend_running)
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
