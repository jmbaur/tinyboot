{ pkgs, lib, ... }: {
  platforms = [ "x86_64-linux" ];
  linux = {
    configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "fizz-fizz-kernel.config" [ generic x86_64 network chromebook ./kernel.config ]);
    firmware = [{ dir = "rtl_nic"; pattern = "rtl8168*"; }];
  };
  coreboot.kconfig = with lib.kernel; {
    BOARD_GOOGLE_FIZZ = yes;
    FMDFILE = freeform ./layout.fmd;
    VENDOR_GOOGLE = yes;
  };
}
