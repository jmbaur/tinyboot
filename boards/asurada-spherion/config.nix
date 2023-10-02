{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "asurada-spherion") {
    platforms = [ "aarch64-linux" ];
    linux = {
      configFile = with pkgs.tinybootKernelPatches; lib.mkDefault (pkgs.concatText "asurada-spherion-kernel.config" [ generic aarch64 chromebook mediatek ]);
      dtbPattern = "mt8192-asurada-spherion*";
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
  };
}
