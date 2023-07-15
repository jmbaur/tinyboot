{ _pkgs, _lib }:
{ config, pkgs, lib, ... }:
let
  boards = lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./boards);
  buildFitImage = pkgs.callPackage ./fitimage { };
  inherit (config.coreboot.bootsplash) width height;
  bootsplash = pkgs.buildPackages.runCommand "bootsplash-${toString width}x${toString height}"
    { nativeBuildInputs = [ pkgs.buildPackages.imagemagick ]; }
    ''
      mkdir -p $out
      magick ${./boards/bootsplash.jpg} -resize ${toString width}x${toString height}\\! $out/bootsplash.jpg
    '';
  updateInitrd =
    let
      flashScript = pkgs.writeScript "flash-script" ''
        #!/bin/sh
        if flashrom \
          --write /update.rom \
          --programmer ${config.flashrom.programmer} \
          ${lib.escapeShellArgs config.flashrom.extraArgs}; then
          echo "flashing succeeded"
          sleep 2
        else
          echo "flashing failed"
          sleep 10
        fi
        reboot
      '';
    in
    pkgs.callPackage ./update-initramfs.nix {
      extraInittab = ''
        kmsg::once:/sbin/flash-update
      '';
      extraContents = [
        { object = config.build.firmware; symlink = "/update.rom"; }
        { object = "${config.flashrom.package}/bin/flashrom"; symlink = "/sbin/flashrom"; }
        { object = flashScript; symlink = "/sbin/flash-update"; }
      ];
    };
in
{
  imports = lib.mapAttrsToList (board: _: ./boards/${board}/config.nix) boards;
  options = with lib; {
    platforms = mkOption { type = types.listOf types.str; default = [ ]; };
    board = mkOption {
      type = types.nullOr (types.enum (mapAttrsToList (board: _: board) boards));
      default = null;
    };
    build = mkOption {
      default = { };
      type = types.submoduleWith {
        modules = [{ freeformType = with types; lazyAttrsOf (uniq unspecified); }];
      };
    };
    flashrom = {
      package = mkPackageOptionMD pkgs "flashrom-cros" { };
      programmer = mkOption { type = types.str; default = "internal"; };
      extraArgs = mkOption { type = types.listOf types.str; default = [ ]; };
    };
    linux = {
      basePackage = mkOption { type = types.package; default = pkgs.linux; };
      configFile = mkOption { type = types.path; };
      extraConfig = mkOption { type = types.lines; default = ""; };
      commandLine = mkOption { type = types.listOf types.str; default = [ ]; };
      dtb = mkOption { type = types.nullOr types.path; default = null; };
      dtbPattern = mkOption { type = types.nullOr types.str; default = null; };
    };
    coreboot = {
      extraArgs = mkOption { type = types.attrsOf types.anything; default = { }; };
      configFile = mkOption { type = types.path; };
      extraConfig = mkOption { type = types.lines; default = ""; };
      bootsplash = {
        enable = mkEnableOption "bootsplash";
        width = mkOption { type = types.int; default = 1024; };
        height = mkOption { type = types.int; default = 768; };
      };
    };
    verifiedBoot = {
      enable = mkEnableOption "verified boot";
      caCertificate = mkOption { type = types.path; };
      signingPublicKey = mkOption { type = types.path; };
      signingPrivateKey = mkOption { type = types.path; };
    };
    debug = mkEnableOption "debug mode";
    tinyboot = {
      ttys = mkOption { type = types.listOf types.str; default = [ "tty1" ]; };
      extraInit = mkOption { type = types.lines; default = ""; };
      extraInittab = mkOption { type = types.lines; default = ""; };
      nameservers = mkOption {
        type = types.listOf types.str;
        default = [ "8.8.8.8" "8.8.4.4" "2001:4860:4860::8888" "2001:4860:4860::8844" ];
      };
    };
  };
  config = {
    build = {
      initrd = pkgs.callPackage ./initramfs.nix {
        inherit (config.tinyboot) ttys nameservers;
        extraInittab = ''
          ::respawn:/sbin/tbootd --log-level=${if config.debug then "debug" else "info"}
        '' + config.tinyboot.extraInittab;
        extraInit = ''
          mkdir -p /home/tinyuser /tmp/tinyboot
          chown -R tinyuser:tinygroup /home/tinyuser /tmp/tinyboot
          cat /etc/resolv.conf.static >/etc/resolv.conf
          cat /etc/ima/policy.conf >/sys/kernel/security/ima/policy
        '' + config.tinyboot.extraInit;
        imaAppraise = config.verifiedBoot.enable;
        extraContents = lib.optional config.verifiedBoot.enable {
          object = config.verifiedBoot.signingPublicKey;
          symlink = "/etc/keys/x509_ima.der";
        };
      };
      linux = (pkgs.callPackage ./linux.nix { inherit (config.linux) basePackage configFile extraConfig; }).overrideAttrs (_: {
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
      fitImage = buildFitImage {
        inherit (config) board;
        inherit (config.build) linux initrd;
        inherit (config.linux) dtb dtbPattern;
      };
      coreboot = pkgs.buildCoreboot {
        inherit (config) board;
        inherit (config.coreboot) configFile extraConfig extraArgs;
      };
      firmware = pkgs.runCommand "tinyboot-${config.build.coreboot.name}"
        {
          nativeBuildInputs = with pkgs.buildPackages; [ coreboot-utils ];
          passthru = { inherit (config.build) linux initrd coreboot; };
          meta.platforms = config.platforms;
        }
        ''
          dd if=${config.build.coreboot}/coreboot.rom of=$out
          ${lib.optionalString config.coreboot.bootsplash.enable ''
          cbfstool $out add -t bootsplash -n bootsplash.jpg -f ${bootsplash}/bootsplash.jpg
          ''}
          ${if pkgs.stdenv.hostPlatform.linuxArch == "x86_64" then ''
          cbfstool $out add-payload \
            -n fallback/payload \
            -f ${config.build.linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target} \
            -I ${config.build.initrd}/initrd
          '' else if pkgs.stdenv.hostPlatform.linuxArch == "arm64" then ''
          cbfstool $out add -f ${config.build.fitImage}/uImage -n fallback/payload -t fit_payload
          '' else throw "Unsupported architecture"}
        '';
      updateScript = pkgs.writeShellScriptBin "update-firmware" ''
        kexec -l ${config.build.linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target} \
          --initrd=${updateInitrd}/initrd \
          --command-line="${lib.concatStringsSep " " (map (tty: "console=/dev/${tty}") config.tinyboot.ttys)}"
        systemctl kexec
      '';
    };
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
