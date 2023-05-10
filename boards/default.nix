{ pkgs, lib, stdenv, runCommand, coreboot-utils, buildCoreboot, tinyboot-kernel, tinyboot-initramfs }:
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
      commandLine = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = [];
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
      measuredBoot = lib.mkEnableOption "measured boot";
      verifiedBoot = lib.mkEnableOption "verified boot";
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
    coreboot = buildCoreboot {
      inherit board;
      inherit (finalConfig.config.coreboot) configFile extraConfig;
      meta = { inherit (finalConfig.config) platforms; };
    };
    linux = tinyboot-kernel.override { inherit (finalConfig.config.kernel) configFile; };
    initrd = tinyboot-initramfs.override { inherit (finalConfig.config.tinyboot) measuredBoot verifiedBoot debug tty extraInit extraInittab; };
  in
  # TODO(jared): aarch64 fit images
  (runCommand "tinyboot-${coreboot.name}" { nativeBuildInputs = [ coreboot-utils ]; } ''
    mkdir -p $out
    dd if=${coreboot}/coreboot.rom of=$out/coreboot.rom
    cbfstool $out/coreboot.rom add-payload \
      -n fallback/payload \
      -f ${linux}/${stdenv.hostPlatform.linux-kernel.target} \
      -I ${initrd}/initrd \
      -C '${toString finalConfig.config.kernel.commandLine}'
  ''))
    (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.))
