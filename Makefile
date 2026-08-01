.PHONY: build install fmt lint test test-rust test-daemon test-vim test-vim-lifecycle test-vim-real clean vim-core defcompile

build:
	cargo build --release --locked

install:
	./install.sh

fmt:
	cargo fmt --check

lint:
	cargo clippy --all-targets -- -D warnings

test: fmt lint test-rust test-daemon defcompile vim-core test-vim test-vim-lifecycle test-vim-real

test-rust:
	cargo test --all-targets

test-daemon: build
	./target/release/simpleminimap-daemon --self-test
	./target/release/simpleminimap-daemon --help >/dev/null
	./target/release/simpleminimap-daemon --version >/dev/null

test-vim:
	vim -Nu NONE -n -es -S tests/vim_integration.vim

test-vim-lifecycle:
	vim -Nu NONE -n -es -S tests/vim_lifecycle.vim

test-vim-real: build
	SIMPLEMINIMAP_TEST_DAEMON="$(CURDIR)/target/release/simpleminimap-daemon" \
		vim -Nu NONE -n -es -S tests/vim_integration.vim

clean:
	rm -rf target lib/simpleminimap-daemon lib/simpleminimap-daemon.exe tests/vim-errors.log

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simpleminimap/core.vim.
# ---------------------------------------------------------------------------

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts and the protocol handshake.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
