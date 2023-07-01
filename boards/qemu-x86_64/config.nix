{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "qemu-x86_64") {
    platforms = [ "x86_64-linux" ];
    coreboot.configFile = lib.mkDefault ./coreboot.config;
    linux.configFile = lib.mkDefault (pkgs.concatText "qemu-x86_64-kernel.config" [ ../generic-kernel.config ../qemu-kernel.config ../x86_64-kernel.config ./kernel.config ]);
    debug = lib.mkDefault true;
    verifiedBoot = {
      enable = lib.mkDefault true;
      caCertificate = ../../test/keys/x509_ima.pem;
      signingPublicKey = lib.mkDefault ../../test/keys/x509_ima.der;
      signingPrivateKey = lib.mkDefault ../../test/keys/privkey_ima.pem;
    };
    tinyboot.ttys = lib.mkDefault [ "ttyS0" ];
  };
}
