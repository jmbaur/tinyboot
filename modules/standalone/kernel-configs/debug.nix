{ config, lib, ... }:
{
  linux.kconfig = lib.mkIf config.debug (
    with lib.kernel;
    {
      BUG = yes;
      DEBUG_BUGVERBOSE = yes;
      DEBUG_KERNEL = yes;
      DEBUG_MUTEXES = yes;
      DYNAMIC_DEBUG = yes;
      FTRACE = yes;
      GENERIC_BUG = yes;
      IKCONFIG = yes;
      KALLSYMS = yes;
      KALLSYMS_ALL = yes;
      SERIAL_EARLYCON = yes;
      SYMBOLIC_ERRNAME = yes;
    }
  );
}
