" doc/simpleminimap.txt as a help file, not just as prose.
"
" Two whole classes of defect are invisible to every other test here and to
" reading the file: a |link| to a tag nobody defines (CTRL-] gives E149), and a
" *tag* claimed for a generic word, which installs the plugin into the shared,
" global help-tag namespace and hijacks :help for every other plugin.  Both
" shipped in the previous round.
set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
call delete(s:root .. '/tests/vim-errors.log')
execute 'set runtimepath^=' .. fnameescape(s:root)

let s:doc = s:root .. '/doc/simpleminimap.txt'
let s:lines = readfile(s:doc)
call assert_true(len(s:lines) > 100, 'the help file was read')

" ---------------------------------------------------------------------------
" doc/tags must be in sync with the help file.
"
" Generated into a scratch directory rather than over doc/tags, so running the
" gate never mutates the tree it is checking.
" ---------------------------------------------------------------------------
let s:scratch = s:root .. '/tests/vim-doc-tags'
" ---------------------------------------------------------------------------
" The vendored-supervisor section must describe what this plugin actually does.
"
" autoload/simpleminimap/core.vim is the simple* suite's shared daemon
" supervisor, and this plugin does not call it once: the backend is started,
" fenced, restarted and given up on by autoload/simpleminimap.vim.  The help
" used to introduce the vendored file as "the suite's shared daemon supervisor"
" and stop there, which reads as a claim that the lifecycle you get is the
" shared, well-tested one -- and `make vim-core` running 300-odd lines of green
" supervisor tests, plus `make core-verify` reporting the bundle verified,
" agree with that reading all the way to the wrong conclusion.
"
" So the sentence is tied here to the fact underneath it.  Adopt the core
" supervisor and the disclaimer becomes false and this fails; drop the
" disclaimer while nothing calls the core and this fails too.
" ---------------------------------------------------------------------------
let s:self = expand('<sfile>:p')
let s:vendored = [s:root .. '/autoload/simpleminimap/core.vim',
      \ s:root .. '/tests/vim_core.vim', s:self]
let s:call_sites = []
for s:file in glob(s:root .. '/autoload/**/*.vim', 0, 1)
      \ + glob(s:root .. '/plugin/*.vim', 0, 1)
      \ + glob(s:root .. '/tests/*.vim', 0, 1)
  if index(s:vendored, s:file) >= 0
    continue
  endif
  if match(readfile(s:file), 'simpleminimap#core#') >= 0
    call add(s:call_sites, fnamemodify(s:file, ':.'))
  endif
endfor

" Asserted as two booleans rather than with assert_match() over the help text:
" a failed assert_match prints the entire help file and buries the answer.
let s:says_unused = match(s:lines, 'This plugin does not call it') >= 0
call assert_equal(empty(s:call_sites), s:says_unused, empty(s:call_sites)
      \ ? 'nothing outside the vendored files calls simpleminimap#core#, so '
      \ .. '|simpleminimap-simplecore| must say so rather than leave the reader '
      \ .. 'to assume the shared supervisor is what runs here'
      \ : printf('|simpleminimap-simplecore| still says the core supervisor is '
      \ .. 'unused, but it is called from %s', join(s:call_sites, ', ')))

call delete(s:scratch, 'rf')
call mkdir(s:scratch, 'p')
call writefile(s:lines, s:scratch .. '/simpleminimap.txt')
execute 'helptags' fnameescape(s:scratch)
let s:committed = readfile(s:root .. '/doc/tags')
let s:fresh = readfile(s:scratch .. '/tags')
" Compared as two set differences rather than as two lists: an assert_equal()
" on the whole file prints both copies in full, which buries the one tag that
" actually moved.
call assert_equal([], filter(copy(s:fresh), 'index(s:committed, v:val) < 0'),
      \ 'doc/tags is missing tags: run vim -es -c "helptags doc" -c qa')
call assert_equal([], filter(copy(s:committed), 'index(s:fresh, v:val) < 0'),
      \ 'doc/tags has tags the help file no longer defines: run helptags doc')

" ---------------------------------------------------------------------------
" Every tag this plugin defines stays inside its own namespace.
"
" `*not*` used as prose emphasis reads as emphasis and parses as a tag
" definition, so `:help not` opened this plugin's help for every user that had
" it installed.
" ---------------------------------------------------------------------------
let s:owned = '\%(simpleminimap\|SimpleMinimap\|:SimpleMinimap\|g:simpleminimap_'
      \ .. '\|<Plug>(simpleminimap\)'
let s:defined = []
for s:line in readfile(s:scratch .. '/tags')
  let s:tag = split(s:line, "\t")[0]
  call add(s:defined, s:tag)
  call assert_match('^' .. s:owned, s:tag,
        \ printf('help tag %s is not in this plugin''s namespace: prose emphasis '
        \ .. 'with *stars* claims a tag in the shared global namespace', s:tag))
endfor
call assert_true(len(s:defined) > 40, 'the tag file was parsed')

" ---------------------------------------------------------------------------
" Every |link| resolves.
"
" Help tag lookup reads the doc/tags of every 'runtimepath' entry, which is
" exactly what CTRL-] does, so this is the same answer the user gets -- without
" opening a help window per link.
" ---------------------------------------------------------------------------
let s:known = {}
for s:tagfile in globpath(&runtimepath, 'doc/tags', 0, 1)
  for s:line in readfile(s:tagfile)
    let s:known[split(s:line, "\t")[0]] = 1
  endfor
endfor
call assert_true(has_key(s:known, 'help-tags'), 'the runtime help tags were found')

let s:links = []
for s:line in s:lines
  let s:column = 0
  while 1
    let s:hit = matchstrpos(s:line, '|[^ \t|]\+|', s:column)
    if s:hit[1] < 0
      break
    endif
    let s:column = s:hit[2]
    let s:link = s:hit[0][1 : -2]
    if index(s:links, s:link) < 0
      call add(s:links, s:link)
    endif
  endwhile
endfor
call assert_true(len(s:links) > 10, 'the help file cross-references something')

for s:link in s:links
  call assert_true(has_key(s:known, s:link),
        \ printf('|%s| is a dead help link: CTRL-] on it gives E149', s:link))
endfor

call delete(s:scratch, 'rf')

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/vim-errors.log')
  cquit
endif
qall!
