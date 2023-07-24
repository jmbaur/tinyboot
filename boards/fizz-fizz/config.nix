{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "fizz-fizz") {
    platforms = [ "x86_64-linux" ];
    tinyboot.ttys = lib.mkDefault [ "ttyS0" "tty1" ];
    linux = {
      configFile = lib.mkDefault (pkgs.concatText "fizz-fizz-kernel.config" [ ../generic-kernel.config ../x86_64-kernel.config ../chromebook-kernel.config ]);
      commandLine = [ "quiet" ];
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
    flashrom.extraArgs = lib.mkDefault [ "-i" "RW_SECTION_A" ];
  };
}
