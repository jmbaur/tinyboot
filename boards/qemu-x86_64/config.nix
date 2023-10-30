{ config, pkgs, lib, kconfig, ... }: {
  imports = [ ../../qemu.nix ];
  config = lib.mkIf (config.board == "qemu-x86_64") {
    platforms = [ "x86_64-linux" ];
    qemu.flags = [ "-M" "q35" "-device" "tpm-tis,tpmdev=tpm0" ];
    linux.configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "qemu-x86_64-kernel.config" [ generic qemu x86_64 ]);
    loglevel = lib.mkDefault "debug";
    tinyboot.tty = lib.mkDefault "ttyS0";
    coreboot.kconfig = with kconfig; {
      BOARD_EMULATION_QEMU_X86_Q35 = yes;
      VENDOR_EMULATION = yes;
      FMDFILE = freeform ./layout.fmd;
    };
  };
}
