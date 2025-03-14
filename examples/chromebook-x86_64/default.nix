{ lib, ... }:
{
  hostPlatform = "x86_64-linux";
  chromebook = true;
  video = true;
  linux.consoles = [ "ttyS0,115200n8" ];
  linux.kconfig = with lib.kernel; {
    PINCTRL_ALDERLAKE = yes;
    PINCTRL_TIGERLAKE = yes;
  };
}
