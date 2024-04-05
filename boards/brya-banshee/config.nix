{ pkgs, lib, ... }:
{
  platforms = [ "x86_64-linux" ];
  linux.configFile =
    with pkgs.tinybootKernelConfigs;
    lib.mkDefault (
      pkgs.concatText "brya-banshee-kernel.config" [
        generic
        video
        x86_64
        alderlake
        chromebook
      ]
    );
  coreboot = {
    # start=0x01800000 length=0x00800000 (upper 1/4)
    wpRange.start = "0x01800000";
    wpRange.length = "0x00800000";
    kconfig = with lib.kernel; {
      BOARD_GOOGLE_BANSHEE = yes;
      FMDFILE = freeform ./layout.fmd;
      VBOOT_NO_BOARD_SUPPORT = yes; # TODO(jared): figure out why this is needed
      VENDOR_GOOGLE = yes;
    };
  };
}
