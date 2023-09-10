{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "poppy-atlas") {
    platforms = [ "x86_64-linux" ];
    linux = {
      configFile = with pkgs.tinybootKernelPatches; lib.mkDefault (pkgs.concatText "poppy-atlas-kernel.config" [ generic x86_64 chromebook ./kernel.config ]);
      commandLine = [ "quiet" ];
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
  };
}
