" Sign and search projection on a large buffer.
"
" Both projections used to be quadratic-ish: RowForSourceLine() walked every
" row for every sign and every match, and UpdateSearch() asked matchbufline()
" for every match in the whole buffer -- millions of dictionaries on the main
" thread to decide at most len(rows) bits.  These assertions are about the
" *cost*, so they need a fixture no other test file wants to carry.
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

" 50,000 lines, every one of them matching the pattern used below.  Before the
" fix this made matchbufline() return well over a hundred thousand dictionaries
" in one call, inside a CursorMoved autocommand.
call setline(1, map(range(1, 50000), '"let value = " .. v:val .. " everywhere"'))
let s:source_winid = win_getid()
let s:source_bufnr = bufnr()
call cursor(1, 1)
SimpleMinimapOpen

function! s:Session() abort
  return values(simpleminimap#DebugStatus().sessions)[0]
endfunction

let s:attempt = 0
while (len(simpleminimap#DebugStatus().sessions) != 1
      \ || len(s:Session().rows) == 0) && s:attempt < 300
  sleep 20m
  let s:attempt += 1
endwhile
call assert_equal(1, len(simpleminimap#DebugStatus().sessions))
let s:session = s:Session()
call assert_true(len(s:session.rows) > 0, 'the large fixture renders')
call assert_equal(50000, s:session.source_lines)
let s:row_count = len(s:session.rows)

if exists('*matchbufline')
  set hlsearch
  let @/ = '.'
  let v:hlsearch = 1

  let s:started = reltime()
  call simpleminimap#OnCursorMoved(s:source_winid)
  let s:elapsed = reltimefloat(reltime(s:started)) * 1000.0
  let s:session = s:Session()

  " Every row contains a match, and the projection says so.
  call assert_equal(range(1, s:row_count), s:session.search_rows,
        \ 'a pattern matching every character marks every minimap row')
  call assert_false(s:session.search_partial,
        \ 'a dense pattern is projected completely, not partially')
  call assert_true(s:session.search_match > 0)

  " A dense pattern must cost a few hundred lines per row, not the buffer.
  " 2000ms is deliberately loose: the point is to catch the old behaviour,
  " which allocates on the order of a million dictionaries here.
  call assert_true(s:elapsed < 2000.0,
        \ 'projecting a dense pattern over 50,000 lines stays bounded ('
        \ .. float2nr(s:elapsed) .. 'ms)')

  " A pattern that matches nothing must still terminate, and mark nothing.
  let @/ = 'zzz-no-such-text-zzz'
  let v:hlsearch = 1
  let s:started = reltime()
  call simpleminimap#OnCursorMoved(s:source_winid)
  let s:elapsed = reltimefloat(reltime(s:started)) * 1000.0
  let s:session = s:Session()
  call assert_equal([], s:session.search_rows)
  call assert_false(s:session.search_partial,
        \ '50,000 lines is well inside the scan budget')
  call assert_true(s:elapsed < 5000.0,
        \ 'a pattern matching nowhere still terminates ('
        \ .. float2nr(s:elapsed) .. 'ms)')

  " A pattern confined to one region marks only the rows covering it.
  call setline(25000, 'a unique-projection-marker here')
  let @/ = 'unique-projection-marker'
  let v:hlsearch = 1
  call simpleminimap#OnCursorMoved(s:source_winid)
  let s:session = s:Session()
  call assert_equal(1, len(s:session.search_rows),
        \ 'a single match marks a single row')
  let s:marked = s:session.rows[s:session.search_rows[0] - 1]
  call assert_true(s:marked.start <= 25000 && 25000 <= s:marked.end,
        \ 'the marked row is the band containing the match')

  " Use distinct row bands and compare Vim's real / search with the projection.
  call setline(3, 'foo élan')
  call setline(40000, 'Foo Élan')
  function! s:SearchRowsAt(lines) abort
    let result = []
    let rows = s:Session().rows
    for index in range(len(rows))
      for lnum in a:lines
        if rows[index].start <= lnum && lnum <= rows[index].end
          call add(result, index + 1)
          break
        endif
      endfor
    endfor
    return result
  endfunction
  function! s:CheckSearch(lines) abort
    let options = [&ignorecase, &smartcase, &magic]
    let previous = [@/, v:searchforward, v:hlsearch, winsaveview(), getjumplist(), win_getid()]
    call assert_equal(len(a:lines), searchcount({'recompute': 1, 'maxcount': 0}).total,
          \ 'Vim native search for ' .. @/)
    call simpleminimap#OnCursorMoved(s:source_winid)
    call assert_equal(s:SearchRowsAt(a:lines), s:Session().search_rows, 'projection for ' .. @/)
    call assert_equal(previous, [@/, v:searchforward, v:hlsearch, winsaveview(), getjumplist(), win_getid()],
          \ 'search projection does not move the cursor or overwrite search state')
    call assert_equal(options, [&ignorecase, &smartcase, &magic])
  endfunction
  set ignorecase smartcase
  for s:case in [
        \ ['Foo', [40000]], ['foo', [3, 40000]],
        \ ['Foo\c', [3, 40000]], ['foo\C', [3]],
        \ ['foo\Z', [3, 40000]], ['Élan', [40000]],
        \ ['\%#=1Foo', [40000]], ['\%#=2Foo', [40000]],
        \ ]
    execute "normal! /" .. s:case[0] .. "\<CR>"
    call s:CheckSearch(s:case[1])
  endfor
  execute "normal! /Foo\<CR>"
  call s:CheckSearch([40000])
  set nosmartcase
  " Startup (-S) suppresses OptionSet; explicitly exercise the production hook.
  doautocmd OptionSet smartcase
  call assert_equal(s:SearchRowsAt([3, 40000]), s:Session().search_rows, 'smartcase toggle refreshes in place')
  set noignorecase
  doautocmd OptionSet ignorecase
  call assert_equal(s:SearchRowsAt([40000]), s:Session().search_rows, 'ignorecase toggle refreshes in place')
  set ignorecase
  call s:CheckSearch([3, 40000])
  set smartcase
  call s:CheckSearch([40000])
  execute "normal! ?Foo\<CR>"
  call assert_false(v:searchforward)
  call s:CheckSearch([40000])
  set noignorecase nosmartcase

  " Past the scan budget the projection reports itself incomplete rather than
  " silently under-reporting matches, and the statusline says so.
  call append(line('$'), map(range(1, 200000), '"filler " .. v:val'))
  call simpleminimap#Refresh()
  let s:attempt = 0
  while s:Session().source_lines < 250000 && s:attempt < 300
    sleep 20m
    let s:attempt += 1
  endwhile
  call assert_equal(250000, s:Session().source_lines, 'the padded fixture renders')

  let @/ = 'zzz-no-such-text-zzz'
  let v:hlsearch = 1
  call simpleminimap#OnCursorMoved(s:source_winid)
  let s:session = s:Session()
  call assert_true(s:session.search_partial,
        \ 'a buffer past the scan budget is projected partially')
  call assert_equal([], s:session.search_rows)
  let g:statusline_winid = s:session.winid
  call assert_match('\~', simpleminimap#Statusline(),
        \ 'the statusline marks an incomplete projection')
  unlet g:statusline_winid

  set ignorecase smartcase
  let @/ = 'ZZZ-NO-SUCH-TEXT-ZZZ'
  call s:CheckSearch([])
  call assert_true(s:Session().search_partial,
        \ 'native smartcase scanning retains the same line budget')

  " Large native literal searches must yield to another Vim timer, and even
  " a replacement without CursorMoved must retire the old partial projection.
  call setline(12000, 'staleprobe')
  call setline(130000, 'retainedprobe')
  call setline(180000, 'replacementprobe')
  let @/ = 'staleprobe'
  let v:hlsearch = 1
  call simpleminimap#OnCursorMoved(s:source_winid)
  call assert_equal([], s:Session().search_rows, 'do not publish on CursorMoved')
  call assert_true(s:Session().search_partial, 'deferred projection is reported incomplete')
  let s:cursor_state = [v:searchforward, winsaveview(), getjumplist(), win_getid()]
  let s:initial_job = get(s:Session(), 'search_job', {})
  call assert_equal([0, 0, 200000], get(s:initial_job, 'resume', []),
        \ 'CursorMoved left the entire literal scan for later ticks')

  " One production probe yields after at most 8 chunks of 400 lines.
  " These first 3200 lines contain no staleprobe match.
  call assert_equal([[1], v:false], simpleminimap#SearchSmartcaseProbe([[1, 15000]]),
        \ 'preserve the synchronous probe helper shape')
  if !empty(s:initial_job)
    let s:bounded = simpleminimap#SearchSmartcaseProbe([[1, 15000]], [0, 0, 200000], 8)
    call assert_equal([[], v:true, [0, 3201, 196800]], s:bounded)
  endif

  let s:timer_observation = []
  function! s:ReplaceDuringScan(timer) abort
    let job = get(s:Session(), 'search_job', {})
    if get(job, 'resume', [0, 0, 200000])[2] == 200000
      return
    endif
    let s:timer_observation = [job.resume, s:Session().search_rows]
    " Change the native search and source without calling plugin hooks, as
    " a different plugin's timer could. The next search tick must notice.
    let @/ = 'replacementprobe'
    let v:hlsearch = 1
    call setline(160000, 'REPLACEMENTPROBE')
    call timer_stop(a:timer)
  endfunction
  let s:replacement_timer = timer_start(1, function('s:ReplaceDuringScan'), {'repeat': -1})
  let s:attempt = 0
  while (empty(s:timer_observation) || !empty(get(s:Session(), 'search_job', {}))) && s:attempt < 300
    sleep 10m
    let s:attempt += 1
  endwhile
  call timer_stop(s:replacement_timer)
  call assert_false(empty(s:timer_observation), 'another Vim timer ran during a genuinely started scan')
  if !empty(s:timer_observation)
    call assert_equal([], s:timer_observation[1], 'in-flight results never appear')
  endif
  call assert_equal(2, searchcount({'recompute': 1, 'maxcount': 0}).total,
        \ 'native result after direct pattern and buffer replacement')
  call assert_equal(s:SearchRowsAt([160000, 180000]), s:Session().search_rows,
        \ 'only the replacement rows publish after the obsolete generation is canceled')
  call assert_true(s:Session().search_partial, 'the line cap still reports incomplete coverage')
  call assert_equal(s:cursor_state, [v:searchforward, winsaveview(), getjumplist(), win_getid()],
        \ 'timer slices leave the original window, view, jump list and search direction alone')
  call assert_equal({}, get(s:Session(), 'search_job', {}), 'completed job no longer owns a timer')

  let @/ = 'retainedprobe'
  let v:hlsearch = 1
  call simpleminimap#OnCursorMoved(s:source_winid)
  let s:stopped_timer = get(get(s:Session(), 'search_job', {}), 'timer', -1)
  call assert_true(s:stopped_timer > 0, 'next query actually scheduled')
  for s:repeat in range(1, 12)
    call simpleminimap#OnCursorMoved(s:source_winid)
  endfor
  call assert_equal(s:stopped_timer, get(get(s:Session(), 'search_job', {}), 'timer', -2),
        \ 'repeated CursorMoved on the same query leaves its pending slice alone')
  let s:old_cmp = &casemap
  let &casemap = s:old_cmp ==# 'internal' ? 'internal,keepascii' : 'internal'
  doautocmd OptionSet casemap
  call assert_equal([], timer_info(s:stopped_timer), 'case mapping changes retire the old query')
  let s:stopped_timer = get(get(s:Session(), 'search_job', {}), 'timer', -1)
  call assert_true(s:stopped_timer > 0, 'case mapping change scheduled current query')
  let v:hlsearch = 0
  call simpleminimap#OnCursorMoved(s:source_winid)
  sleep 20m
  call assert_equal([], timer_info(s:stopped_timer), 'nohlsearch stopped the outstanding timer')
  call assert_equal([], s:Session().search_rows, 'old timer could not republish after nohlsearch')
  call assert_equal({}, get(s:Session(), 'search_job', {}), 'no pending search after nohlsearch')
  let &casemap = s:old_cmp
  set noignorecase nosmartcase

  let v:hlsearch = 0
  call simpleminimap#OnCursorMoved(s:source_winid)
  call assert_equal([], s:Session().search_rows)
  call assert_false(s:Session().search_partial,
        \ 'the partial marker is cleared with the projection')
  set nohlsearch
endif

" Sign projection: 4,000 signs onto a few dozen rows used to run the linear row
" scan once per sign.
call sign_define('SimpleMinimapProjTest', {'text': '!', 'texthl': 'WarningMsg'})
let s:id = 1
for s:lnum in range(1, 40000, 10)
  call sign_place(s:id, 'SimpleMinimapProjTests', 'SimpleMinimapProjTest',
        \ s:source_bufnr, {'lnum': s:lnum})
  let s:id += 1
endfor
let s:started = reltime()
call simpleminimap#OnSignsChanged(s:source_bufnr)
let s:elapsed = reltimefloat(reltime(s:started)) * 1000.0
let s:session = s:Session()
call assert_true(len(s:session.sign_rows) > 0, 'signs reach the minimap')
call assert_true(s:elapsed < 2000.0,
      \ 'projecting 4,000 signs stays bounded (' .. float2nr(s:elapsed) .. 'ms)')

" The projection is exact: every row whose band overlaps a signed line, and no
" others.
let s:expected = []
for s:row_index in range(len(s:session.rows))
  let s:row = s:session.rows[s:row_index]
  for s:lnum in range(1, 40000, 10)
    if s:row.start <= s:lnum && s:lnum <= s:row.end
      call add(s:expected, s:row_index + 1)
      break
    endif
  endfor
endfor
call assert_equal(s:expected, s:session.sign_rows,
      \ 'row lookup by arithmetic agrees with an exhaustive scan')

call sign_unplace('SimpleMinimapProjTests', {'buffer': s:source_bufnr})
call sign_undefine('SimpleMinimapProjTest')
if exists('*matchbufline') && !empty(s:initial_job)
  set ignorecase smartcase hlsearch
  let @/ = 'retainedprobe'
  let v:hlsearch = 1
  call simpleminimap#OnCursorMoved(s:source_winid)
  let s:source_view = win_execute(s:source_winid, 'echo string(winsaveview())')
  tabnew
  call setline(1, ['other tab', 'unrelated'])
  call cursor(2, 3)
  let s:front_state = [tabpagenr(), win_getid(), winsaveview(), getjumplist(), @/]
  let s:attempt = 0
  while !empty(get(s:Session(), 'search_job', {})) && s:attempt < 300
    sleep 10m
    let s:attempt += 1
  endwhile
  call assert_equal(s:SearchRowsAt([130000]), s:Session().search_rows,
        \ 'native search finished against the background source, not the foreground tab')
  call assert_equal(s:front_state, [tabpagenr(), win_getid(), winsaveview(), getjumplist(), @/],
        \ 'background projection never steals the foreground tab, window or view')
  call assert_equal(s:source_view, win_execute(s:source_winid, 'echo string(winsaveview())'),
        \ 'each slice restores the actual background source view')
  setlocal nomodified
  tabclose

  let @/ = 'replacementprobe'
  let v:hlsearch = 1
  call simpleminimap#OnCursorMoved(s:source_winid)
  let s:closing_timer = get(get(s:Session(), 'search_job', {}), 'timer', -1)
  call assert_true(s:closing_timer > 0, 'closing a minimap with a queued slice')
  SimpleMinimapClose
  sleep 20m
  call assert_equal([], timer_info(s:closing_timer), 'closing the minimap stops its search timer')
  call assert_equal({}, simpleminimap#DebugStatus().sessions, 'no stale work recreated the session')
else
  SimpleMinimapClose
endif
call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
