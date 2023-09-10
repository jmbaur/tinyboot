{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "asurada-spherion") {
    platforms = [ "aarch64-linux" ];
    linux = {
      basePackage = pkgs.linuxKernel.kernels.linux_6_5;
      configFile = with pkgs.tinybootKernelPatches; lib.mkDefault (pkgs.concatText "asurada-spherion-kernel.config" [ generic aarch64 chromebook mediatek ]);
      commandLine = [ "quiet" ];
      dtbPattern = "mt8192-asurada-spherion*";
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
  };
}
