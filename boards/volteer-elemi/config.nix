{ pkgs, lib, ... }: {
  platforms = [ "x86_64-linux" ];
  kernel.configFile = lib.mkDefault (pkgs.concatText "volteer-elemi-kernel.config" [ ../generic-kernel.config ../x86_64-kernel.config ../chromebook-kernel.config ]);
  tinyboot.measuredBoot.enable = lib.mkDefault true;
  coreboot.configFile = lib.mkDefault ./coreboot.config;
}
