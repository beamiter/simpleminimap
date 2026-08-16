.PHONY: check build install fmt lint clippy test test-rust test-daemon test-vim test-vim-lifecycle test-vim-scroll test-vim-projection test-vim-overlays test-vim-incremental test-vim-colors test-vim-fill test-vim-popup test-vim-timeout test-vim-health test-vim-doc test-vim-remote test-vim-real clean vim-core defcompile core-verify

build:
	cargo build --release --locked

install:
	./install.sh

fmt:
	cargo fmt --all -- --check

clippy:
	cargo clippy --all-targets --locked -- -D warnings

# Kept: `lint` predates the suite-wide name.
lint: clippy

# `check` is the full gate in every simple* plugin; `test` is cargo test alone.
check: core-verify fmt clippy test test-daemon defcompile vim-core test-vim test-vim-lifecycle test-vim-scroll test-vim-projection test-vim-overlays test-vim-incremental test-vim-colors test-vim-fill test-vim-popup test-vim-timeout test-vim-health test-vim-doc test-vim-remote test-vim-real

# Kept: `test-rust` predates the suite-wide name.
test-rust: test

test:
	cargo test --locked --all-targets

test-daemon: build
	./target/release/simpleminimap-daemon --self-test
	./target/release/simpleminimap-daemon --help >/dev/null
	./target/release/simpleminimap-daemon --version >/dev/null

test-vim:
	vim -Nu NONE -n -es -S tests/vim_integration.vim

test-vim-lifecycle:
	vim -Nu NONE -n -es -S tests/vim_lifecycle.vim

# Needs a source buffer much taller than the window, which the shared
# integration fixture (six lines) cannot provide: a six-line buffer never
# scrolls, so every scroll assertion there would pass vacuously.
test-vim-scroll:
	vim -Nu NONE -n -es -S tests/vim_scroll.vim

# Cost assertions on a 50,000-line buffer with 4,000 signs: the fixture only
# makes sense here, and it is what catches an O(signs x rows) regression.
test-vim-projection:
	vim -Nu NONE -n -es -S tests/vim_projection.vim

# Quickfix, location list, marks and diff projections, plus the provider
# registry a third-party plugin registers through.  Needs a source file long
# enough that one minimap row covers a real band of lines.
test-vim-overlays:
	vim -Nu NONE -n -es -S tests/vim_overlays.vim

# Sample-cache accounting on a 4,000-line buffer: the point of the test is what
# a single keystroke costs, which only means something when the buffer is much
# taller than the minimap.
test-vim-incremental:
	vim -Nu NONE -n -es -S tests/vim_incremental.vim

# Syntax classification needs a real syntax-highlighted buffer of a known
# filetype, which no other fixture here has, and g:simpleminimap_fill is pinned
# to 'compact' so band boundaries are predictable enough to assert per row.
test-vim-colors:
	vim -Nu NONE -n -es -S tests/vim_colors.vim

# Row count and the blank tail below it, which only differ when the file is
# shorter than the minimap window is tall.
test-vim-fill:
	vim -Nu NONE -n -es -S tests/vim_fill.vim

# g:simpleminimap_display is read when a session opens, and the popup path
# shares almost nothing with the split path below it, so it gets its own Vim.
test-vim-popup:
	vim -Nu NONE -n -es -S tests/vim_popup.vim

# The wedged-daemon mode is selected by an environment variable read at daemon
# start, so it needs its own Vim instance.
test-vim-timeout:
	vim -Nu NONE -n -es -S tests/vim_timeout.vim

# Runs against a daemon announcing an older protocol, selected by an
# environment variable read at daemon start.
test-vim-health:
	vim -Nu NONE -n -es -S tests/vim_health.vim

# doc/simpleminimap.txt as a help file: dead |links| and *tags* claimed for
# generic words are invisible to every other target here and to reading it.
test-vim-doc:
	vim -Nu NONE -n -i NONE -es -S tests/vim_doc.vim

# A SimpleRemote virtual workspace, simulated: remote:// buffers whose
# 'buftype' flips to acwrite after an asynchronous fill from a callback.  Fed
# on stdin rather than with -S because Vim does not fire OptionSet during
# startup, and the 'buftype' flip reaching the minimap through OptionSet is
# one of the paths under test.
test-vim-remote:
	printf 'source tests/vim_remote.vim\n' | vim -Nu NONE -n -i NONE -es

test-vim-real: build
	SIMPLEMINIMAP_TEST_DAEMON="$(CURDIR)/target/release/simpleminimap-daemon" \
		vim -Nu NONE -n -es -S tests/vim_integration.vim

clean:
	rm -rf target lib/simpleminimap-daemon lib/simpleminimap-daemon.exe tests/vim-errors.log tests/vim-doc-tags tests/vim-overlay-*.txt

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
#   https://github.com/beamiter/simplecore
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simpleminimap/core.vim.
# ---------------------------------------------------------------------------

# The bundle is copied into each plugin rather than shared by reference, so
# that every plugin stays independently installable.  Copies drift silently
# unless something checks them, and one such copy went unnoticed long enough
# for the whole .simplecore directory to go missing before it had a repository
# of its own: .simplecore.manifest pins the sha256 of every vendored file, and
# this target fails the build when a copy no longer matches.
#
#   git clone https://github.com/beamiter/simplecore ../.simplecore
#   ../.simplecore/vendor.sh --check    # suite-wide drift
#   ../.simplecore/vendor.sh            # re-vendor
core-verify:
	@grep -E '^[0-9a-f]{64}  ' .simplecore.manifest | sha256sum -c --quiet
	@echo "simplecore: bundle v$$(awk '$$1 == "version" { print $$2 }' .simplecore.manifest) verified"

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts and the protocol handshake.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
