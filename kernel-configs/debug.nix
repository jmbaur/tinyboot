{ config, lib, ... }:
let
  efi = !config.coreboot.enable;
in
{
  linux.kconfig = lib.mkIf config.debug (
    with lib.kernel;
    {
      BUG = yes;
      SERIAL_EARLYCON = yes;
      EFI_EARLYCON = lib.mkIf efi yes;
      DEBUG_BUGVERBOSE = yes;
      DEBUG_KERNEL = yes;
      DEBUG_MUTEXES = yes;
      DYNAMIC_DEBUG = yes;
      FTRACE = yes;
      GENERIC_BUG = yes;
      KALLSYMS = yes;
      SYMBOLIC_ERRNAME = yes;
    }
  );
}
