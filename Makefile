.PHONY: build test run clean

default: build

check:
	cargo clippy

build: check
	cargo build

test: check
	cargo test --workspace

run:
	nix run

clean:
	cargo clean
	rm nixos*.img
