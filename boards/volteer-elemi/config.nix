{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "volteer-elemi") {
    platforms = [ "x86_64-linux" ];
    linux = {
      configFile = lib.mkDefault (pkgs.concatText "volteer-elemi-kernel.config" [ ../generic-kernel.config ../x86_64-kernel.config ../chromebook-kernel.config ./kernel.config ]);
      commandLine = [ "quiet" ];
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
    flashrom = {
      extraArgs = lib.mkDefault [ "-i" "RW_SECTION_A" ];
      package = (pkgs.flashrom-cros.overrideAttrs (old: {
        buildFlags = [ "CFLAGS=-Wno-unused-variable" ];
        src = pkgs.fetchgit {
          url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
          branchName = "factory-volteer-13600.B";
          rev = "a33454948c1064b3ea0f3f376c7ba4a98a435497";
          hash = "sha256-cjJRzuJMXmmxwCTn2nGqAAtgSG9RdSZ1JH4AngDVoWc=";
        };
      })).override { useMeson = false; };
    };
  };
}
