vim9script

# Startup handshake deadline, bounded restarts, and stale-timer ownership.
set nocompatible
set nomore
set hidden

var root = fnamemodify(expand('<sfile>:p:h'), ':h')
delete(root .. '/tests/vim-errors.log')
execute 'set runtimepath^=' .. fnameescape(root)

var spawn_log = tempname()
$SIMPLEMINIMAP_TEST_SPAWN_LOG = spawn_log
$SIMPLEMINIMAP_TEST_NO_READY = '1'
$SIMPLEMINIMAP_TEST_IGNORE_TERM = '1'
g:simpleminimap_daemon_path = root .. '/tests/mock_daemon.py'
g:simpleminimap_debounce = 0
g:simpleminimap_width = 12
g:simpleminimap_set_default_mapping = 0
g:simpleminimap_auto_restart = 0
execute 'source ' .. fnameescape(root .. '/plugin/simpleminimap.vim')

def WaitFor(Condition: func(): bool, label: string, timeout_ms: number): bool
  for _ in range(timeout_ms / 20)
    if Condition()
      return true
    endif
    sleep 20m
  endfor
  assert_true(false, 'timeout: ' .. label)
  return false
enddef

def Spawns(): number
  return filereadable(spawn_log) ? len(readfile(spawn_log)) : 0
enddef

setline(1, ['one', 'two', 'three'])
SimpleMinimapOpen
assert_true(WaitFor(
  () => simpleminimap#DebugStatus().backend_handshake_timeouts == 1
    && !simpleminimap#DebugStatus().backend_running,
  'a live process which never sends READY is stopped', 5000))
var state = simpleminimap#DebugStatus()
assert_false(state.backend_ready)
assert_false(state.backend_handshake_pending)
assert_equal(1, Spawns(), 'auto-restart disabled means one process only')
assert_match('did not announce READY within 3000ms', state.backend_error)

var health = ''
redir => health
silent SimpleMinimapHealth
redir END
assert_match('\[WARN\] READY handshake: idle; 1 timeout', health)

# A manual restart replaces the failed generation.  Waiting past the old
# generation's deadline must not let a stale callback kill this healthy job.
$SIMPLEMINIMAP_TEST_NO_READY = ''
$SIMPLEMINIMAP_TEST_IGNORE_TERM = ''
SimpleMinimapRestart
assert_true(WaitFor(() => !!simpleminimap#DebugStatus().backend_ready,
  'replacement backend becomes ready', 4000))
assert_false(simpleminimap#DebugStatus().backend_handshake_pending,
  'READY retires its startup deadline')
sleep 3200m
state = simpleminimap#DebugStatus()
assert_true(state.backend_running)
assert_true(state.backend_ready)
assert_false(state.backend_handshake_pending,
  'an expired/queued startup callback does not survive as pending')
assert_equal(state.protocol_version, state.backend_protocol)
assert_equal(1, state.backend_handshake_timeouts)

# The same startup failure with automatic restart enabled spends the shared
# three-restart budget and then holds the breaker.  It must not fork forever.
$SIMPLEMINIMAP_TEST_NO_READY = '1'
$SIMPLEMINIMAP_TEST_IGNORE_TERM = '1'
g:simpleminimap_auto_restart = 1
var before = Spawns()
SimpleMinimapRestart
assert_true(WaitFor(() => !!simpleminimap#DebugStatus().backend_breaker_tripped,
  'repeated handshake failures trip the breaker', 16000))
state = simpleminimap#DebugStatus()
assert_equal(3, state.backend_restart_attempts)
assert_equal('handshake timeout', state.backend_breaker_reason)
assert_false(state.backend_running)
assert_true(Spawns() - before <= 4,
  printf('startup failure was respawned %d times', Spawns() - before))

redir => health
silent SimpleMinimapHealth
redir END
assert_match('\[FAIL\] crash-loop breaker: tripped.*handshake timeout', health)

simpleminimap#Stop()
$SIMPLEMINIMAP_TEST_NO_READY = ''
$SIMPLEMINIMAP_TEST_IGNORE_TERM = ''
$SIMPLEMINIMAP_TEST_SPAWN_LOG = ''
delete(spawn_log)
if !empty(v:errors)
  writefile(v:errors, root .. '/tests/vim-errors.log')
  cquit!
endif
delete(root .. '/tests/vim-errors.log')
qall!
