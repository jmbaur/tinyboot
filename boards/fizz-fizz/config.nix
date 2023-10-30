{ config, pkgs, lib, kconfig, ... }: {
  config = lib.mkIf (config.board == "fizz-fizz") {
    platforms = [ "x86_64-linux" ];
    tinyboot.tty = lib.mkDefault "ttyS0";
    linux = {
      configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "fizz-fizz-kernel.config" [ generic x86_64 chromebook ./kernel.config ]);
      firmware = pkgs.runCommand "fizz-firmware" { } ''
        mkdir -p $out; cp -r ${pkgs.linux-firmware}/lib/firmware/rtl_nic $out/rtl_nic
      '';
    };
    coreboot.kconfig = with kconfig; {
      VENDOR_GOOGLE = yes;
      BOARD_GOOGLE_FIZZ = yes;
      FMDFILE = freeform ./layout.fmd;
    };
  };
}
