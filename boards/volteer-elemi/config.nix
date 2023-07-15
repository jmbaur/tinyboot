{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "volteer-elemi") {
    platforms = [ "x86_64-linux" ];
    linux = {
      configFile = lib.mkDefault (pkgs.concatText "volteer-elemi-kernel.config" [ ../generic-kernel.config ../x86_64-kernel.config ../chromebook-kernel.config ]);
      commandLine = [ "quiet" ];
    };
    coreboot = {
      configFile = lib.mkDefault ./coreboot.config;
      bootsplash = { enable = true; width = 1920; height = 1080; };
    };
    flashrom.extraArgs = lib.mkDefault [ "--ifd" "-i" "bios" ];
  };
}
