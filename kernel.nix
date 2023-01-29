{ lib, stdenv, linuxKernel, linuxManualConfig, ... }:
linuxKernel.manualConfig {
  inherit lib stdenv;
  inherit (linuxKernel.kernels.linux_6_1) src version modDirVersion kernelPatches extraMakeFlags;
  configfile = ./configs/${stdenv.hostPlatform.linuxArch}-linux.config;
  config = {
    # DTB required to be set to true for nixpkgs kernel build to install dtbs into derivation
    DTB = stdenv.hostPlatform.system != "x86_64-linux";
    CONFIG_MODULES = "y";
  };
}
