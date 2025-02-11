{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (config.board == "fizz-fizz") {
    network = true;
    chromebook = true;
    linux = {
      consoles = [ "ttyS0,115200n8" ];
      kconfig = with lib.kernel; {
        NET_VENDOR_REALTEK = yes;
        R8169 = yes;
      };
      firmware = [
        (pkgs.runCommand "rtl-nic-firmware" { } ''
          mkdir -p $out/lib/firmware && cp -r ${pkgs.linux-firmware}/lib/firmware/rtl_nic $out/lib/firmware
        '')
      ];
    };
    coreboot.kconfig = with lib.kernel; {
      BOARD_GOOGLE_FIZZ = yes;
      FMDFILE = freeform ./layout.fmd;
      GENERIC_LINEAR_FRAMEBUFFER = yes;
      RUN_FSP_GOP = yes;
      VENDOR_GOOGLE = yes;
    };
  };
}
