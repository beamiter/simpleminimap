" Request deadlines against a daemon that accepts input and never replies.
"
" This is the failure mode a liveness check cannot see: the process is alive,
" job_status() says "run", the handshake succeeded, and the minimap simply
" never updates again.  Needs its own Vim instance because the wedge is chosen
" by an environment variable read at daemon start.
set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
call delete(s:root .. '/tests/vim-errors.log')
execute 'set runtimepath^=' .. fnameescape(s:root)
let $SIMPLEMINIMAP_TEST_WEDGE = '1'
let g:simpleminimap_daemon_path = s:root .. '/tests/mock_daemon.py'
let g:simpleminimap_debounce = 0
let g:simpleminimap_width = 12
let g:simpleminimap_set_default_mapping = 0
let g:simpleminimap_request_timeout_ms = 150
let g:simpleminimap_auto_restart = 0
runtime plugin/simpleminimap.vim

call assert_equal(150, g:simpleminimap_request_timeout_ms)

call setline(1, ['fn main() {', '    let answer = 42;', '}'])
let s:source_winid = win_getid()
SimpleMinimapOpen

function! s:State() abort
  return simpleminimap#DebugStatus()
endfunction

" The handshake succeeds, so the plugin believes the backend is healthy.
let s:attempt = 0
while !s:State().backend_ready && s:attempt < 200
  sleep 20m
  let s:attempt += 1
endwhile
call assert_true(s:State().backend_ready,
      \ 'a wedged daemon still completes the protocol handshake')
call assert_true(s:State().backend_running)
call assert_equal(1, len(s:State().sessions))
call assert_equal(0, s:State().backend_timeouts)
call assert_equal(1, len(s:State().pending_requests),
      \ 'the render request is in flight and unanswered')

" Without a deadline this request stays pending for the life of the session.
let s:attempt = 0
while s:State().backend_timeouts == 0 && s:attempt < 200
  sleep 20m
  let s:attempt += 1
endwhile
call assert_true(s:State().backend_timeouts > 0,
      \ 'an unanswered request expires instead of hanging for ever')
call assert_equal(0, len(s:State().pending_requests),
      \ 'the expired request is dropped, not leaked into pending_requests')
call assert_match('did not respond', s:State().backend_error)
" The message is rendered into a 12-column window, so only its head survives.
call assert_match('backend did',
      \ join(getbufline(values(s:State().sessions)[0].bufnr, 1, '$'), ' '),
      \ 'the minimap says so instead of showing stale content')

" The session keeps working: a fresh render arms a fresh deadline.
let s:seen = s:State().backend_timeouts
call setline(2, '    let answer = 43;')
call simpleminimap#OnTextChanged(bufnr())
let s:attempt = 0
while s:State().backend_timeouts <= s:seen && s:attempt < 200
  sleep 20m
  let s:attempt += 1
endwhile
call assert_true(s:State().backend_timeouts > s:seen,
      \ 'every request gets its own deadline')

" Health reports the deadline rather than a bare [OK].
redir => s:health
silent SimpleMinimapHealth
redir END
call assert_match('request timeout: 150ms', s:health)
call assert_match('crash-loop breaker', s:health)

" A zero timeout disables the deadline, and Health warns about it.
let g:simpleminimap_request_timeout_ms = 0
let s:seen = s:State().backend_timeouts
call simpleminimap#Refresh()
sleep 400m
call assert_equal(s:seen, s:State().backend_timeouts,
      \ 'a zero timeout disables the deadline')
redir => s:health
silent SimpleMinimapHealth
redir END
call assert_match('request timeout: disabled', s:health)

" A daemon that renders once and then dies, for ever.  The restart budget used
" to be reset by every successful render, which turned the documented
" three-restart cap into a per-success cap: this daemon was respawned every
" ~100ms for the life of the session, since it always made progress first.
let $SIMPLEMINIMAP_TEST_WEDGE = ''
let $SIMPLEMINIMAP_TEST_CRASH_AFTER_RENDER = '1'
let g:simpleminimap_auto_restart = 1
SimpleMinimapRestart
call assert_false(s:State().backend_breaker_tripped,
      \ ':SimpleMinimapRestart re-arms the breaker')

let s:attempt = 0
while !s:State().backend_breaker_tripped && s:attempt < 400
  sleep 20m
  let s:attempt += 1
endwhile
call assert_true(s:State().backend_breaker_tripped,
      \ 'a daemon that keeps dying is given up on rather than respawned for ever')
call assert_equal(3, s:State().backend_restart_attempts,
      \ 'the restart budget is spent, not reset')
call assert_false(s:State().backend_running)

redir => s:health
silent SimpleMinimapHealth
redir END
call assert_match('\[FAIL\] crash-loop breaker: tripped', s:health)
call assert_match('SimpleMinimapRestart', s:health,
      \ 'Health says how to get back')

" Nothing respawns while the breaker holds.
call simpleminimap#Refresh()
sleep 300m
call assert_equal(3, s:State().backend_restart_attempts,
      \ 'a tripped breaker does not keep forking processes')

let $SIMPLEMINIMAP_TEST_CRASH_AFTER_RENDER = ''
SimpleMinimapRestart
call assert_false(s:State().backend_breaker_tripped)
call assert_equal(0, s:State().backend_restart_attempts)

SimpleMinimapClose
call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
