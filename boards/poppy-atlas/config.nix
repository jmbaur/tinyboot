{ config, pkgs, lib, kconfig, ... }: {
  config = lib.mkIf (config.board == "poppy-atlas") {
    platforms = [ "x86_64-linux" ];
    linux.configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "poppy-atlas-kernel.config" [ generic video x86_64 chromebook ./kernel.config ]);
    coreboot.kconfig = with kconfig; {
      VBOOT_SLOTS_RW_AB = no;
      VBOOT_SLOTS_RW_A = yes;
      BOARD_GOOGLE_ATLAS = yes;
      FMDFILE = freeform ./layout.fmd;
      VENDOR_GOOGLE = yes;
    };
  };
}
