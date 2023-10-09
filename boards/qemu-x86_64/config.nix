{ config, pkgs, lib, ... }: {
  imports = [ ../../qemu.nix ];
  config = lib.mkIf (config.board == "qemu-x86_64") {
    platforms = [ "x86_64-linux" ];
    qemu.flags = [ "-M" "q35" "-device" "tpm-tis,tpmdev=tpm0" ];
    coreboot.configFile = lib.mkDefault ./coreboot.config;
    linux.configFile = with pkgs.tinybootKernelPatches; lib.mkDefault (pkgs.concatText "qemu-x86_64-kernel.config" [ generic qemu x86_64 ]);
    loglevel = lib.mkDefault "info";
    tinyboot.tty = lib.mkDefault "ttyS0";
  };
}
