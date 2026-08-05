.PHONY: check build install fmt lint clippy test test-rust test-daemon test-vim test-vim-lifecycle test-vim-real clean vim-core defcompile core-verify

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
check: core-verify fmt clippy test test-daemon defcompile vim-core test-vim test-vim-lifecycle test-vim-real

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

test-vim-real: build
	SIMPLEMINIMAP_TEST_DAEMON="$(CURDIR)/target/release/simpleminimap-daemon" \
		vim -Nu NONE -n -es -S tests/vim_integration.vim

clean:
	rm -rf target lib/simpleminimap-daemon lib/simpleminimap-daemon.exe tests/vim-errors.log

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simpleminimap/core.vim.
# ---------------------------------------------------------------------------

# The bundle is copied into each plugin rather than shared by reference, so
# that every plugin stays independently installable.  Copies drift silently
# unless something checks them, and one already went unnoticed long enough for
# the .simplecore directory itself to go missing: .simplecore.manifest pins the
# sha256 of every vendored file, and this target fails the build when a copy
# no longer matches.  Run ../.simplecore/vendor.sh --check to see suite-wide
# drift, or ../.simplecore/vendor.sh to re-vendor.
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
