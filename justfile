export BUILD_DIR := justfile_directory() / "build"
zig_bin_dir := justfile_directory() / "zig-out/bin"

help:
	just --list

init:
	mkdir -p {{BUILD_DIR}}

build:
	zig build -Dcpu=baseline -Doptimize=Debug

clean:
	rm -rf {{BUILD_DIR}}
	rm -rf {{zig_bin_dir}} {{justfile_directory() / "zig-cache"}}

disk:
	nix run -L {{justfile_directory()}}

base-initrd: init
	nix build -L {{justfile_directory()}}\#coreboot.qemu-{{arch()}}.config.build.baseInitrd \
		-o {{BUILD_DIR}}/result-base-initrd
	xz -d < {{BUILD_DIR}}/result-base-initrd/initrd > {{BUILD_DIR}}/base-initrd

initrd-contents: init
	echo -e "{{zig_bin_dir}}/tboot-loader\n/init" >{{BUILD_DIR}}/contents

initrd: build initrd-contents
	test -f {{BUILD_DIR}}/base-initrd || just base-initrd
	cat {{BUILD_DIR}}/base-initrd > {{BUILD_DIR}}/initrd
	rm -rf {{BUILD_DIR}}/root
	make-initrd-ng {{BUILD_DIR}}/contents {{BUILD_DIR}}/root
	(cd {{BUILD_DIR}}/root && find . -print0 | sort -z | cpio -o -H newc -R +0:+0 --reproducible --null >> {{BUILD_DIR}}/initrd)

qemu: initrd
	test -f {{justfile_directory()}}/nixos-{{arch()}}-linux.qcow2 || just disk
	nix run -L {{justfile_directory()}}\#coreboot.qemu-{{arch()}}.config.build.qemuScript -- \
		-initrd {{BUILD_DIR}}/initrd \
		-drive if=virtio,file=nixos-{{arch()}}-linux.qcow2,format=qcow2,media=disk
