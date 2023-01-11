#!@bash@/bin/bash -e

# shellcheck shell=bash

img=nixos-@system@.img

if [ ! -f $img ]; then
	zstd -d <@drive@/sd-image/* >$img
fi

@qemu@ @qemuFlags@ \
	-serial stdio \
	-m 1G \
	-kernel @kernel@ \
	-initrd @initrd@ \
	-append console=@console@ \
	-drive if=virtio,file=$img,format=raw
