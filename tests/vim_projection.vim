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
SimpleMinimapClose
call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
