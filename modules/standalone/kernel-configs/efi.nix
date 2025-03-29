{ config, lib, ... }:
{
  linux.kconfig = lib.mkIf config.efi {
    EFI = lib.kernel.yes;
    EFI_STUB = lib.kernel.yes;
    EFI_EARLYCON = lib.kernel.yes;
    FB_EFI = lib.kernel.yes;
    EFIVAR_FS = lib.kernel.yes;
  };
}
