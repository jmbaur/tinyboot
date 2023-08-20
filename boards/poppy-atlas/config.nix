{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "poppy-atlas") {
    platforms = [ "x86_64-linux" ];
    linux = {
      configFile = lib.mkDefault (pkgs.concatText "poppy-atlas-kernel.config" [ ../generic-kernel.config ../x86_64-kernel.config ../chromebook-kernel.config ./kernel.config ]);
      commandLine = [ "quiet" ];
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
  };
}
