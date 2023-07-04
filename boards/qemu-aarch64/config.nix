{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "qemu-aarch64") {
    platforms = [ "aarch64-linux" ];
    linux = {
      configFile = lib.mkDefault (pkgs.concatText "qemu-aarch64-kernel.config" [ ../generic-kernel.config ../aarch64-kernel.config ../qemu-kernel.config ./kernel.config ]);
      dtb = lib.mkDefault (pkgs.buildPackages.runCommand "qemu-aarch64.dtb" { depsBuildBuild = [ pkgs.pkgsBuildBuild.qemu ]; } ''
        qemu-system-aarch64 -M virt,secure=on,dumpdtb=$out -cpu cortex-a53 -m 2G -smp 2 -nographic
      '');
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
    debug = lib.mkDefault true;
    verifiedBoot = {
      enable = lib.mkDefault true;
      caCertificate = ../../test/keys/x509_ima.pem;
      signingPublicKey = lib.mkDefault ../../test/keys/x509_ima.der;
      signingPrivateKey = lib.mkDefault ../../test/keys/privkey_ima.pem;
    };
    tinyboot.ttys = lib.mkDefault [ "ttyAMA0" ];
  };
}
