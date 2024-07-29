{ config, lib, ... }:
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
      # https://github.com/torvalds/linux/blob/8400291e289ee6b2bf9779ff1c83a291501f017b/drivers/net/ethernet/realtek/r8169_main.c#L38
      firmware = [
        {
          dir = "rtl_nic";
          pattern = "rtl8168*";
        }
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
