set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
call delete(s:root .. '/tests/vim-errors.log')
execute 'set runtimepath^=' .. fnameescape(s:root)
let s:crash_marker = '/tmp/simpleminimap-crash-once-' .. getpid()
call delete(s:crash_marker)
let $SIMPLEMINIMAP_TEST_CRASH_ONCE = s:crash_marker
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
      \ 'fn helper() { println!("中文🙂"); }',
      \ ])
let s:source_winid = win_getid()
let s:source_bufnr = bufnr()
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
call assert_equal(simplify(fnamemodify(s:configured_daemon, ':p')), state.backend_path)
call assert_equal(0, state.backend_restart_attempts)
let session = values(state.sessions)[0]
call assert_true(len(session.rows) > 0)
call assert_equal(1, session.rows[0].start)
call assert_equal(3, session.rows[0].end)
call assert_true(session.viewport_match > 0)
call assert_true(session.cursor_match > 0)

" Signs from Git/LSP-style integrations are projected onto minimap rows.
call sign_define('SimpleMinimapTestSign', {'text': '!', 'texthl': 'WarningMsg'})
call sign_place(1, 'SimpleMinimapTests', 'SimpleMinimapTestSign', s:source_bufnr, {'lnum': 5})
call simpleminimap#OnSignsChanged(s:source_bufnr)
let session = values(simpleminimap#DebugStatus().sessions)[0]
call assert_equal([2], session.sign_rows)
call assert_true(session.sign_match > 0)

" A click arriving while the source owns focus still reaches the minimap's
" buffer-local mouse mapping and jumps through the release handler.
if exists('*test_setmouse')
  set mouse=a
  let s:minimap_screen = win_screenpos(win_id2win(session.winid))
  call test_setmouse(s:minimap_screen[0] + 1, s:minimap_screen[1] + 1)
  call feedkeys("\<LeftMouse>", 'xt')
  call assert_equal(session.winid, win_getid())
  call assert_equal(2, line('.'))
  call assert_equal(1, getwininfo(session.winid)[0].topline)
  call test_setmouse(s:minimap_screen[0] + 1, s:minimap_screen[1] + 1)
  call feedkeys("\<LeftDrag>", 'xt')
  call assert_equal(5, getcurpos(s:source_winid)[1])
  call test_setmouse(s:minimap_screen[0] + 1, s:minimap_screen[1] + 1)
  call feedkeys("\<LeftRelease>", 'xt')
  call assert_equal(s:source_winid, win_getid())
  call assert_equal(5, line('.'))
  call feedkeys("\<C-O>", 'xt')
  call assert_equal(1, line('.'))
  call feedkeys("\<C-I>", 'xt')
  call assert_equal(5, line('.'))
endif

" Runtime controls resize and restyle without recreating the session.
SimpleMinimapFocus
call assert_equal(session.winid, win_getid())
SimpleMinimapResize 14
call assert_equal(14, winwidth(0))
SimpleMinimapStyle ascii
call assert_equal('ascii', g:simpleminimap_render_style)
SimpleMinimapStyle
call assert_equal('braille', g:simpleminimap_render_style)
call assert_match('braille', simpleminimap#Statusline())
call assert_equal(['braille', 'blocks', 'ascii'], simpleminimap#CompleteStyle('', '', 0))

" Preview follows a minimap row but intentionally keeps minimap focus.
call cursor(2, 1)
call simpleminimap#Preview()
call assert_equal(session.winid, win_getid())
call assert_equal(5, getcurpos(s:source_winid)[1])
call simpleminimap#ScrollSource(1)
call simpleminimap#MouseDown()
call simpleminimap#MouseDrag()
call simpleminimap#MouseUp()
SimpleMinimapFocus
call cursor(2, 1)
silent SimpleMinimapHealth

" The second minimap row represents source lines 4..6; jumping lands at its midpoint.
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

" An explicit backend restart preserves the session and renders again.
let s:old_request = values(simpleminimap#DebugStatus().sessions)[0].request_id
SimpleMinimapRestart
let s:attempt = 0
while (!simpleminimap#DebugStatus().backend_ready
      \ || values(simpleminimap#DebugStatus().sessions)[0].request_id <= s:old_request) && s:attempt < 150
  sleep 20m
  let s:attempt += 1
endwhile
call assert_true(simpleminimap#DebugStatus().backend_ready)
call assert_true(values(simpleminimap#DebugStatus().sessions)[0].request_id > s:old_request)

SimpleMinimapClose
call assert_equal(0, len(simpleminimap#DebugStatus().sessions))
call sign_unplace('SimpleMinimapTests', {'buffer': s:source_bufnr})
call sign_undefine('SimpleMinimapTestSign')
call simpleminimap#Stop()
call delete(s:crash_marker)

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
