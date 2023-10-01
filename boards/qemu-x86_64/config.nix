{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "qemu-x86_64") {
    platforms = [ "x86_64-linux" ];
    coreboot.configFile = lib.mkDefault ./coreboot.config;
    linux.configFile = with pkgs.tinybootKernelPatches; lib.mkDefault (pkgs.concatText "qemu-x86_64-kernel.config" [ generic qemu x86_64 ]);
    linux.commandLine = [ "quiet" ];
    debug = lib.mkDefault true;
    tinyboot.ttys = lib.mkDefault [ "ttyS0" ];
  };
}
