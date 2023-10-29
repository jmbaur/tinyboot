{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "brya-banshee") {
    platforms = [ "x86_64-linux" ];
    linux.configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "brya-banshee-kernel.config" [ generic x86_64 chromebook ./kernel.config ]);
    coreboot.configFile = lib.mkDefault ./coreboot.config;
  };
}
