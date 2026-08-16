" A SimpleRemote virtual workspace, simulated without SimpleRemote.
"
" In SimpleRemote's virtual mode a remote file is a buffer named
" remote:///abs/path.  Its BufReadCmd sends the read request and returns with
" the buffer still empty and 'buftype' still ''; the reply arrives later on a
" channel callback, which fills the buffer with setbufline(), sets 'buftype'
" to acwrite, detects the filetype and fires
"   User SimpleRemoteBufferRead   g:simpleremote_event = {bufnr, path, ...}
" Two things used to go wrong for the minimap.  The 'buftype' flip made the
" buffer ineligible ("no editable window"), and setbufline() from a callback
" fires no TextChanged, so even an eligible buffer kept its empty-buffer
" render until the next keypress.  Both are simulated here with the same
" sequence of calls SimpleRemote makes, from a timer callback, with the plugin
" itself absent -- exactly how the plugin's own tests must run.
"
" Unlike its siblings this file is fed to Vim on stdin (see the Makefile),
" not with -S: the third scenario depends on OptionSet, and Vim never fires
" OptionSet during startup, which is when a -S script runs.
set nocompatible
set nomore
set shortmess+=I
" Buffers stay loaded when they leave a window, as in any real session; an
" unloaded remote:// buffer would go through the BufReadCmd again on :buffer.
set hidden

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
call delete(s:root .. '/tests/vim-errors.log')
execute 'set runtimepath^=' .. fnameescape(s:root)
let g:simpleminimap_daemon_path = s:root .. '/tests/mock_daemon.py'
let g:simpleminimap_debounce = 0
let g:simpleminimap_width = 12
let g:simpleminimap_set_default_mapping = 0
runtime plugin/simpleminimap.vim

call assert_equal(1, v:vim_did_enter,
      \ 'this file must run after startup (printf "source ..." | vim -es), '
      \ .. 'or the OptionSet scenario below cannot fire')
call assert_true(exists('#SimpleMinimap#User#SimpleRemoteBufferRead'),
      \ 'the SimpleRemoteBufferRead listener is registered unconditionally')
call assert_false(exists('*g:SimpleRemoteReadFile'),
      \ 'simpleremote itself is not on the runtimepath')

" ---------------------------------------------------------------------------
" The stub of SimpleRemote's virtual mode.
" ---------------------------------------------------------------------------
let g:simpleremote_workspace = {'id': 'ssh:devbox:/srv/app', 'kind': 'ssh',
      \ 'target': 'devbox', 'root': '/srv/app', 'tree_root': '/srv/app',
      \ 'local_root': '', 'mode': 'virtual', 'runtime': 'agent',
      \ 'runtime_version': '0', 'protocol': 1, 'probe': {},
      \ 'uri': 'remote:///srv/app'}
let g:simpleremote_status = 'ssh:devbox'
let s:remote_files = {
      \ '/srv/app/main.py': ['import os', '', 'def main():',
      \                       '    return os.getcwd()', '', 'main()'],
      \ '/srv/app/one.py': ['print("one line")'],
      \ '/srv/app/two.py': ['print("second line")'],
      \ '/srv/app/util.py': ['def a():', '    pass', '', 'def b():', '    pass',
      \                       '', 'def c():', '    pass'],
      \ }
let s:pending = {}
let s:reads = []

" ReadRemote(): the BufReadCmd half.  Nothing is loaded yet.
function! s:ReadRemote(uri) abort
  let s:pending[bufnr()] = substitute(a:uri, '^remote://', '', '')
endfunction
augroup SimpleRemoteStub
  autocmd!
  autocmd BufReadCmd remote://* call s:ReadRemote(expand('<amatch>'))
augroup END

