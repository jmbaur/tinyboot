{ lib, ... }:
{
  network = true;
  chromebook = true;
  linux = {
    kconfig = with lib.kernel; {
      NET_VENDOR_REALTEK = yes;
      R8169 = yes;
    };
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
    VENDOR_GOOGLE = yes;
  };
}
