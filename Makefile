.PHONY: build install fmt lint test test-rust test-vim test-vim-lifecycle test-vim-real clean

build:
	cargo build --release --locked

install:
	./install.sh

fmt:
	cargo fmt --check

lint:
	cargo clippy --all-targets -- -D warnings

test: fmt lint test-rust test-vim test-vim-lifecycle test-vim-real

test-rust:
	cargo test --all-targets

test-vim:
	vim -Nu NONE -n -es -S tests/vim_integration.vim

test-vim-lifecycle:
	vim -Nu NONE -n -es -S tests/vim_lifecycle.vim

test-vim-real: build
	SIMPLEMINIMAP_TEST_DAEMON="$(CURDIR)/target/release/simpleminimap-daemon" \
		vim -Nu NONE -n -es -S tests/vim_integration.vim

clean:
	rm -rf target lib/simpleminimap-daemon lib/simpleminimap-daemon.exe tests/vim-errors.log
