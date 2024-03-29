{ pkgs, lib, ... }: {
  platforms = [ "x86_64-linux" ];
  linux.configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "qemu-x86_64-kernel.config" [ generic debug network qemu x86_64 video ./kernel.config ]);
  coreboot.kconfig = with lib.kernel; {
    BOARD_EMULATION_QEMU_X86_Q35 = yes;
    VENDOR_EMULATION = yes;
    FMDFILE = freeform ./layout.fmd;
  };
}
