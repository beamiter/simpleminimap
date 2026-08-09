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
SimpleMinimapStyle ascii
call assert_equal('ascii', g:simpleminimap_render_style)
SimpleMinimapStyle braille
" A colour-scheme reload used to push window-local options at whatever the
" session's winid was; a popup has none, and setwinvar() on one is not a way to
" find that out.
doautocmd ColorScheme
call assert_equal(1, popup_getpos(s:Session().winid).visible,
      \ 'a ColorScheme reload leaves the popup alone')
" `visible` on its own proves nothing -- setwinvar() on a popup does not throw
" and does not hide it -- so assert the options themselves.  Without the guard
" the popup comes out of a reload carrying the minimap statusline expression
" and 'winfixwidth', neither of which a popup has any use for.
call assert_equal('', getwinvar(s:Session().winid, '&statusline', 'unset'),
      \ 'a ColorScheme reload does not push a statusline onto the popup')
call assert_equal(0, getwinvar(s:Session().winid, '&winfixwidth', -1),
      \ 'a ColorScheme reload does not push winfixwidth onto the popup')
call assert_equal('SimpleMinimapNormal', getwinvar(s:Session().winid, '&wincolor', ''),
      \ 'the popup keeps the colour it was created with')

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

" ---------------------------------------------------------------------------
" Two popup sessions at once must not share a scratch buffer.
"
" A popup buffer used to be named `simpleminimap://popup/<localtime() +
" source_winid>`, and that sum aliases between tab pages: open the minimap in
" the tab whose window id is the higher one, let the clock make up the
" difference, open it in the other tab, and bufadd() hands the second session
" the first session's buffer.  Both then render into it -- whichever renders
" last wins, so one tab shows the other tab's file -- and closing either one
" wipes a buffer the surviving popup is still displaying.  The wait below is
" what makes that collision certain rather than a one-second-in-N flake.
" ---------------------------------------------------------------------------
function! s:SessionForTab(tabnr) abort
  for session in values(simpleminimap#DebugStatus().sessions)
    if get(session, 'tabnr', -1) == a:tabnr
      return session
    endif
  endfor
  return {}
endfunction

function! s:WaitForTab(tabnr) abort
  let attempt = 0
  while empty(get(s:SessionForTab(a:tabnr), 'rows', [])) && attempt < 200
    sleep 20m
    let attempt += 1
  endwhile
  return s:SessionForTab(a:tabnr)
endfunction

let s:tab1_winid = win_getid()
tabnew
call setline(1, map(range(1, 120), 'printf("other tab %03d", v:val)'))
let s:tab2_winid = win_getid()
call assert_true(s:tab2_winid > s:tab1_winid,
      \ 'the second tab page owns the later window id')
call assert_true(s:tab2_winid - s:tab1_winid <= 5,
      \ 'the two window ids are close enough to force the collision below')

SimpleMinimapOpen
let s:tab2 = s:WaitForTab(2)
call assert_true(!empty(get(s:tab2, 'rows', [])), 'the second tab rendered')
let s:opened_at = localtime()
while localtime() - s:opened_at < s:tab2_winid - s:tab1_winid
  sleep 50m
endwhile

tabprevious
SimpleMinimapOpen
let s:tab1 = s:WaitForTab(1)
call assert_true(!empty(get(s:tab1, 'rows', [])), 'the first tab rendered')
let s:tab2 = s:SessionForTab(2)
call assert_equal(2, len(simpleminimap#DebugStatus().sessions),
      \ 'both tab pages have a session')
call assert_notequal(s:tab1.bufnr, s:tab2.bufnr,
      \ 'two live popup sessions own two different scratch buffers')
call assert_equal(200, s:tab1.source_lines)
call assert_equal(120, s:tab2.source_lines)
call assert_equal(len(s:tab1.rows), len(getbufline(s:tab1.bufnr, 1, '$')),
      \ 'the first tab displays its own rendering')
call assert_equal(len(s:tab2.rows), len(getbufline(s:tab2.bufnr, 1, '$')),
      \ 'the second tab displays its own rendering')

" Closing one of them must not take the other one's buffer with it.
tabnext
SimpleMinimapClose
call assert_equal({}, s:SessionForTab(2), 'the second tab session is gone')
call assert_false(bufexists(s:tab2.bufnr), 'it wiped its own buffer')
tabprevious
call assert_true(bufexists(s:tab1.bufnr),
      \ 'closing one popup session leaves the other one its buffer')
call assert_equal(1, popup_getpos(s:tab1.winid).visible,
      \ 'the surviving popup is still on screen')
call assert_equal(len(s:tab1.rows), len(getbufline(s:tab1.bufnr, 1, '$')))
SimpleMinimapClose
call assert_equal({}, s:SessionForTab(1))
call assert_false(bufexists(s:tab1.bufnr))

call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
