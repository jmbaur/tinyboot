{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "kukui-jacuzzi-fennel") {
    platforms = [ "aarch64-linux" ];
    linux = {
      basePackage = pkgs.linuxKernel.kernels.linux_6_4;
      configFile = lib.mkDefault (pkgs.concatText "kukui-jacuzzi-fennel-kernel.config" [ ../generic-kernel.config ../aarch64-kernel.config ../chromebook-kernel.config ../mediatek-kernel.config ]);
      commandLine = [ "console=ttyS0" ];
      dtbPattern = "mt8183-kukui-jacuzzi-fennel*";
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
    flashrom.extraArgs = lib.mkDefault [ "-i" "RW_SECTION_A" ];
  };
}