" ApplyRemoteRead(): the callback half, in the order SimpleRemote does it.
" `announce` is the User event; the second scenario below leaves it out to
" stand in for any BufReadCmd plugin that never heard of this one.
function! s:ApplyRemoteRead(bufnr, announce, _timer) abort
  let path = remove(s:pending, a:bufnr)
  let lines = s:remote_files[path]
  let old_count = len(getbufline(a:bufnr, 1, '$'))
  call setbufline(a:bufnr, 1, lines)
  if old_count > len(lines)
    call deletebufline(a:bufnr, len(lines) + 1, old_count)
  endif
  call setbufvar(a:bufnr, '&buftype', 'acwrite')
  call setbufvar(a:bufnr, '&swapfile', 0)
  call setbufvar(a:bufnr, 'vimrc_remote',
        \ {'path': path, 'uri': 'remote://' .. path, 'generation': 1})
  call setbufvar(a:bufnr, '&modified', 0)
  call setbufvar(a:bufnr, '&filetype', 'python')
  if a:announce
    let g:simpleremote_event = {'event': 'SimpleRemoteBufferRead',
          \ 'type': 'buffer-read', 'bufnr': a:bufnr, 'path': path,
          \ 'workspace': copy(g:simpleremote_workspace),
          \ 'status': g:simpleremote_status, 'time': localtime()}
    silent! doautocmd <nomodeline> User SimpleRemoteBufferRead
  endif
  call add(s:reads, path)
endfunction

function! s:Session() abort
  let state = simpleminimap#DebugStatus()
  return len(state.sessions) == 1 ? values(state.sessions)[0] : {}
endfunction

function! s:MinimapText() abort
  let session = s:Session()
  return empty(session) ? [] : getbufline(session.bufnr, 1, '$')
endfunction

" Waits until the session's last applied render was built from `count` source
" lines.  Only :sleep runs here -- no keys are fed -- so anything the minimap
" does in the meantime it did on its own.
function! s:WaitForSourceLines(count) abort
  let attempt = 0
  while get(s:Session(), 'source_lines', -1) != a:count && attempt < 200
    sleep 20m
    let attempt += 1
  endwhile
  return get(s:Session(), 'source_lines', -1)
endfunction

" Waits until the session has applied at least `minimum` renders.
function! s:WaitForRenders(minimum) abort
  let attempt = 0
  while get(s:Session(), 'render_count', 0) < a:minimum && attempt < 200
    sleep 20m
    let attempt += 1
  endwhile
  return get(s:Session(), 'render_count', 0)
endfunction

function! s:WaitForReads(count) abort
  let attempt = 0
  while len(s:reads) < a:count && attempt < 200
    sleep 20m
    let attempt += 1
  endwhile
  return len(s:reads)
endfunction

" ---------------------------------------------------------------------------
" 1. The full virtual-mode sequence: :edit remote://..., then the read lands.
" ---------------------------------------------------------------------------
call setline(1, ['local one', 'local two', 'local three'])
let s:source_winid = win_getid()
SimpleMinimapOpen
call assert_equal(3, s:WaitForSourceLines(3), 'the local buffer rendered first')

edit remote:///srv/app/main.py
let s:main_bufnr = bufnr()
call assert_equal('remote:///srv/app/main.py', bufname())
call assert_equal('', &buftype, 'the BufReadCmd left buftype alone, like SimpleRemote')
call assert_equal([''], getline(1, '$'), 'nothing is loaded before the reply')
call assert_equal(s:main_bufnr, s:Session().source_bufnr,
      \ 'the minimap follows the buffer into the window while it is still empty')
call assert_equal(1, s:WaitForSourceLines(1), 'the empty buffer rendered')

let s:renders_before = get(s:Session(), 'render_count', 0)
" With auto-close on, an ineligible source with no replacement would close
" the session outright rather than show a message -- the sharper failure.
let g:simpleminimap_auto_close = 1
call timer_start(0, function('s:ApplyRemoteRead', [s:main_bufnr, 1]))
call assert_equal(1, s:WaitForReads(1), 'the simulated read landed')
call assert_equal('acwrite', getbufvar(s:main_bufnr, '&buftype'))
call assert_equal(6, len(getbufline(s:main_bufnr, 1, '$')))

