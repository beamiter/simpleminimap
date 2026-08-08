" Incremental sampling: a keystroke must re-read the band it landed in, not the
" whole buffer.
"
" Every render used to call BuildSampleGroup() for every minimap row, and each
" of those reads and normalises up to twelve source lines -- 720 getbufline() +
" NormalizeDisplayCells() pairs on a 60-row minimap, paid again on every
" debounce tick for a one-character edit.
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
runtime plugin/simpleminimap.vim

call setline(1, map(range(1, 4000), 'printf("line %04d: let value = compute(%d);", v:val, v:val)'))
let s:source_bufnr = bufnr()
SimpleMinimapOpen

function! s:Session() abort
  let state = simpleminimap#DebugStatus()
  return len(state.sessions) == 1 ? values(state.sessions)[0] : {}
endfunction

function! s:WaitForRenders(count) abort
  let attempt = 0
  while get(s:Session(), 'render_count', 0) < a:count && attempt < 200
    sleep 20m
    let attempt += 1
  endwhile
  return get(s:Session(), 'render_count', 0)
endfunction

call assert_true(s:WaitForRenders(1) >= 1, 'the minimap rendered')
let s:rows = len(s:Session().rows)
call assert_true(s:rows > 4, 'the minimap has enough rows for the test to mean anything')

" The first render can only miss: nothing is cached yet.
let s:stats = simpleminimap#SampleCacheStats()
call assert_equal(1, s:stats.buffers, 'the source buffer is watched')
call assert_true(s:stats.misses >= s:rows, 'the first render sampled every band')

" ---------------------------------------------------------------------------
" One changed line re-samples one band.
" ---------------------------------------------------------------------------
let s:before = simpleminimap#SampleCacheStats()
let s:renders = get(s:Session(), 'render_count', 0)
call setline(2000, 'line 2000: CHANGED CHANGED CHANGED CHANGED CHANGED')
doautocmd TextChanged
call s:WaitForRenders(s:renders + 1)

let s:after = simpleminimap#SampleCacheStats()
let s:misses = s:after.misses - s:before.misses
let s:hits = s:after.hits - s:before.hits
call assert_true(s:misses >= 1, 'the edited band was re-sampled')
call assert_true(s:misses <= 2,
      \ printf('an in-line edit re-sampled %d of %d bands', s:misses, s:rows))
call assert_equal(s:rows, s:misses + s:hits,
      \ 'every band was accounted for exactly once')

" And the edit reached the daemon.  Listener callbacks are queued until a
" redraw or an explicit flush, and the render runs from a timer: an unflushed
" queue leaves the edited band holding pre-edit text, which produces the same
" body signature as the previous render, which makes the render a cache skip.
" So "did render_count advance" is exactly the staleness detector here.
call assert_equal(s:renders + 1, get(s:Session(), 'render_count', 0),
      \ 'the edit produced a render rather than a signature-identical skip')

" ---------------------------------------------------------------------------
" Adding a line moves every band, so the whole cache has to go.
" ---------------------------------------------------------------------------
let s:before = simpleminimap#SampleCacheStats()
let s:renders = get(s:Session(), 'render_count', 0)
call append(10, 'line 0010b: inserted')
doautocmd TextChanged
call s:WaitForRenders(s:renders + 1)

let s:after = simpleminimap#SampleCacheStats()
call assert_equal(0, s:after.hits - s:before.hits,
      \ 'inserting a line invalidates every cached band')

" ---------------------------------------------------------------------------
" :SimpleMinimapRefresh! reaches past the cache -- it is the documented way to
" say "I do not trust what I am looking at".
" ---------------------------------------------------------------------------
let s:before = simpleminimap#SampleCacheStats()
SimpleMinimapRefresh!
sleep 100m
let s:after = simpleminimap#SampleCacheStats()
call assert_equal(0, s:after.hits - s:before.hits,
      \ 'a forced refresh re-samples everything')

" ---------------------------------------------------------------------------
" The escape hatch really switches the caching off.
" ---------------------------------------------------------------------------
let g:simpleminimap_incremental = 0
let s:before = simpleminimap#SampleCacheStats()
let s:renders = get(s:Session(), 'render_count', 0)
call setline(2500, 'line 2500: CHANGED with g:simpleminimap_incremental off')
doautocmd TextChanged
call s:WaitForRenders(s:renders + 1)
let s:after = simpleminimap#SampleCacheStats()
call assert_equal(0, s:after.hits - s:before.hits,
      \ 'g:simpleminimap_incremental = 0 disables the cache entirely')
let g:simpleminimap_incremental = 1

" ---------------------------------------------------------------------------
" Closing the last session that tracks a buffer stops watching it.
" ---------------------------------------------------------------------------
SimpleMinimapClose
call assert_equal(0, simpleminimap#SampleCacheStats().buffers,
      \ 'the buffer listener is released with the session')

call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
