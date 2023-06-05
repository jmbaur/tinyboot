# shellcheck shell=bash

export PATH=$PATH:@extraPath@

# stop() { pkill swtpm; }
# trap stop EXIT SIGINT

# mkdir -p /tmp/mytpm1
# swtpm socket --tpmstate dir=/tmp/mytpm1 \
# 	--ctrl type=unixio,path=/tmp/mytpm1/swtpm-sock \
# 	--tpm2 \
# 	--log level=20 &

if [[ ! -f nixos-@system@.iso ]]; then
	curl -L -o nixos-@system@.iso https://channels.nixos.org/nixos-22.11/latest-nixos-minimal-@system@.iso
fi

if [[ ! -f nixos-@testName@.qcow2 ]]; then
	echo "no disk image found"
	echo "make sure you run this first:"
	echo "nix run .#@testName@-disk"
	exit 1
fi

# -chardev socket,id=chrtpm,path=/tmp/mytpm1/swtpm-sock \
# -tpmdev emulator,id=tpm0,chardev=chrtpm \
# -device tpm-tis,tpmdev=tpm0 \

@qemu@ @qemuFlags@ \
	-smp 2 \
	-m 2G \
	-bios @corebootROM@/coreboot.rom \
	-device virtio-vga \
	-serial stdio \
	-device nec-usb-xhci,id=xhci \
	-device usb-storage,bus=xhci.0,drive=stick,removable=true \
	-drive if=none,id=stick,format=raw,file=nixos-@system@.iso \
	-drive if=virtio,file=nixos-@testName@.qcow2,format=qcow2,media=disk \
	"$@"
