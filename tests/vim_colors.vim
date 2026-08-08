" Syntax colouring: the minimap has to say what the ink *is*, not only how
" much of it there is.
"
" Density shading alone cannot separate a comment block from a string table
" from code, which is the usual reason a terminal minimap reads worse than the
" editor beside it.  Each sampled line carries a folded syntax class to the
" daemon, the daemon reports the winning class per rendered cell, and the
" frontend paints that class instead of the density shade.
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
" A fixed four source lines per row keeps the band boundaries predictable, so
" the test can say which class each row must come back with.
let g:simpleminimap_fill = 'compact'
let g:simpleminimap_colors = 1
runtime plugin/simpleminimap.vim

if !has('syntax') || !has('textprop')
  " Nothing to assert without either: the feature is gated on both and Health
  " says so.  Skipping is honest; asserting a fallback would not be.
  qall!
endif

" Twelve lines of each class, in order, so band N's class is a function of N
" alone: rows 1-3 comment, 4-6 string, 7-9 keyword, 10-12 type.
let s:lines = []
for s:i in range(1, 12)
  call add(s:lines, printf('/* comment %02d */', s:i))
endfor
for s:i in range(1, 12)
  call add(s:lines, printf('    "string literal %02d";', s:i))
endfor
for s:i in range(1, 12)
  call add(s:lines, printf('if (value == %02d) { work(); }', s:i))
endfor
for s:i in range(1, 12)
  call add(s:lines, printf('int counter_%02d = 0;', s:i))
endfor
call setline(1, s:lines)
setfiletype c
syntax enable

" ---------------------------------------------------------------------------
" The fold itself: one class per line, taken at the first non-blank column.
" ---------------------------------------------------------------------------
call assert_equal(['c', 's', 'k', 't'],
      \ simpleminimap#SyntaxProbe([1, 13, 25, 37]),
      \ 'comment / string / keyword / type each fold to their own class')
call assert_equal(['n', 'n'], simpleminimap#SyntaxProbe([0, 99999]),
      \ 'a line outside the buffer is unclassified, not an error')

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

function! s:RowClasses() abort
  return map(copy(get(s:Session(), 'rows', [])), 'get(v:val, "classes", "")')
endfunction

function! s:PropTypes() abort
  let session = s:Session()
  if empty(session)
    return []
  endif
  let types = {}
  for lnum in range(1, len(get(session, 'rows', [])))
    for prop in prop_list(lnum, {'bufnr': session.bufnr})
      let types[prop.type] = 1
    endfor
  endfor
  return sort(keys(types))
endfunction

call assert_true(s:WaitForRenders(1) >= 1, 'the minimap rendered')
let s:classes = s:RowClasses()
call assert_true(len(s:classes) >= 12,
      \ printf('the minimap has one row per four lines, got %d', len(s:classes)))

" ---------------------------------------------------------------------------
" The class survives the whole round trip: sampled in Vim, sent on the wire,
" reported per cell by the daemon, stored on the row.
" ---------------------------------------------------------------------------
call assert_match('^c\+$', s:classes[0], 'a band of comments renders as comment')
call assert_match('^s\+$', s:classes[3], 'a band of strings renders as string')
call assert_match('^k\+$', s:classes[6], 'a band of keywords renders as keyword')
call assert_match('^t\+$', s:classes[9], 'a band of types renders as type')

" ...and becomes the colour of those cells rather than their brightness.
let s:types = s:PropTypes()
for s:expected in ['SimpleMinimapSynComment', 'SimpleMinimapSynString',
      \ 'SimpleMinimapSynKeyword', 'SimpleMinimapSynType']
  call assert_true(index(s:types, s:expected) >= 0,
        \ printf('%s is painted, have %s', s:expected, string(s:types)))
endfor
call assert_equal([], filter(copy(s:types), 'v:val =~# "^SimpleMinimapShade"'),
      \ 'every cell here is classified, so none falls back to density shading')

" ---------------------------------------------------------------------------
" An edit re-classifies the band it landed in: the row has to change colour,
" not only shape.
" ---------------------------------------------------------------------------
let s:renders = get(s:Session(), 'render_count', 0)
call setline(25, '/* the keyword band starts with a comment now */')
doautocmd TextChanged
call s:WaitForRenders(s:renders + 1)
call assert_match('^c\+$', s:RowClasses()[6],
      \ 'the edited band picks up its new class')

" ---------------------------------------------------------------------------
" Syntax state propagates forward -- opening a string or a comment re-colours
" everything below it -- so an edit has to drop the classification of every
" band under it, while bands above keep theirs.  The probe counter is the
" mechanism itself: a class that was reused was not derived again.
" ---------------------------------------------------------------------------
let s:rows = len(s:RowClasses())
let s:before = simpleminimap#SampleCacheStats().classified
let s:renders = get(s:Session(), 'render_count', 0)
call setline(len(s:lines), 'int counter_last = 1;')
doautocmd TextChanged
call s:WaitForRenders(s:renders + 1)
let s:tail_probes = simpleminimap#SampleCacheStats().classified - s:before
call assert_true(s:tail_probes > 0, 'the edited band is re-classified')
call assert_true(s:tail_probes <= 8,
      \ printf('an edit in the last band re-classified %d lines, not the file',
      \        s:tail_probes))

let s:before = simpleminimap#SampleCacheStats().classified
let s:renders = get(s:Session(), 'render_count', 0)
call setline(1, '/* comment 01 rewritten */')
doautocmd TextChanged
call s:WaitForRenders(s:renders + 1)
let s:head_probes = simpleminimap#SampleCacheStats().classified - s:before
call assert_true(s:head_probes >= 4 * (s:rows - 1),
      \ printf('an edit in the first band re-classified %d lines of %d bands',
      \        s:head_probes, s:rows))

" ---------------------------------------------------------------------------
" The option really gates it: with colouring off the wire carries no class at
" all and the cells go back to density shading.
" ---------------------------------------------------------------------------
let g:simpleminimap_colors = 0
SimpleMinimapRefresh!
let s:renders = get(s:Session(), 'render_count', 0)
call s:WaitForRenders(s:renders + 1)

call assert_match('^n\+$', s:RowClasses()[0],
      \ 'g:simpleminimap_colors = 0 sends no class')
let s:types = s:PropTypes()
call assert_equal([], filter(copy(s:types), 'v:val =~# "^SimpleMinimapSyn"'),
      \ printf('no hue is painted while colouring is off, have %s', string(s:types)))
call assert_true(index(s:types, 'SimpleMinimapShadeMid') >= 0,
      \ printf('density shading takes the cells back, have %s', string(s:types)))

" ---------------------------------------------------------------------------
" Health reports what a user can see, in both states.
" ---------------------------------------------------------------------------
redir => s:health
silent SimpleMinimapHealth
redir END
call assert_match('\[INFO\] syntax colours: disabled by g:simpleminimap_colors', s:health)

let g:simpleminimap_colors = 1
redir => s:health
silent SimpleMinimapHealth
redir END
call assert_match('\[OK\] syntax colours: enabled', s:health)

call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
