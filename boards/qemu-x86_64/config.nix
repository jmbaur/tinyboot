{ pkgs, ... }: {
  platforms = [ "x86_64-linux" ];
  kernel = {
    configFile = pkgs.concatText "qemu-x86_64-kernel.config" [ ../generic-kernel.config ../qemu-kernel.config ../x86_64-kernel.config ./kernel.config ];
    commandLine = ["console=ttyS0"];
  };
  coreboot.configFile = ./coreboot.config;
  tinyboot = {
    debug = true;
    tty = "ttyS0";
  };
}
