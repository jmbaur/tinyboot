{ pkgs, lib, stdenv, buildCoreboot, tinyboot-kernel, tinyboot-initramfs }:
let
  module = { ... }: {
    config._module.args = { inherit pkgs lib; };
    options.platforms = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    options.kernel = {
      configFile = lib.mkOption {
        type = lib.types.path;
      };
      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
    };
    options.coreboot = {
      configFile = lib.mkOption {
        type = lib.types.path;
      };
      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
    };
    options.tinyboot = {
      debug = lib.mkEnableOption "debug mode";
      tty = lib.mkOption {
        type = lib.types.str;
        default = "tty0";
      };
      extraInit = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
      extraInittab = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
    };
  };
in
lib.mapAttrs
  (board: _:
  let
    finalConfig = lib.evalModules { modules = [ module (import ./${board}/config.nix) ]; };
    tinybootExtraConfig = lib.attrByPath [ stdenv.hostPlatform.linuxArch ] "" {
      x86_64 = ''
        CONFIG_PAYLOAD_FILE="${tinyboot-kernel.override { inherit (finalConfig.config.kernel) configFile; }}/bzImage"
        CONFIG_LINUX_INITRD="${tinyboot-initramfs.override { inherit (finalConfig.config.tinyboot) debug tty extraInit extraInittab; }}/initrd"
      '';
      # TODO(jared): aarch64 fit images
    };
  in
  buildCoreboot {
    inherit board;
    inherit (finalConfig.config.coreboot) configFile;
    extraConfig = finalConfig.config.coreboot.extraConfig + tinybootExtraConfig;
    meta = { inherit (finalConfig.config) platforms; };
  })
  (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.))
