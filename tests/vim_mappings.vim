" What this plugin claims in the leader namespace it shares with its siblings.
"
" The default used to be a bare <Leader>m, guarded by maparg('<leader>m', 'n').
" maparg() matches a sequence exactly, so that guard is blind to any sibling
" that maps a continuation of the key: simplemarkdown's <Leader>md left
" maparg('<leader>m') empty, and this plugin's <Leader>m left
" maparg('<leader>md') empty, so both defaults installed whatever the load
" order and <Leader>m became a strict prefix of <Leader>md.  Vim then cannot
" dispatch <Leader>m until 'timeoutlen' has elapsed, and a key typed inside
" that window silently goes somewhere else.
"
" No other test here loads the plugin with the default mapping enabled -- every
" one of them sets g:simpleminimap_set_default_mapping to 0 first -- so until
" this file the default was the only user-visible mapping decision with no
" coverage at all.
set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
call delete(s:root .. '/tests/vim-errors.log')
execute 'set runtimepath^=' .. fnameescape(s:root)
let g:simpleminimap_daemon_path = s:root .. '/tests/mock_daemon.py'
let g:simpleminimap_debounce = 0
" Named rather than inherited: every assertion below spells the resulting key
" out as a literal, and Vim's default only happens to be a backslash.
let mapleader = '\'

let s:plugin = s:root .. '/plugin/simpleminimap.vim'

function s:Load() abort
  if exists('g:loaded_simpleminimap')
    unlet g:loaded_simpleminimap
  endif
  execute 'source ' .. fnameescape(s:plugin)
endfunction

" Every normal-mode sequence a user could actually type.  <Plug> pseudo-keys
" are excluded: they are addressed by name from another mapping and never
" arrive from the keyboard, so they can neither shadow a key nor cost a
" 'timeoutlen' pause.
function s:UserSequences() abort
  let l:out = []
  for l:entry in maplist()
    " 'n' is nmap; ' ' is map, which includes normal mode.
    if (l:entry.mode !~# 'n' && l:entry.mode !=# ' ') || l:entry.lhs =~# '^<Plug>'
      continue
    endif
    call add(l:out, l:entry.lhs)
  endfor
  return sort(l:out)
endfunction

" Pairs where one sequence continues another -- the relationship
" simplewhichkey#Conflicts() reports at runtime, computed here over the
" mappings that exist right after this plugin has installed its default.
function s:PrefixConflicts() abort
  let l:sequences = s:UserSequences()
  let l:out = []
  for l:short in l:sequences
    for l:long in l:sequences
      if l:short !=# l:long && strpart(l:long, 0, len(l:short)) ==# l:short
        call add(l:out, l:short .. ' <-> ' .. l:long)
      endif
    endfor
  endfor
  return l:out
endfunction

" ---------------------------------------------------------------------------
" simplemarkdown loaded first.
"
" Its <Leader>md is already installed when this plugin's guard runs, which is
" exactly the case the old exact-match guard could not see.
" ---------------------------------------------------------------------------
mapclear
nmap <silent> <leader>md <Cmd>echo 'simplemarkdown-toggle'<CR>
call s:Load()

call assert_match('simpleminimap-toggle', maparg('<leader>mm', 'n'),
      \ 'the default mapping is <Leader>mm')
call assert_equal('', maparg('<leader>m', 'n'),
      \ 'the plugin claims no one-character leader key: <Leader>m is a strict '
      \ .. 'prefix of every sibling default under m, starting with '
      \ .. 'simplemarkdown''s <Leader>md')
call assert_match('simplemarkdown-toggle', maparg('<leader>md', 'n'),
      \ 'loading this plugin does not disturb a sibling''s default')
call assert_equal([], s:PrefixConflicts(),
      \ 'no default mapping continues another: a shorter sequence cannot fire '
      \ .. 'until ''timeoutlen'' has passed')

" ---------------------------------------------------------------------------
" This plugin loaded first.
"
" simplemarkdown's guard is maparg('<leader>md', 'n') ==# '', so what matters
" is that our default leaves that empty -- and that it stays empty for the same
" reason in both directions, not by accident of load order.
" ---------------------------------------------------------------------------
mapclear
call s:Load()
call assert_match('simpleminimap-toggle', maparg('<leader>mm', 'n'))
call assert_equal('', maparg('<leader>md', 'n'),
      \ 'a sibling''s guard still sees its own key free')
nmap <silent> <leader>md <Cmd>echo 'simplemarkdown-toggle'<CR>
call assert_match('simpleminimap-toggle', maparg('<leader>mm', 'n'),
      \ 'and installing it does not disturb ours')
call assert_equal([], s:PrefixConflicts(),
      \ 'nor does the reverse load order produce a prefix conflict')

" ---------------------------------------------------------------------------
" The guard still does the one job left to it: a key the user has already
" claimed is never taken.
" ---------------------------------------------------------------------------
mapclear
nmap <silent> <leader>mm <Cmd>echo 'user-owned'<CR>
call s:Load()
call assert_match('user-owned', maparg('<leader>mm', 'n'),
      \ 'the default never replaces a mapping the user owns')

" ---------------------------------------------------------------------------
" And the opt-out installs nothing at all -- on the new key or the old one.
" ---------------------------------------------------------------------------
mapclear
let g:simpleminimap_set_default_mapping = 0
call s:Load()
call assert_equal('', maparg('<leader>mm', 'n'),
      \ 'g:simpleminimap_set_default_mapping = 0 installs no default')
call assert_equal('', maparg('<leader>m', 'n'))
call assert_equal([], s:UserSequences(),
      \ 'with the default off the plugin leaves the typed-key namespace alone')

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
