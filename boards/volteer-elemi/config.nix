{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "volteer-elemi") {
    platforms = [ "x86_64-linux" ];
    linux.configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "volteer-elemi-kernel.config" [ generic x86_64 chromebook ./kernel.config ]);
    coreboot.configFile = lib.mkDefault ./coreboot.config;
  };
}
