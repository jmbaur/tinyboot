#!/usr/bin/env bash
# shellcheck shell=bash

set -o errexit
set -o nounset
set -o pipefail

stop() { pkill swtpm; }
trap stop EXIT SIGINT

tpm_dir="${BUILD_DIR}/mytpm1"
mkdir -p "$tpm_dir"
swtpm socket --tpmstate dir="$tpm_dir" \
	--ctrl type=unixio,path="${tpm_dir}/swtpm-sock" \
	--tpm2 &

"$QEMU" \
	-enable-kvm \
	-nographic \
	-smp 2 -m 2G \
	-netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
	-chardev socket,id=chrtpm,path="${tpm_dir}/swtpm-sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
	"$@"
