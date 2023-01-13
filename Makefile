.PHONY: build test run clean

default: build

build:
	cargo build

test:
	cargo test --workspace

run:
	nix run

clean:
	cargo clean
	rm nixos*.img
