#!@bash@/bin/bash -e

# shellcheck shell=bash

if [ ! -f nixos.qcow2 ]; then
	zstd -d <@drive@/sd-image/* >nixos.img
	qemu-img convert -f raw -O qcow2 nixos.img nixos.qcow2
	qemu-img resize nixos.qcow2 +5G
	rm nixos.img
fi

@qemu@ -enable-kvm \
	-serial stdio \
	-m 1G \
	-kernel @kernel@ \
	-initrd @initrd@ \
	-append console=@console@ \
	-hda nixos.qcow2
