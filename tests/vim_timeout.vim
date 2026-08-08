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
" One line per daemon process actually started: the only way to tell "restarted
" within budget" apart from "forked for the life of the session".
let s:spawn_log = s:root .. '/tests/spawn.log'
call delete(s:spawn_log)
let $SIMPLEMINIMAP_TEST_SPAWN_LOG = s:spawn_log
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

function! s:Spawns() abort
  return filereadable(s:spawn_log) ? len(readfile(s:spawn_log)) : 0
endfunction

" Keep editing so a fresh request -- and a fresh deadline -- is always in
" flight, which is what a user typing into a wedged session does.  a:delay has
" to exceed the request timeout: a new render supersedes the pending request
" and its timer, so typing faster than the deadline never expires anything.
function! s:Churn(iterations, delay, stop_when_tripped) abort
  let l:i = 0
  while l:i < a:iterations
    if a:stop_when_tripped && s:State().backend_breaker_tripped
      return
    endif
    call setline(2, '    let answer = ' .. l:i .. ';')
    call simpleminimap#OnTextChanged(bufnr())
    execute 'sleep ' .. a:delay .. 'm'
    let l:i += 1
  endwhile
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

" g:simpleminimap_auto_restart is 0, so nothing is respawned automatically --
" on this path either.  Timeout restarts used to be routed through the
" user-facing Restart(), which ignores that option (it stops the job as an
" explicit restart) and clears the restart budget on the way, so a daemon that
" answered the handshake and then went silent forked a fresh process every
" couple of deadlines for the life of the session.
call s:Churn(8, 220, 0)
call assert_true(s:State().backend_timeouts > 4,
      \ 'the wedge kept expiring requests while we typed')
call assert_equal(1, s:Spawns(),
      \ 'g:simpleminimap_auto_restart = 0 means no respawn on the timeout path either')
call assert_equal(0, s:State().backend_restart_attempts)
call assert_false(s:State().backend_breaker_tripped)

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

" The same wedge with automatic restarts enabled.  The daemon is replaced, but
" out of the same three-restarts-per-60s budget the crash path spends: an
" unbudgeted timeout restart meant the breaker could never trip on a wedged
" daemon, and a daemon that crashed twice and then wedged got its crash budget
" refunded.
let g:simpleminimap_request_timeout_ms = 150
let g:simpleminimap_auto_restart = 1
let s:before = s:Spawns()
SimpleMinimapRestart
call s:Churn(60, 220, 1)
call assert_true(s:State().backend_breaker_tripped,
      \ 'a daemon that never answers is given up on rather than respawned for ever')
call assert_equal('no response', s:State().backend_breaker_reason,
      \ 'the breaker records why it tripped instead of always saying crash loop')
call assert_equal(3, s:State().backend_restart_attempts,
      \ 'timeout restarts spend the same budget as crashes')
call assert_true(s:Spawns() - s:before <= 4,
      \ printf('at most one process per budgeted restart, got %d', s:Spawns() - s:before))
call assert_false(s:State().backend_running,
      \ 'the wedged process is stopped, not replaced, once the budget is spent')

redir => s:health
silent SimpleMinimapHealth
redir END
call assert_match('\[FAIL\] crash-loop breaker: tripped.*no response', s:health,
      \ 'Health names the daemon that stopped answering, not a crash loop')

" Nothing respawns while the breaker holds, on this path either.
let s:before = s:Spawns()
call s:Churn(3, 220, 0)
call assert_equal(s:before, s:Spawns(),
      \ 'a tripped breaker does not keep forking processes')

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
call assert_match('\[FAIL\] crash-loop breaker: tripped.*crash loop', s:health)
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
call delete(s:spawn_log)

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
