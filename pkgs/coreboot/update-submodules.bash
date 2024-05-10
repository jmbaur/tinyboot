#!/usr/bin/env nix-shell
#!nix-shell -i bash -p nix-prefetch-git
#
# shellcheck shell=bash

cd "$(dirname "$0")" || exit

nix-prefetch-git https://github.com/coreboot/amd_blobs --rev 64cdd7c8ef199f5d79be14e7972fb7316f41beed >amd_blobs.json
nix-prefetch-git https://github.com/coreboot/blobs --rev a8db7dfe823def043368857b8fbfbba86f2e9e47 >blobs.json
nix-prefetch-git https://github.com/coreboot/cmocka --rev 8931845c35e78b5123d73430b071affd537d5935 >cmocka.json
nix-prefetch-git https://github.com/coreboot/fsp --rev 507ef01cce16dc1e1af898e60de96dbb8e9d6d17 >fsp.json
nix-prefetch-git https://github.com/coreboot/intel-microcode --rev ece0d294a29a1375397941a4e6f2f7217910bc89 >intel_microcode.json
nix-prefetch-git https://github.com/coreboot/qc_blobs --rev a252198ec6544e13904cfe831cec3e784aaa715d >qc_blobs.json