" No key was pressed between the read and here.
call assert_equal(6, s:WaitForSourceLines(6),
      \ 'the minimap re-rendered the filled remote buffer without a keypress')
let s:session = s:Session()
call assert_equal(s:main_bufnr, s:session.source_bufnr,
      \ 'the acwrite buffer stayed the source')
call assert_equal(s:source_winid, s:session.source_winid)
call assert_true(s:session.render_count > s:renders_before)
call assert_equal(6, len(s:session.rows))
call assert_equal(1, s:session.rows[0].start)
call assert_equal(6, s:session.rows[-1].end)
call assert_notmatch('^SimpleMinimap', s:MinimapText()[0],
      \ 'no "no editable window" message for an acwrite buffer')
call assert_equal(1, len(simpleminimap#DebugStatus().sessions),
      \ 'auto-close did not close the session over the buftype flip')
let g:simpleminimap_auto_close = 0

" ---------------------------------------------------------------------------
" 2. Same length, different text.
"
" A one-line remote file replaces the one-line empty buffer, so a safeguard
" that compares line counts alone has nothing to notice.  Two independent
" signals do notice it: the User event SimpleRemote fires, and the buffer's
" b:changedtick, which every setbufline() from a callback bumps.  The real
" sequence has both; 2a and 2b below each take one of them away, so neither
" can pass on the other one's wiring.
" ---------------------------------------------------------------------------
edit remote:///srv/app/one.py
let s:one_bufnr = bufnr()
call assert_equal(1, s:WaitForSourceLines(1), 'the empty one.py buffer rendered')
let s:renders_before = s:Session().render_count
let s:request_before = s:Session().request_id
call timer_start(0, function('s:ApplyRemoteRead', [s:one_bufnr, 1]))
call assert_equal(2, s:WaitForReads(2))
let s:attempt = 0
while s:Session().render_count <= s:renders_before && s:attempt < 200
  sleep 20m
  let s:attempt += 1
endwhile
let s:session = s:Session()
call assert_true(s:session.render_count > s:renders_before,
      \ 'SimpleRemoteBufferRead re-rendered a same-length fill')
call assert_true(s:session.request_id > s:request_before,
      \ 'the re-render went to the daemon (the text changed, so did the signature)')
call assert_equal(s:one_bufnr, s:session.source_bufnr)
call assert_equal(1, s:session.source_lines)
call assert_equal(getbufvar(s:one_bufnr, 'changedtick'), s:session.source_tick,
      \ 'the applied render recorded the changedtick it was built from')

" ---------------------------------------------------------------------------
" 2a. The User event on its own.
"
" A callback rewrites the same number of lines and announces the fill.  No
" option changes, no window is entered and no key is pressed, so the
"   autocmd User SimpleRemoteBufferRead ... simpleminimap#OnTextChanged(...)
" in plugin/simpleminimap.vim is the only path that can reach the minimap.
" Delete that autocmd and this block fails.
" ---------------------------------------------------------------------------
enew!
let s:announced_bufnr = bufnr()
call setline(1, ['one', 'two', 'three'])
call simpleminimap#OnTextChanged(s:announced_bufnr)
call assert_equal(3, s:WaitForSourceLines(3), 'the announced buffer rendered first')
let s:renders_before = s:Session().render_count
let s:tick_before = getbufvar(s:announced_bufnr, 'changedtick')
function! s:RewriteAndAnnounce(bufnr, _timer) abort
  call setbufline(a:bufnr, 1, ['ONE', 'TWO', 'THREE'])
  let g:simpleremote_event = {'event': 'SimpleRemoteBufferRead',
        \ 'type': 'buffer-read', 'bufnr': a:bufnr, 'path': '/srv/app/three.py',
        \ 'workspace': copy(g:simpleremote_workspace),
        \ 'status': g:simpleremote_status, 'time': localtime()}
  silent! doautocmd <nomodeline> User SimpleRemoteBufferRead
  let g:simpleminimap_test_grown = 1
endfunction
let g:simpleminimap_test_grown = 0
call timer_start(0, function('s:RewriteAndAnnounce', [s:announced_bufnr]))
let s:attempt = 0
while !g:simpleminimap_test_grown && s:attempt < 200
  sleep 20m
  let s:attempt += 1
endwhile
call assert_equal(3, len(getbufline(s:announced_bufnr, 1, '$')),
      \ 'the rewrite kept the line count (premise: only the event can tell)')
call assert_true(getbufvar(s:announced_bufnr, 'changedtick') > s:tick_before)
call assert_true(s:WaitForRenders(s:renders_before + 1) > s:renders_before,
      \ 'User SimpleRemoteBufferRead alone re-rendered a same-length rewrite')

" ---------------------------------------------------------------------------
" 2b. b:changedtick on its own.
"
" The same one-line-for-one-line fill, announced by nothing at all -- the
" BufReadCmd plugin that never heard of this one.  The 'buftype' flip lands in
" OnContextChanged(), where the window, the buffer and the line count are all
" unchanged, so the changedtick recorded with the rows on screen is the only
" thing that can say the text moved.  Compare line counts alone and this stays
" on the empty-buffer render until a key is pressed.
" ---------------------------------------------------------------------------
edit remote:///srv/app/two.py
let s:two_bufnr = bufnr()
call assert_equal(1, s:WaitForSourceLines(1), 'the empty two.py buffer rendered')
let s:renders_before = s:Session().render_count
let s:request_before = s:Session().request_id
let s:tick_before = getbufvar(s:two_bufnr, 'changedtick')
let s:reads_before = len(s:reads)
call timer_start(0, function('s:ApplyRemoteRead', [s:two_bufnr, 0]))
call assert_equal(s:reads_before + 1, s:WaitForReads(s:reads_before + 1))
call assert_false(exists('g:simpleremote_event')
      \ && g:simpleremote_event.bufnr == s:two_bufnr,
      \ 'this scenario announced nothing')
call assert_equal(1, len(getbufline(s:two_bufnr, 1, '$')),
      \ 'the fill kept the line count at 1 (premise)')
call assert_true(getbufvar(s:two_bufnr, 'changedtick') > s:tick_before)
call assert_true(s:WaitForRenders(s:renders_before + 1) > s:renders_before,
      \ 'a same-length unannounced fill re-rendered on the buftype flip alone')
let s:session = s:Session()
call assert_true(s:session.request_id > s:request_before,
      \ 'the re-render reached the daemon: the text changed, so did the signature')
call assert_equal(s:two_bufnr, s:session.source_bufnr)
call assert_equal(1, s:session.source_lines)
call assert_equal(getbufvar(s:two_bufnr, 'changedtick'), s:session.source_tick)

" And the catch-up settles: nothing more happens on a further WinEnter.
let s:renders_before = s:Session().render_count
let s:request_before = s:Session().request_id
doautocmd <nomodeline> WinEnter
sleep 50m
call assert_equal(s:renders_before, s:Session().render_count,
      \ 'the caught-up buffer is not re-rendered again')
call assert_equal(s:request_before, s:Session().request_id)

" ---------------------------------------------------------------------------
" 3. No User event at all: the generic safeguard.
"
" Any BufReadCmd plugin that fills a buffer from a callback leaves the minimap
" one render behind.  The 'buftype' flip -- or any BufEnter/WinEnter -- lands
" in OnContextChanged(), which now compares the buffer's line count with the
" one its rows were rendered from and re-renders on a mismatch.
" ---------------------------------------------------------------------------
edit remote:///srv/app/util.py
let s:util_bufnr = bufnr()
call assert_equal(1, s:WaitForSourceLines(1), 'the empty util.py buffer rendered')
call timer_start(0, function('s:ApplyRemoteRead', [s:util_bufnr, 0]))
call assert_equal(3, s:WaitForReads(3))
call assert_false(exists('g:simpleremote_event')
      \ && g:simpleremote_event.bufnr == s:util_bufnr,
      \ 'this scenario announced nothing')
call assert_equal(8, s:WaitForSourceLines(8),
      \ 'the buftype flip alone re-rendered the filled buffer (no User event, no key)')
call assert_equal(s:util_bufnr, s:Session().source_bufnr)
call assert_equal(8, len(s:Session().rows))

" The same safeguard from a plain WinEnter, with no option change: a callback
" grows a local buffer, nothing fires, and re-entering the window catches up.
enew!
let s:plain_bufnr = bufnr()
call setline(1, ['plain one', 'plain two'])
call simpleminimap#OnTextChanged(s:plain_bufnr)
call assert_equal(2, s:WaitForSourceLines(2), 'the plain buffer rendered')
function! s:GrowFromCallback(bufnr, _timer) abort
  call setbufline(a:bufnr, 1, map(range(1, 20), 'printf("grown %02d", v:val)'))
  let g:simpleminimap_test_grown = 1
endfunction
let g:simpleminimap_test_grown = 0
call timer_start(0, function('s:GrowFromCallback', [s:plain_bufnr]))
let s:attempt = 0
while !g:simpleminimap_test_grown && s:attempt < 200
  sleep 20m
  let s:attempt += 1
endwhile
call assert_equal(20, len(getbufline(s:plain_bufnr, 1, '$')))
" The premise: nothing here fires TextChanged (a callback never does), so
" the minimap is genuinely behind before the window is re-entered.
sleep 100m
call assert_equal(2, s:Session().source_lines,
      \ 'a callback fill alone leaves the minimap one render behind (premise)')
doautocmd <nomodeline> WinEnter
call assert_equal(20, s:WaitForSourceLines(20),
      \ 'WinEnter on the same window and buffer re-renders a changed line count')

" And once caught up, the same event is not a render: the signature cache and
" the length check both agree there is nothing to do.
let s:renders_before = s:Session().render_count
let s:request_before = s:Session().request_id
doautocmd <nomodeline> WinEnter
sleep 50m
call assert_equal(s:renders_before, s:Session().render_count,
      \ 'an unchanged buffer is not re-rendered on WinEnter')
call assert_equal(s:request_before, s:Session().request_id,
      \ 'nor is a request sent for it')

" A change whose rendered output is identical -- the same 20 lines written
" again from a callback -- costs one signature check and then settles: the
" skip path records the changedtick it has just proved the rows match.  Without
" that record the tick would stay behind for ever and every later WinEnter
" would rebuild the request body again.
function! s:RewriteSameFromCallback(bufnr, _timer) abort
  call setbufline(a:bufnr, 1, map(range(1, 20), 'printf("grown %02d", v:val)'))
  let g:simpleminimap_test_grown = 1
endfunction
let g:simpleminimap_test_grown = 0
let s:tick_before = getbufvar(s:plain_bufnr, 'changedtick')
call timer_start(0, function('s:RewriteSameFromCallback', [s:plain_bufnr]))
let s:attempt = 0
while !g:simpleminimap_test_grown && s:attempt < 200
  sleep 20m
  let s:attempt += 1
endwhile
call assert_true(getbufvar(s:plain_bufnr, 'changedtick') > s:tick_before,
      \ 'rewriting the same text still bumps changedtick (premise)')
let s:skips_before = s:Session().render_skips
let s:request_before = s:Session().request_id
doautocmd <nomodeline> WinEnter
sleep 100m
call assert_equal(s:skips_before + 1, s:Session().render_skips,
      \ 'the identical render was recognised by the signature, not sent')
call assert_equal(s:request_before, s:Session().request_id,
      \ 'so no request went out for it')
let s:skips_before = s:Session().render_skips
doautocmd <nomodeline> WinEnter
sleep 100m
call assert_equal(s:skips_before, s:Session().render_skips,
      \ 'and the skip recorded the tick, so the next WinEnter costs nothing')

" ---------------------------------------------------------------------------
" 4. A pinned split follows the same rule.
" ---------------------------------------------------------------------------
call simpleminimap#Pin()
call assert_true(s:Session().pinned)
let g:simpleminimap_test_grown = 0
function! s:ShrinkFromCallback(bufnr, _timer) abort
  call deletebufline(a:bufnr, 6, 20)
  let g:simpleminimap_test_grown = 1
endfunction
call timer_start(0, function('s:ShrinkFromCallback', [s:plain_bufnr]))
let s:attempt = 0
while !g:simpleminimap_test_grown && s:attempt < 200
  sleep 20m
  let s:attempt += 1
endwhile
call assert_equal(5, len(getbufline(s:plain_bufnr, 1, '$')))
doautocmd <nomodeline> WinEnter
call assert_equal(5, s:WaitForSourceLines(5),
      \ 'a pinned source window re-renders a changed line count on WinEnter')
call assert_true(s:Session().pinned, 'the pin survived')
call simpleminimap#Unpin()

" ---------------------------------------------------------------------------
" 5. SimpleRemote's tree ([SimpleRemote], buftype=nofile) never becomes the
"    source, while the remote:// buffer next to it stays eligible.
" ---------------------------------------------------------------------------
execute 'buffer' s:main_bufnr
call assert_equal(6, s:WaitForSourceLines(6))
vnew
setlocal buftype=nofile bufhidden=wipe noswapfile
setlocal filetype=simpleremotetree
call setline(1, ['/srv/app', '  main.py', '  util.py'])
let s:tree_winid = win_getid()
call simpleminimap#OnContextChanged()
call assert_equal(s:main_bufnr, s:Session().source_bufnr,
      \ 'entering the remote tree does not steal the minimap')
call assert_equal(s:source_winid, s:Session().source_winid)
call assert_notmatch('^SimpleMinimap', s:MinimapText()[0])
close!

" ---------------------------------------------------------------------------
" 6. A tab whose only window is a remote:// buffer can open a minimap, by
"    command and by auto-open; the message that used to refuse is gone.
" ---------------------------------------------------------------------------
SimpleMinimapClose
call assert_equal(0, len(simpleminimap#DebugStatus().sessions))
tabnew
execute 'buffer' s:main_bufnr
call assert_equal('acwrite', &buftype)
SimpleMinimapOpen
call assert_equal(1, len(simpleminimap#DebugStatus().sessions),
      \ ':SimpleMinimapOpen accepts a tab whose only window is a remote:// buffer')
call assert_equal(s:main_bufnr, s:Session().source_bufnr)
call assert_equal(6, s:WaitForSourceLines(6))
SimpleMinimapClose
let g:simpleminimap_auto_open = 1
call simpleminimap#MaybeAutoOpen()
call assert_equal(1, len(simpleminimap#DebugStatus().sessions),
      \ 'auto-open treats a remote:// buffer like a file')
let g:simpleminimap_auto_open = 0
SimpleMinimapClose
tabclose

" ---------------------------------------------------------------------------
" 7. The listener is harmless when the payload is missing or names nothing.
" ---------------------------------------------------------------------------
execute 'buffer' s:main_bufnr
SimpleMinimapOpen
call assert_equal(6, s:WaitForSourceLines(6))
let s:renders_before = s:Session().render_count
unlet! g:simpleremote_event
doautocmd <nomodeline> User SimpleRemoteBufferRead
let g:simpleremote_event = {'event': 'SimpleRemoteBufferRead', 'bufnr': 0}
doautocmd <nomodeline> User SimpleRemoteBufferRead
let g:simpleremote_event = {'event': 'SimpleRemoteBufferRead', 'bufnr': 99999}
doautocmd <nomodeline> User SimpleRemoteBufferRead
sleep 50m
call assert_equal(s:renders_before, s:Session().render_count,
      \ 'an event for no buffer of ours renders nothing')
call assert_equal(1, len(simpleminimap#DebugStatus().sessions))

SimpleMinimapClose
call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
