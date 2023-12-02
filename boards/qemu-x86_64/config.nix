{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "qemu-x86_64") {
    platforms = [ "x86_64-linux" ];
    qemu.enable = true;
    qemu.flags = [ "-M" "q35" "-device" "tpm-tis,tpmdev=tpm0" ];
    linux.configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "qemu-x86_64-kernel.config" [ generic debug network qemu x86_64 video ./kernel.config ]);
    tinyboot.tty = lib.mkDefault "tty1";
    coreboot.kconfig = with lib.kernel; {
      BOARD_EMULATION_QEMU_X86_Q35 = yes;
      VENDOR_EMULATION = yes;
      FMDFILE = freeform ./layout.fmd;
    };
  };
}
