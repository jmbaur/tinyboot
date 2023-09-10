{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "volteer-elemi") {
    platforms = [ "x86_64-linux" ];
    linux = {
      configFile = with pkgs.tinybootKernelPatches; lib.mkDefault (pkgs.concatText "volteer-elemi-kernel.config" [ generic x86_64 chromebook ./kernel.config ]);
      commandLine = [ "quiet" ];
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
  };
}
