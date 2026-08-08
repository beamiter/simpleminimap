" :SimpleMinimapHealth as a diagnostic rather than a status line.
"
" Runs against a daemon that announces an older protocol, which is the most
" common failure after a plugin update that did not rebuild lib/.  The protocol
" is chosen by an environment variable read at daemon start, so this needs its
" own Vim instance.
set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
call delete(s:root .. '/tests/vim-errors.log')
execute 'set runtimepath^=' .. fnameescape(s:root)
let g:simpleminimap_daemon_path = s:root .. '/tests/mock_daemon.py'
let g:simpleminimap_debounce = 0
let g:simpleminimap_width = 12
let g:simpleminimap_set_default_mapping = 0

" A misspelled option is otherwise ignored in silence for ever.
let g:simpleminimap_widht = 20
let g:simpleminimap_not_a_real_option_at_all = 1
runtime plugin/simpleminimap.vim

" The known-option list must match what the plugin actually normalises, or the
" typo scan starts reporting real options as unknown.
let s:assigned = []
for s:line in readfile(s:root .. '/plugin/simpleminimap.vim')
  let s:name = matchstr(s:line, '^g:\zssimpleminimap_\w\+\ze\s*=')
  if s:name !=# '' && index(s:assigned, s:name) < 0
    call add(s:assigned, s:name)
  endif
endfor
call assert_true(len(s:assigned) > 10, 'the plugin file was parsed')
call assert_equal(sort(s:assigned), sort(copy(simpleminimap#KnownOptions())),
      \ 'KNOWN_OPTIONS matches the options plugin/simpleminimap.vim normalises')

call assert_equal(
      \ ['simpleminimap_not_a_real_option_at_all', 'simpleminimap_widht'],
      \ simpleminimap#UnknownOptions())

redir => s:health
silent SimpleMinimapHealth
redir END
call assert_match('unknown option g:simpleminimap_widht (did you mean g:simpleminimap_width?)',
      \ s:health, 'a near miss is named')
call assert_match('unknown option g:simpleminimap_not_a_real_option_at_all',
      \ s:health)
call assert_notmatch('unknown option g:simpleminimap_side', s:health,
      \ 'real options are not reported as typos')
unlet g:simpleminimap_widht
unlet g:simpleminimap_not_a_real_option_at_all

" Health must not block on the daemon.  It used to shell out synchronously with
" system(), so a daemon hung on a slow filesystem froze Vim inside the very
" command you run to diagnose a hang.
let s:started = reltime()
redir => s:health
silent SimpleMinimapHealth
redir END
call assert_true(reltimefloat(reltime(s:started)) * 1000.0 < 500.0,
      \ 'Health does not wait on the daemon')
call assert_match('daemon protocol: not negotiated yet', s:health,
      \ 'no backend has been started yet')

" A daemon speaking an older protocol is named as out of date, with the fix.
let $SIMPLEMINIMAP_TEST_PROTOCOL = '1'
call setline(1, ['fn main() {', '    let answer = 42;', '}'])
SimpleMinimapOpen

let s:attempt = 0
while simpleminimap#DebugStatus().backend_protocol == 0 && s:attempt < 200
  sleep 20m
  let s:attempt += 1
endwhile
call assert_equal(1, simpleminimap#DebugStatus().backend_protocol)
call assert_false(simpleminimap#DebugStatus().backend_ready)
call assert_match('run ./install.sh', simpleminimap#DebugStatus().backend_error,
      \ 'the error names the fix, not only the symptom')

let s:session = values(simpleminimap#DebugStatus().sessions)[0]
call assert_match('out of date',
      \ join(getbufline(s:session.bufnr, 1, '$'), ' '),
      \ 'the minimap itself says the daemon is stale')

redir => s:health
silent SimpleMinimapHealth
redir END
call assert_match('\[FAIL\] daemon protocol: daemon v1, plugin expects v2', s:health)
call assert_match('install\.sh', s:health)

" The version probe runs as a job and lands in Health without blocking it.
let s:attempt = 0
while simpleminimap#DebugStatus().daemon_version ==# '' && s:attempt < 200
  sleep 20m
  let s:attempt += 1
endwhile
call assert_match('simpleminimap-daemon (mock)',
      \ simpleminimap#DebugStatus().daemon_version,
      \ 'the --version probe lands in Health without blocking it')

let $SIMPLEMINIMAP_TEST_PROTOCOL = ''
SimpleMinimapClose
call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
