" How many minimap rows a short file gets, and what the rows below it do.
"
" The historical scale was a fixed four source lines per row, so any file
" shorter than four times the minimap height rendered into the top fraction of
" the window: a 40-line file in a 50-row minimap drew 10 rows and 40 dead ones,
" the viewport highlight covered the whole drawn block wherever the cursor was,
" and clicking in the blank region did nothing at all.  Most files are shorter
" than that, so it was the default experience on a tall terminal.
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

" Shorter than the window is tall, which is where the two modes differ.
let s:lines = 12
call setline(1, map(range(1, s:lines), 'printf("line %02d", v:val)'))
let s:source_winid = win_getid()
SimpleMinimapOpen

function! s:Session() abort
  let state = simpleminimap#DebugStatus()
  return len(state.sessions) == 1 ? values(state.sessions)[0] : {}
endfunction

function! s:WaitForRows(count) abort
  let attempt = 0
  while len(get(s:Session(), 'rows', [])) != a:count && attempt < 200
    sleep 20m
    let attempt += 1
  endwhile
  return len(get(s:Session(), 'rows', []))
endfunction

let s:height = winheight(win_id2win(s:Session().winid))
call assert_true(s:height > s:lines,
      \ 'the minimap window is taller than the file, or this test proves nothing')

" ---------------------------------------------------------------------------
" proportional (the default): one row per line until the rows run out.
" ---------------------------------------------------------------------------
call assert_equal('proportional', g:simpleminimap_fill)
call assert_equal(s:lines, s:WaitForRows(s:lines),
      \ 'a short file gets one minimap row per line')
let s:rows = s:Session().rows
call assert_equal(1, s:rows[0].start)
call assert_equal(1, s:rows[0].end)
call assert_equal(s:lines, s:rows[-1].start)
call assert_equal(s:lines, s:rows[-1].end)

" A jump aimed below the drawn rows used to resolve to nothing at all, because
" SourceTargetForRow() refused any row past the last one; the blank tail of the
" minimap was simply inert.  It now resolves to the last real row.
SimpleMinimapFocus
call cursor(s:height, 1)
call simpleminimap#Jump()
call assert_equal(s:source_winid, win_getid())
call assert_equal(s:lines, line('.'),
      \ 'a jump from the blank tail lands on the last rendered row')

" ---------------------------------------------------------------------------
" compact: the historical fixed four-lines-per-row scale, kept for anyone who
" prefers a stable scale over spending the window.
" ---------------------------------------------------------------------------
let g:simpleminimap_fill = 'compact'
SimpleMinimapRefresh
call assert_equal((s:lines + 3) / 4, s:WaitForRows((s:lines + 3) / 4),
      \ 'compact keeps four source lines per row')
let s:rows = s:Session().rows
call assert_equal(1, s:rows[0].start)
call assert_equal(4, s:rows[0].end)

" ---------------------------------------------------------------------------
" A file taller than the window is banded either way -- there are only so many
" rows -- so the option cannot make a long file more expensive.
" ---------------------------------------------------------------------------
let g:simpleminimap_fill = 'proportional'
call win_gotoid(s:source_winid)
call setline(1, map(range(1, 2000), 'printf("line %04d", v:val)'))
call simpleminimap#OnTextChanged(bufnr())
call assert_equal(s:height, s:WaitForRows(s:height),
      \ 'a long file fills the window and no more')
call assert_equal(2000, s:Session().rows[-1].end)

" An unrecognised value falls back to the default rather than rendering nothing.
let g:simpleminimap_fill = 'nonsense'
SimpleMinimapRefresh!
call assert_equal(s:height, s:WaitForRows(s:height))
let g:simpleminimap_fill = 'proportional'

SimpleMinimapClose
call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
