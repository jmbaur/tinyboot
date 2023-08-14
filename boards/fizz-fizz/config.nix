{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "fizz-fizz") {
    platforms = [ "x86_64-linux" ];
    tinyboot.ttys = lib.mkDefault [ "ttyS0" "tty1" ];
    linux = {
      configFile = lib.mkDefault (pkgs.concatText "fizz-fizz-kernel.config" [ ../generic-kernel.config ../x86_64-kernel.config ../chromebook-kernel.config ./kernel.config ]);
      commandLine = [ "quiet" ];
      firmware = pkgs.runCommand "fizz-firmware" { } ''
        mkdir -p $out; cp -r ${pkgs.linux-firmware}/lib/firmware/rtl_nic $out/rtl_nic
      '';
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
  };
}
