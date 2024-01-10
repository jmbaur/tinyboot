export BUILD_DIR := justfile_directory() / "build"
zig_out_dir := justfile_directory() / "zig-out"

help:
	just --list

init:
	mkdir -p {{BUILD_DIR}}

build: init
	zig build install -Dcpu=baseline -Doptimize=Debug
	cat {{zig_out_dir}}/tboot-loader.cpio >{{BUILD_DIR}}/initrd

clean:
	rm -rf {{BUILD_DIR}}
	rm -rf {{zig_out_dir}} {{justfile_directory() / "zig-cache"}}

disk:
	nix run -L {{justfile_directory()}}

qemu: build
	test -f {{justfile_directory()}}/nixos-{{arch()}}-linux.qcow2 || just disk
	nix run -L {{justfile_directory()}}\#coreboot.qemu-{{arch()}}.config.build.qemuScript -- \
		-initrd {{BUILD_DIR}}/initrd \
		-drive if=virtio,file=nixos-{{arch()}}-linux.qcow2,format=qcow2,media=disk
