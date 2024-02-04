#!/usr/bin/env nix-shell
#!nix-shell -i bash -p nix-prefetch-git
#
# shellcheck shell=bash

cd "$(dirname "$0")" || exit

nix-prefetch-git https://review.coreboot.org/amd_blobs --rev e4519efca74615f0f322d595afa7702c64753914 >amd_blobs.json
nix-prefetch-git https://review.coreboot.org/blobs.git --rev a8db7dfe823def043368857b8fbfbba86f2e9e47 >blobs.json
nix-prefetch-git https://review.coreboot.org/cmocka.git --rev 8931845c35e78b5123d73430b071affd537d5935 >cmocka.json
nix-prefetch-git https://review.coreboot.org/fsp.git --rev 481ea7cf0bae0107c3e14aa746e52657647142f3 >fsp.json
nix-prefetch-git https://review.coreboot.org/intel-microcode.git --rev 6788bb07eb5f9e9b83c31ea1364150fe898f450a >intel_microcode.json
nix-prefetch-git https://review.coreboot.org/qc_blobs.git --rev a252198ec6544e13904cfe831cec3e784aaa715d >qc_blobs.json
