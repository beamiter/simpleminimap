" The overlay provider registry and the projections built on it.
"
" Before this existed the minimap could only show what some *other* plugin had
" already turned into a Vim sign, so a :grep result set, the location list,
" marks and a :diffthis session were all invisible.  Each projection here is
" asserted through the same public surface a third-party provider uses.
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

" 200 lines over a small minimap, so a row covers a wide band and the
" line -> row projection is doing real work rather than the identity.
let s:file = s:root .. '/tests/vim-overlay-source.txt'
call writefile(map(range(1, 200), 'printf("line %03d has some content", v:val)'), s:file)
execute 'edit' fnameescape(s:file)
let s:source_winid = win_getid()
let s:source_bufnr = bufnr()
SimpleMinimapOpen

function! s:Session() abort
  let state = simpleminimap#DebugStatus()
  return len(state.sessions) == 1 ? values(state.sessions)[0] : {}
endfunction

let s:attempt = 0
while empty(get(s:Session(), 'rows', [])) && s:attempt < 150
  sleep 20m
  let s:attempt += 1
endwhile
call assert_true(!empty(get(s:Session(), 'rows', [])), 'the minimap rendered')

let s:rows = s:Session().rows
function! s:RowFor(lnum) abort
  let index = 0
  for row in s:rows
    let index += 1
    if a:lnum >= row.start && a:lnum <= row.end
      return index
    endif
  endfor
  return 0
endfunction

