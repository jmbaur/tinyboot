{ pkgs, lib, stdenv, buildPackages, buildCoreboot, buildFitImage }:
let
  module = { ... }: {
    config._module.args = { inherit pkgs lib; };
    options.platforms = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    options.kernel = {
      basePackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.linuxKernel.kernels.linux_6_1;
      };
      configFile = lib.mkOption {
        type = lib.types.path;
      };
      commandLine = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = [ ];
      };
      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
      dtb = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
      };
      dtbPattern = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
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
    linux = pkgs.callPackage ../kernel.nix { inherit (finalConfig.config.kernel) basePackage configFile; };
    initrd = pkgs.callPackage ../initramfs.nix { inherit (finalConfig.config.tinyboot) measuredBoot verifiedBoot debug tty extraInit extraInittab; };
    fitImage = buildFitImage { inherit board linux initrd; inherit (finalConfig.config.kernel) dtb dtbPattern; };
  in
  (buildPackages.runCommand "tinyboot-${coreboot.name}"
  { nativeBuildInputs = with buildPackages; [ coreboot-utils ]; }
    ''
      mkdir -p $out
      dd if=${coreboot}/coreboot.rom of=$out/coreboot.rom
      ${if stdenv.hostPlatform.linuxArch == "x86_64" then ''
      cbfstool $out/coreboot.rom add-payload \
        -n fallback/payload \
        -f ${linux}/${stdenv.hostPlatform.linux-kernel.target} \
        -I ${initrd}/initrd \
        -C '${toString finalConfig.config.kernel.commandLine}'
        '' else if stdenv.hostPlatform.linuxArch == "arm64" then ''
      cbfstool $out/coreboot.rom add -f ${fitImage}/uImage -n fallback/payload -t fit_payload
        '' else throw "Unsupported architecture"}
    ''))
  (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.))
