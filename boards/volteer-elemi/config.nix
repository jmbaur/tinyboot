{ pkgs, ... }: {
  platforms = [ "x86_64-linux" ];
  kernel = {
    configFile = pkgs.concatText "volteer-elemi-kernel.config" [ ../generic-kernel.config ../x86_64-kernel.config ../chromebook-kernel.config ];
    commandLine = [ "console=ttyS0" "console=tty0" ];
  };
  tinyboot.measuredBoot.enable = true;
  coreboot.configFile = ./coreboot.config;
}
