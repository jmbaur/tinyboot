{ lib, stdenv, linuxKernel, ... }:
linuxKernel.manualConfig {
  inherit lib stdenv;
  inherit (linuxKernel.kernels.linux_6_1) src version modDirVersion kernelPatches extraMakeFlags;
  configfile = ./configs/${stdenv.hostPlatform.linuxArch}-linux.config;
  config = stdenv.hostPlatform.linux-kernel;
}
