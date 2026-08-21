vim9script

set nocompatible
set nomore
set hidden

var root = fnamemodify(expand('<sfile>:p:h'), ':h')
execute 'set runtimepath^=' .. fnameescape(root)

var fixture_dir = tempname()
mkdir(fixture_dir, 'p')
var old_backend = fixture_dir .. '/old-backend.py'
writefile([
  '#!/usr/bin/env python3',
  'import subprocess, sys',
  'print("READY" + chr(9) + "3", flush=True)',
  'subprocess.Popen([sys.executable, "-c",',
  '  "import time; time.sleep(0.7); print(''READY'' + chr(9) + ''999'', flush=True)"],',
  '  stdout=sys.stdout)',
  'for _line in sys.stdin:',
  '  pass',
], old_backend)
setfperm(old_backend, 'rwxr-xr-x')

var current_backend = root .. '/tests/mock_daemon.py'
if !executable(current_backend)
  setfperm(current_backend, 'rwxr-xr-x')
endif

g:simpleminimap_daemon_path = old_backend
g:simpleminimap_debounce = 0
g:simpleminimap_request_timeout_ms = 0
g:simpleminimap_set_default_mapping = 0
execute 'source ' .. fnameescape(root .. '/plugin/simpleminimap.vim')

def WaitFor(Condition: func(): bool, label: string, timeout_ms: number = 4000): bool
  for _ in range(timeout_ms / 10)
    if Condition()
      return true
    endif
    sleep 10m
  endfor
  assert_true(false, 'timeout: ' .. label)
  return false
enddef

setline(1, ['one', 'two', 'three'])
SimpleMinimapOpen
WaitFor(() => !!simpleminimap#DebugStatus().backend_ready,
  'the original backend becomes ready')

g:simpleminimap_daemon_path = current_backend
SimpleMinimapRestart
WaitFor(() => !!simpleminimap#DebugStatus().backend_ready
    && simpleminimap#DebugStatus().backend_protocol
      == simpleminimap#DebugStatus().protocol_version,
  'the replacement backend becomes ready')

# The child of the original process still owns its stdout and speaks after the
# replacement is live.  Its deliberately incompatible READY must be fenced.
sleep 850m
var state = simpleminimap#DebugStatus()
assert_true(state.backend_ready, 'late output made the replacement unready')
assert_equal(state.protocol_version, state.backend_protocol,
  'late output replaced the current backend protocol')

simpleminimap#Stop()
delete(fixture_dir, 'rf')
if !empty(v:errors)
  writefile(v:errors, root .. '/tests/vim-errors.log')
  cquit!
endif
delete(root .. '/tests/vim-errors.log')
qall!
