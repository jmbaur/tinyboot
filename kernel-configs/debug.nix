{ config, lib, ... }:
let
  efi = !config.coreboot.enable;
in
{
  linux.kconfig = lib.mkIf config.debug (
    with lib.kernel;
    {
      BUG = yes;
      DEBUG_BUGVERBOSE = yes;
      DEBUG_KERNEL = yes;
      DEBUG_MUTEXES = yes;
      DYNAMIC_DEBUG = yes;
      EFI_EARLYCON = lib.mkIf efi yes;
      FTRACE = yes;
      GENERIC_BUG = yes;
      IKCONFIG = yes;
      KALLSYMS_ALL = yes;
      SERIAL_EARLYCON = yes;
      SYMBOLIC_ERRNAME = yes;
    }
  );
}
