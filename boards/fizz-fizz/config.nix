{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "fizz-fizz") {
    platforms = [ "x86_64-linux" ];
    tinyboot.tty = lib.mkDefault "ttyS0";
    linux = {
      configFile = with pkgs.tinybootKernelPatches; lib.mkDefault (pkgs.concatText "fizz-fizz-kernel.config" [ generic x86_64 chromebook ./kernel.config ]);
      commandLine = [ "quiet" ];
      firmware = pkgs.runCommand "fizz-firmware" { } ''
        mkdir -p $out; cp -r ${pkgs.linux-firmware}/lib/firmware/rtl_nic $out/rtl_nic
      '';
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
  };
}
