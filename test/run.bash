#!@bash@/bin/bash -e

# shellcheck shell=bash

if [ ! -f nixos.img ]; then
	zstd -d <@drive@/sd-image/* >nixos.img
fi

qemu-kvm @qemuFlags@ \
	-serial stdio \
	-m 1G \
	-kernel @kernel@ \
	-initrd @initrd@ \
	-append console=@console@ \
	-drive if=virtio,file=nixos.img,format=raw
