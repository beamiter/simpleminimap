set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
let s:configured_daemon = exists('$SIMPLEMINIMAP_TEST_DAEMON') && $SIMPLEMINIMAP_TEST_DAEMON !=# ''
      \ ? $SIMPLEMINIMAP_TEST_DAEMON
      \ : s:root .. '/tests/mock_daemon.py'
let g:simpleminimap_daemon_path = s:configured_daemon
let g:simpleminimap_debounce = 0
let g:simpleminimap_width = 12
let g:simpleminimap_set_default_mapping = 0
runtime plugin/simpleminimap.vim

call setline(1, [
      \ 'fn main() {',
      \ '    let answer = 42;',
      \ '    println!("{}", answer);',
      \ '}',
      \ '',
      \ 'fn helper() {}',
      \ ])
let s:source_winid = win_getid()
SimpleMinimapOpen
SimpleMinimapOpen

function! s:Rendered() abort
  let state = simpleminimap#DebugStatus()
  if len(state.sessions) != 1
    return 0
  endif
  let session = values(state.sessions)[0]
  if len(session.rows) == 0
    return 0
  endif
  let lines = getbufline(session.bufnr, 1)
  return !empty(lines)
        \ && lines[0] !~# '^SimpleMinimap'
        \ && strdisplaywidth(lines[0]) == 12
endfunction

let s:attempt = 0
while !s:Rendered() && s:attempt < 150
  sleep 20m
  let s:attempt += 1
endwhile
call assert_true(s:Rendered())

let state = simpleminimap#DebugStatus()
call assert_equal(1, len(state.sessions))
call assert_true(state.backend_running)
let session = values(state.sessions)[0]
call assert_true(len(session.rows) > 0)
call assert_equal(1, session.rows[0].start)
call assert_equal(3, session.rows[0].end)
call assert_true(session.viewport_match > 0)
call assert_true(session.cursor_match > 0)

" The second minimap row represents source lines 4..6; jumping lands at its midpoint.
call win_gotoid(session.winid)
call cursor(2, 1)
call simpleminimap#Jump()
call assert_equal(s:source_winid, win_getid())
call assert_equal(5, line('.'))

" A source edit schedules a fresh request and keeps the minimap usable.
let s:old_request = values(simpleminimap#DebugStatus().sessions)[0].request_id
call setline(2, '    let answer = 43;')
call simpleminimap#OnTextChanged(bufnr())
let s:attempt = 0
while values(simpleminimap#DebugStatus().sessions)[0].request_id <= s:old_request && s:attempt < 100
  sleep 20m
  let s:attempt += 1
endwhile
call assert_true(values(simpleminimap#DebugStatus().sessions)[0].request_id > s:old_request)

SimpleMinimapClose
call assert_equal(0, len(simpleminimap#DebugStatus().sessions))
call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
