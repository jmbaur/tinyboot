build_dir := justfile_directory() / "build"
cargo_debug_target_dir := justfile_directory() / "target" / env_var("CARGO_BUILD_TARGET") / "debug"

help:
	just --list

init:
	mkdir -p {{build_dir}}

clean:
	rm -rf {{build_dir}}

disk:
	nix run -L {{justfile_directory()}}\#disk

qemu-script: init
	nix build -L {{justfile_directory()}}\#coreboot.qemu-{{arch()}}.config.build.qemuScript \
		-o {{build_dir}}/result-qemu-script

base-initrd: init
	nix build -L {{justfile_directory()}}\#coreboot.qemu-{{arch()}}.config.build.baseInitrd \
		-o {{build_dir}}/result-base-initrd
	xz -d < {{build_dir}}/result-base-initrd/initrd > {{build_dir}}/base-initrd

initrd-contents: init
	echo -e "{{cargo_debug_target_dir}}/tboot-init\n/init" >{{build_dir}}/contents

initrd: initrd-contents
	test -f {{build_dir}}/base-initrd || just base-initrd
	cat {{build_dir}}/base-initrd > {{build_dir}}/initrd
	cargo build --package tboot-init
	rm -rf {{build_dir}}/root
	make-initrd-ng {{build_dir}}/contents {{build_dir}}/root
	(cd {{build_dir}}/root && find . -print0 | sort -z | cpio -o -H newc -R +0:+0 --reproducible --null >> {{build_dir}}/initrd)

qemu: initrd
	test -f {{justfile_directory()}}/nixos-bls-{{arch()}}-linux.qcow2 || just disk
	test -f {{build_dir}}/result-qemu-script/bin/tinyboot-qemu || just qemu-script
	env BUILD_DIR={{build_dir}} \
		{{build_dir}}/result-qemu-script/bin/tinyboot-qemu \
		-drive if=virtio,file=nixos-bls-{{arch()}}-linux.qcow2,format=qcow2,media=disk \
		-initrd {{build_dir}}/initrd
