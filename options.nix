{ _pkgs, _lib }:
{ config, pkgs, lib, ... }:
let
  boards = lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./boards);
  buildFitImage = pkgs.callPackage ./fitimage { };
  buildCoreboot = pkgs.callPackage ./coreboot.nix { flashrom = pkgs.callPackage ./flashrom.nix { }; };
in
{
  imports = lib.mapAttrsToList (board: _: ./boards/${board}/config.nix) boards;
  options = {
    board = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum (lib.mapAttrsToList (board: _: board) boards));
      default = null;
    };
    build = {
      initrd = lib.mkOption {
        internal = true;
        readOnly = true;
        default = pkgs.callPackage ./initramfs.nix {
          inherit (config) debug;
          inherit (config.tinyboot) ttys nameservers extraInit extraInittab;
          imaAppraise = config.verifiedBoot.enable;
          extraContents = lib.optional config.verifiedBoot.enable {
            object = config.verifiedBoot.signingPublicKey;
            symlink = "/etc/keys/x509_ima.der";
          };
        };
      };
      linux = lib.mkOption {
        internal = true;
        readOnly = true;
        default = (pkgs.callPackage ./linux.nix { inherit (config.linux) basePackage configFile extraConfig; }).overrideAttrs (_: {
          preConfigure = lib.optionalString config.verifiedBoot.enable ''
            mkdir tinyboot; cp ${config.verifiedBoot.caCertificate} tinyboot/ca.pem
          '';
          postInstall = lib.optionalString config.debug ''
            cp .config $out/config
            cp vmlinux $out/vmlinux
          '' + lib.optionalString config.verifiedBoot.enable ''
            install -Dm755 -t "$out/bin" scripts/sign-file
          '';
        });
      };
      fitImage = lib.mkOption {
        internal = true;
        readOnly = true;
        default = buildFitImage {
          inherit (config) board;
          inherit (config.build) linux initrd;
          inherit (config.linux) dtb dtbPattern;
        };
      };
      coreboot = lib.mkOption {
        internal = true;
        readOnly = true;
        default = buildCoreboot {
          inherit (config) board;
          inherit (config.coreboot) configFile extraConfig extraArgs;
        };
      };
      firmware = lib.mkOption {
        internal = true;
        readOnly = true;
        default = pkgs.runCommand "tinyboot-${config.build.coreboot.name}"
          {
            nativeBuildInputs = with pkgs.buildPackages; [ coreboot-utils ];
            passthru = { inherit (config.build) linux initrd coreboot; };
            meta.platforms = config.platforms;
          }
          ''
            mkdir -p $out
            dd if=${config.build.coreboot}/coreboot.rom of=$out/coreboot.rom
            ${if pkgs.stdenv.hostPlatform.linuxArch == "x86_64" then ''
            cbfstool $out/coreboot.rom add-payload \
              -n fallback/payload \
              -f ${config.build.linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target} \
              -I ${config.build.initrd}/initrd
            '' else if pkgs.stdenv.hostPlatform.linuxArch == "arm64" then ''
            cbfstool $out/coreboot.rom add -f ${config.build.fitImage}/uImage -n fallback/payload -t fit_payload
            '' else throw "Unsupported architecture"}
          '';
      };
    };
    platforms = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    linux = {
      basePackage = lib.mkOption { type = lib.types.package; default = pkgs.linux; };
      configFile = lib.mkOption { type = lib.types.path; };
      extraConfig = lib.mkOption { type = lib.types.lines; default = ""; };
      commandLine = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      dtb = lib.mkOption { type = lib.types.nullOr lib.types.path; default = null; };
      dtbPattern = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
    };
    coreboot = {
      extraArgs = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      configFile = lib.mkOption { type = lib.types.path; };
      extraConfig = lib.mkOption { type = lib.types.lines; default = ""; };
    };
    verifiedBoot = {
      enable = lib.mkEnableOption "verified boot";
      caCertificate = lib.mkOption { type = lib.types.path; };
      signingPublicKey = lib.mkOption { type = lib.types.path; };
      signingPrivateKey = lib.mkOption { type = lib.types.path; };
    };
    debug = lib.mkEnableOption "debug mode";
    tinyboot = {
      ttys = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ "tty1" ]; };
      extraInit = lib.mkOption { type = lib.types.lines; default = ""; };
      extraInittab = lib.mkOption { type = lib.types.lines; default = ""; };
      nameservers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "8.8.8.8" "8.8.4.4" "2001:4860:4860::8888" "2001:4860:4860::8844" ];
      };
    };
  };
  config = {
    _module.args = { pkgs = _pkgs; lib = _lib; };
    linux.commandLine = lib.optional config.debug "debug" ++ [ "lsm=integrity" "ima_appraise=enforce" ];
    linux.extraConfig = ''
      CONFIG_CMDLINE="${toString config.linux.commandLine}"
    '' + (lib.optionalString config.debug ''
      CONFIG_DEBUG_DRIVER=y
      CONFIG_DEBUG_INFO_DWARF5=y
      CONFIG_DEBUG_KERNEL=y
      CONFIG_DYNAMIC_DEBUG=y
    '') + (lib.optionalString config.verifiedBoot.enable ''
      CONFIG_SYSTEM_TRUSTED_KEYS="tinyboot/ca.pem"
      CONFIG_IMA_LOAD_X509=y
      CONFIG_IMA_X509_PATH="/etc/keys/x509_ima.der"
    '');
  };
}
