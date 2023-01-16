.PHONY: build test run clean

default: build

check:
	cargo clippy

build: check
	cargo build

test: check
	cargo test --workspace

run:
	nix run -L

clean:
	cargo clean
	rm -f *.qcow2
