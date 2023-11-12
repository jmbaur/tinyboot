{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "fizz-fizz") {
    platforms = [ "x86_64-linux" ];
    tinyboot.tty = lib.mkDefault "ttyS0";
    linux = {
      configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "fizz-fizz-kernel.config" [ generic x86_64 network chromebook ./kernel.config ]);
      firmware = [{ dir = "rtl_nic"; pattern = "rtl8168*"; }];
    };
    coreboot.kconfig = with lib.kernel; {
      VBOOT_SLOTS_RW_AB = no;
      VBOOT_SLOTS_RW_A = yes;
      BOARD_GOOGLE_FIZZ = yes;
      FMDFILE = freeform ./layout.fmd;
      VENDOR_GOOGLE = yes;
    };
  };
}
