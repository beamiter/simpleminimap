" g:simpleminimap_display = 'popup': the minimap floats over the tracked window
" instead of taking a window of its own.
"
" The split has always cost 18 columns of code width permanently, fought with
" 'winfixwidth', broke <C-w> muscle memory and disturbed every plugin that
" counts windows.  A popup is what satellite.nvim and nvim-scrollview draw, and
" it is display-only: Vim cannot move the cursor into a popup, so the commands
" that require entering the minimap have to say so rather than misfire.
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
let g:simpleminimap_display = 'popup'
runtime plugin/simpleminimap.vim

if !has('popupwin')
  qall!
endif

call assert_equal('popup', g:simpleminimap_display)

call setline(1, map(range(1, 200), 'printf("line %03d = compute(%d);", v:val, v:val)'))
let s:source_winid = win_getid()
let s:source_bufnr = bufnr()
let s:windows_before = winnr('$')

SimpleMinimapOpen

function! s:Session() abort
  let state = simpleminimap#DebugStatus()
  return len(state.sessions) == 1 ? values(state.sessions)[0] : {}
endfunction

let s:attempt = 0
while empty(get(s:Session(), 'rows', [])) && s:attempt < 200
  sleep 20m
  let s:attempt += 1
endwhile
let s:session = s:Session()
call assert_true(!empty(get(s:session, 'rows', [])), 'the popup minimap rendered')
call assert_equal('popup', s:session.kind)

" ---------------------------------------------------------------------------
" The whole point: no window was taken.
" ---------------------------------------------------------------------------
call assert_equal(s:windows_before, winnr('$'),
      \ 'a popup minimap does not consume a window')
call assert_equal(s:source_winid, win_getid(),
      \ 'opening it does not move the cursor out of the source window')
call assert_equal([0, 0], win_id2tabwin(s:session.winid),
      \ 'the surface really is a popup, not a hidden split')

" ---------------------------------------------------------------------------
" It is placed against the tracked window's edge and is exactly as tall.
" ---------------------------------------------------------------------------
let s:origin = win_screenpos(win_id2win(s:source_winid))
let s:pos = popup_getpos(s:session.winid)
call assert_equal(1, s:pos.visible)
call assert_equal(s:origin[0], s:pos.line, 'the popup starts at the window top')
call assert_equal(winheight(win_id2win(s:source_winid)), s:pos.height,
      \ 'the popup is as tall as the window it covers')
call assert_equal(g:simpleminimap_width, s:pos.width)
call assert_equal(s:origin[1] + winwidth(win_id2win(s:source_winid)) - g:simpleminimap_width,
      \ s:pos.col, 'the popup sits against the right edge')

" The rendered rows fill the popup, and the session tracks the real buffer.
call assert_equal(s:pos.height, len(getbufline(s:session.bufnr, 1, '$')))
call assert_equal(s:source_bufnr, s:session.source_bufnr)
call assert_equal(200, s:session.source_lines)

" Overlays are drawn into the popup: matchaddpos() applies to popup windows,
" which is what makes the density shading and the sign/viewport bands work
" there at all.
call assert_true(s:session.viewport_match > 0)
call assert_true(s:session.cursor_match > 0)
let s:groups = map(getmatches(s:session.winid), 'v:val.group')
call assert_true(index(s:groups, 'SimpleMinimapViewport') >= 0,
      \ 'the viewport band is matched into the popup window itself')
call assert_true(index(s:groups, 'SimpleMinimapCursor') >= 0)
if has('textprop')
  call assert_true(len(prop_list(1, {'bufnr': s:session.bufnr})) > 0,
        \ 'density shading reaches the popup buffer')
endif

" ---------------------------------------------------------------------------
" It follows the window it covers.
" ---------------------------------------------------------------------------
let s:before = popup_getpos(s:session.winid)
" leftabove, so the new window's right edge is genuinely somewhere else -- a
" rightbelow split keeps the same right edge and the assertion below would pass
" without the popup having moved at all.
leftabove vsplit
let s:split_winid = win_getid()
call simpleminimap#OnContextChanged()
let s:attempt = 0
while popup_getpos(s:Session().winid).col == s:before.col && s:attempt < 100
  sleep 20m
  let s:attempt += 1
endwhile
let s:after = popup_getpos(s:Session().winid)
call assert_equal(s:split_winid, s:Session().source_winid,
      \ 'the new split is now the tracked window')
call assert_notequal(s:before.col, s:after.col,
      \ 'the popup moved to the newly tracked window')
call assert_equal(win_screenpos(win_id2win(s:split_winid))[1]
      \ + winwidth(win_id2win(s:split_winid)) - g:simpleminimap_width,
      \ s:after.col)
close!
call simpleminimap#OnContextChanged()
call simpleminimap#RepositionSurfaces()
call assert_equal(s:source_winid, s:Session().source_winid,
      \ 'closing that split hands the session back to the original window')
call assert_equal(1, popup_getpos(s:Session().winid).visible,
      \ 'the popup is not left hidden')
call assert_equal(s:before.col, popup_getpos(s:Session().winid).col,
      \ 'closing that split puts the popup back')

" ---------------------------------------------------------------------------
" Commands that need to enter the minimap refuse instead of misfiring.
" ---------------------------------------------------------------------------
call cursor(50, 1)
call simpleminimap#Preview()
call assert_equal(50, line('.'),
      \ 'Preview() does not read the source cursor as a minimap row')
call simpleminimap#Jump()
call assert_equal(50, line('.'),
      \ 'Jump() does not read the source cursor as a minimap row')
silent! SimpleMinimapFocus
call assert_equal(s:source_winid, win_getid(),
      \ 'Focus() leaves the cursor where it is')

" Everything that does not need to be entered keeps working.
SimpleMinimapResize 20
call assert_equal(20, popup_getpos(s:Session().winid).width)
call assert_equal(20, g:simpleminimap_width)
SimpleMinimapResize 12
silent SimpleMinimapHealth
SimpleMinimapRefresh!

" ---------------------------------------------------------------------------
" Closing takes the popup and its buffer with it.
" ---------------------------------------------------------------------------
let s:popup_bufnr = s:Session().bufnr
let s:popup_winid = s:Session().winid
SimpleMinimapClose
call assert_equal({}, s:Session(), 'the session is gone')
call assert_equal([], getwininfo(s:popup_winid), 'the popup is closed')
call assert_false(bufexists(s:popup_bufnr),
      \ 'the popup owns its scratch buffer, so closing must not leak it')
call assert_equal(s:windows_before, winnr('$'))

" Toggling it back and away again leaks nothing either.
SimpleMinimap
call assert_equal('popup', s:Session().kind)
SimpleMinimap
call assert_equal({}, s:Session())

call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
