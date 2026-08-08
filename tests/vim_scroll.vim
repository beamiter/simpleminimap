" Scroll and viewport-thumb regressions.
"
" These need a source buffer far taller than the window, which the shared
" integration fixture (six lines) can never provide: a six-line buffer cannot
" scroll at all, so every assertion here would pass vacuously there.
"
" Note on headless Vim: with no screen, `vim -es` keeps 'topline' pinned to the
" cursor line, so <C-E> is observable through topline but <C-Y> is not.  Upward
" scrolls are therefore asserted through session.last_scroll (the [from, to]
" the plugin computed and issued) rather than through the resulting topline.
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

call setline(1, map(range(1, 4000), '"line " .. v:val .. " ()"'))
let s:source_winid = win_getid()
call cursor(1, 1)
SimpleMinimapOpen

function! s:Session() abort
  return values(simpleminimap#DebugStatus().sessions)[0]
endfunction

function! s:Rendered() abort
  let state = simpleminimap#DebugStatus()
  return len(state.sessions) == 1 && len(values(state.sessions)[0].rows) > 0
endfunction

let s:attempt = 0
while !s:Rendered() && s:attempt < 200
  sleep 20m
  let s:attempt += 1
endwhile
call assert_true(s:Rendered(), 'the tall fixture renders')
let s:session = s:Session()
call assert_true(len(s:session.rows) > 4, 'the fixture produces enough rows to drag across')

" The wheel must move the tracked source window.  The previous implementation
" used winrestview({'topline': ...}), which Vim immediately re-clamps to keep
" the unmoved cursor visible, so this documented feature was a pure no-op.
SimpleMinimapFocus
call assert_equal(s:session.winid, win_getid())
let s:before = getwininfo(s:source_winid)[0].topline
call simpleminimap#ScrollSource(1)
let s:after = getwininfo(s:source_winid)[0].topline
call assert_true(s:after > s:before,
      \ 'the wheel scrolls the source window down (' .. s:before .. ' -> ' .. s:after .. ')')
call assert_equal(s:before + g:simpleminimap_mouse_scroll_lines, s:after,
      \ 'the wheel scrolls exactly g:simpleminimap_mouse_scroll_lines lines')

" Scrolling back up issues the mirrored scroll.
call simpleminimap#ScrollSource(-1)
call assert_equal([s:after, s:before], s:Session().last_scroll,
      \ 'the wheel scrolls back up by the same step')

" The scroll rate follows the option, and stops at the top of the buffer
" instead of running past it.
let s:saved_step = g:simpleminimap_mouse_scroll_lines
let g:simpleminimap_mouse_scroll_lines = 10
let s:before = getwininfo(s:source_winid)[0].topline
call simpleminimap#ScrollSource(1)
call assert_equal(s:before + 10, getwininfo(s:source_winid)[0].topline,
      \ 'the scroll step honours g:simpleminimap_mouse_scroll_lines')
let g:simpleminimap_mouse_scroll_lines = 50
let s:before = getwininfo(s:source_winid)[0].topline
call simpleminimap#ScrollSource(-1)
call assert_equal([s:before, 1], s:Session().last_scroll,
      \ 'scrolling up past the first line is clamped, not wrapped')
let g:simpleminimap_mouse_scroll_lines = s:saved_step

" Dragging the viewport thumb scrolls the source instead of jumping its cursor.
if exists('*test_setmouse')
  set mouse=a
  call win_gotoid(s:source_winid)
  normal! 1G
  call simpleminimap#OnCursorMoved(s:source_winid)
  let s:session = s:Session()
  let s:screen = win_screenpos(win_id2win(s:session.winid))

  " Mouse mappings are buffer-local, so a press is only delivered to the plugin
  " when the minimap already owns focus.
  SimpleMinimapFocus
  let s:cursor_before = getcurpos(s:source_winid)[1]
  let s:top_before = getwininfo(s:source_winid)[0].topline

  " Row 1 is inside the viewport band while the source sits at the top.
  call test_setmouse(s:screen[0], s:screen[1])
  let s:press_row = getmousepos().line
  call feedkeys("\<LeftMouse>", 'xt')
  call assert_equal(s:session.winid, win_getid(), 'the press keeps minimap focus')
  call assert_true(s:Session().drag_anchor.thumb, 'a press on the band grabs the thumb')
  call assert_equal(s:cursor_before, getcurpos(s:source_winid)[1],
        \ 'grabbing the thumb does not move the source cursor')

  call test_setmouse(s:screen[0] + 3, s:screen[1])
  let s:drag_row = getmousepos().line
  call feedkeys("\<LeftDrag>", 'xt')
  let s:top_dragged = getwininfo(s:source_winid)[0].topline
  call assert_true(s:top_dragged > s:top_before,
        \ 'dragging the thumb scrolls the source window')
  call assert_equal(s:session.rows[s:drag_row - s:press_row].start, s:top_dragged,
        \ 'the thumb lands on the row it was dragged to')
  call assert_equal(s:top_before, s:Session().last_scroll[0],
        \ 'the drag scrolls from where the view already was')

  call test_setmouse(s:screen[0] + 3, s:screen[1])
  call feedkeys("\<LeftRelease>", 'xt')
  call assert_equal(s:source_winid, win_getid(), 'releasing hands focus back')
  call assert_equal(s:top_dragged, getwininfo(s:source_winid)[0].topline,
        \ 'releasing the thumb leaves the scrolled view alone')

  " A press outside the band keeps the historical jump-to-band behaviour.
  SimpleMinimapFocus
  call test_setmouse(s:screen[0] + 20, s:screen[1])
  let s:press_row = getmousepos().line
  call feedkeys("\<LeftMouse>", 'xt')
  let s:session = s:Session()
  call assert_false(s:session.drag_anchor.thumb,
        \ 'a press outside the band does not grab the thumb')
  let s:band_row = s:session.rows[s:press_row - 1]
  call assert_equal(s:band_row.start + ((s:band_row.end - s:band_row.start) / 2),
        \ getcurpos(s:source_winid)[1],
        \ 'a press outside the viewport band still previews that band')
  call test_setmouse(s:screen[0] + 20, s:screen[1])
  call feedkeys("\<LeftRelease>", 'xt')
  call assert_equal(s:source_winid, win_getid())

  " With thumb dragging switched off, a press on the band previews the way it
  " always did.
  let g:simpleminimap_drag_thumb = 0
  call win_gotoid(s:source_winid)
  normal! 1G
  call simpleminimap#OnCursorMoved(s:source_winid)
  SimpleMinimapFocus
  call test_setmouse(s:screen[0], s:screen[1])
  let s:press_row = getmousepos().line
  call feedkeys("\<LeftMouse>", 'xt')
  let s:session = s:Session()
  call assert_false(s:session.drag_anchor.thumb)
  let s:band_row = s:session.rows[s:press_row - 1]
  call assert_equal(s:band_row.start + ((s:band_row.end - s:band_row.start) / 2),
        \ getcurpos(s:source_winid)[1],
        \ 'g:simpleminimap_drag_thumb = 0 restores press-to-preview')
  call test_setmouse(s:screen[0], s:screen[1])
  call feedkeys("\<LeftRelease>", 'xt')
  let g:simpleminimap_drag_thumb = 1
  set mouse=
endif

SimpleMinimapClose
call simpleminimap#Stop()

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
