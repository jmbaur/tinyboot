{ pkgs, ... }: {
  platforms = [ "x86_64-linux" ];
  coreboot.configFile = ./coreboot.config;
  kernel = {
    configFile = pkgs.concatText "qemu-x86_64-kernel.config" [ ../generic-kernel.config ../qemu-kernel.config ../x86_64-kernel.config ./kernel.config ];
    commandLine = [ "console=ttyS0" ];
  };
  tinyboot = {
    debug = true;
    tty = "ttyS0";
    verifiedBoot = {
      enable = true;
      publicKey = ../../test/keys/pubkey;
    };
    measuredBoot.enable = false;
  };
}