" ---------------------------------------------------------------------------
" Defaults are unchanged: signs and search only.
" ---------------------------------------------------------------------------
call assert_equal(['signs', 'search'], g:simpleminimap_overlays)
call assert_true(simpleminimap#OverlayEnabled('signs'))
call assert_true(simpleminimap#OverlayEnabled('search'))
call assert_false(simpleminimap#OverlayEnabled('quickfix'))
for s:name in ['signs', 'quickfix', 'loclist', 'marks', 'diff', 'search']
  call assert_true(index(simpleminimap#OverlayNames(), s:name) >= 0,
        \ s:name .. ' is a known overlay')
endfor

" A quickfix list that names this buffer is invisible while 'quickfix' is not
" in g:simpleminimap_overlays -- that is what makes the option meaningful.
call setqflist([{'bufnr': s:source_bufnr, 'lnum': 20, 'type': 'E', 'text': 'boom'}])
call simpleminimap#OnOverlaysChanged()
call assert_equal([], s:Session().sign_rows,
      \ 'an overlay that is not enabled projects nothing')

" ---------------------------------------------------------------------------
" quickfix
" ---------------------------------------------------------------------------
let g:simpleminimap_overlays = ['signs', 'search', 'quickfix']
call setqflist([
      \ {'bufnr': s:source_bufnr, 'lnum': 20, 'type': 'E', 'text': 'error'},
      \ {'bufnr': s:source_bufnr, 'lnum': 120, 'type': 'W', 'text': 'warning'},
      \ {'bufnr': s:source_bufnr, 'lnum': 160, 'type': 'I', 'text': 'info'},
      \ {'bufnr': s:source_bufnr, 'lnum': 0, 'type': 'E', 'text': 'no line'},
      \ {'filename': '/nowhere/else.txt', 'lnum': 3, 'type': 'E', 'text': 'other file'},
      \ ])
call simpleminimap#OnOverlaysChanged()
let s:session = s:Session()
call assert_equal(sort([s:RowFor(20), s:RowFor(120), s:RowFor(160)], 'n'),
      \ s:session.sign_rows, 'quickfix entries project onto their own rows')
call assert_equal('error', s:session.sign_categories[string(s:RowFor(20))])
call assert_equal('warning', s:session.sign_categories[string(s:RowFor(120))])
call assert_equal('info', s:session.sign_categories[string(s:RowFor(160))])
call assert_true(len(s:session.sign_matches) > 0, 'the rows are actually highlighted')

" An entry in another file, and one with no line number, are not projected.
call assert_equal(3, len(s:session.sign_rows))

" ---------------------------------------------------------------------------
" location list: per window, and distinct from the quickfix list
" ---------------------------------------------------------------------------
call setqflist([])
let g:simpleminimap_overlays = ['loclist']
call setloclist(s:source_winid, [
      \ {'bufnr': s:source_bufnr, 'lnum': 90, 'type': 'W', 'text': 'loc'}])
call simpleminimap#OnOverlaysChanged()
call assert_equal([s:RowFor(90)], s:Session().sign_rows,
      \ 'the location list of the tracked window projects')
call assert_equal('warning', s:Session().sign_categories[string(s:RowFor(90))])
call setloclist(s:source_winid, [])

" ---------------------------------------------------------------------------
" marks: only the ones a user sets on purpose
" ---------------------------------------------------------------------------
let g:simpleminimap_overlays = ['marks']
call win_gotoid(s:source_winid)
execute 'normal! 45Gma'
execute 'normal! 199G'
call simpleminimap#OnOverlaysChanged()
call assert_equal([s:RowFor(45)], s:Session().sign_rows,
      \ "'a projects; the automatic marks moved by that motion do not")
call assert_equal('mark', s:Session().sign_categories[string(s:RowFor(45))])
delmarks a

" ---------------------------------------------------------------------------
" A third-party provider is a function, and severity still resolves per row.
" ---------------------------------------------------------------------------
function! TestOverlay(context) abort
  call add(g:test_overlay_calls, a:context.bufnr)
  return [{'lnum': 45, 'category': 'error'},
        \ {'lnum': 46, 'category': 'not-a-real-category'}]
endfunction

let g:test_overlay_calls = []
call simpleminimap#RegisterOverlay('test', function('TestOverlay'))
let g:simpleminimap_overlays = ['marks', 'test']
call win_gotoid(s:source_winid)
execute 'normal! 45Gma'
call simpleminimap#OnOverlaysChanged()
call assert_equal([s:source_bufnr], g:test_overlay_calls,
      \ 'the provider is handed the source buffer')
call assert_equal('error', s:Session().sign_categories[string(s:RowFor(45))],
      \ 'an error outranks a mark on the same row')
call assert_equal('other', s:Session().sign_categories[string(s:RowFor(46))],
      \ 'an unknown category degrades to other instead of throwing')
delmarks a

" A provider that throws is logged and skipped: it must not be able to break
" the redraw that called it, nor stop the providers after it.
function! BrokenOverlay(context) abort
  throw 'overlay exploded'
endfunction
call simpleminimap#RegisterOverlay('broken', function('BrokenOverlay'))
let g:simpleminimap_overlays = ['broken', 'test']
call simpleminimap#OnOverlaysChanged()
call assert_equal('error', s:Session().sign_categories[string(s:RowFor(45))],
      \ 'a throwing provider does not take the working ones down with it')

" ---------------------------------------------------------------------------
" diff
" ---------------------------------------------------------------------------
if has('diff')
  let g:simpleminimap_overlays = ['diff']
  let s:other = s:root .. '/tests/vim-overlay-other.txt'
  " Same file with one line changed near the end, so the hunk lands on a row
  " far from the first one and cannot be confused with "everything differs".
  let s:lines = map(range(1, 200), 'printf("line %03d has some content", v:val)')
  let s:lines[179] = 'CHANGED'
  call writefile(s:lines, s:other)

  call win_gotoid(s:source_winid)
  diffthis
  execute 'rightbelow split' fnameescape(s:other)
  diffthis
  call win_gotoid(s:source_winid)
  call simpleminimap#OnOverlaysChanged()
  let s:diff_rows = s:Session().sign_rows
  call assert_true(index(s:diff_rows, s:RowFor(180)) >= 0,
        \ 'the changed line lands on its own minimap row')
  call assert_equal('change', s:Session().sign_categories[string(s:RowFor(180))])
  call assert_true(len(s:diff_rows) < len(s:rows),
        \ 'an unchanged file is not painted end to end')

  diffoff!
  call win_gotoid(s:source_winid)
  execute 'bwipeout!' bufnr(s:other)
  call delete(s:other)

  " Out of diff mode the overlay costs nothing and shows nothing.
  call simpleminimap#OnOverlaysChanged()
  call assert_equal([], s:Session().sign_rows,
        \ 'the diff overlay is inert outside diff mode')
endif

let g:simpleminimap_overlays = ['signs', 'search']
SimpleMinimapClose
call simpleminimap#Stop()
call delete(s:file)

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
