{ pkgs, lib, ... }: {
  platforms = [ "x86_64-linux" ];
  coreboot.configFile = lib.mkDefault ./coreboot.config;
  kernel = {
    configFile = lib.mkDefault (pkgs.concatText "qemu-x86_64-kernel.config" [ ../generic-kernel.config ../qemu-kernel.config ../x86_64-kernel.config ./kernel.config ]);
    commandLine = lib.mkDefault [ "console=ttyS0" ];
  };
  tinyboot = {
    debug = lib.mkDefault true;
    tty = lib.mkDefault "ttyS0";
    verifiedBoot = {
      enable = lib.mkDefault true;
      publicKey = lib.mkDefault ../../test/keys/pubkey;
    };
    measuredBoot.enable = lib.mkDefault false;
  };
}
