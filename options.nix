{ _pkgs, _lib }:
{ config, pkgs, lib, ... }:
let
  boards = lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./boards);
  buildFitImage = pkgs.callPackage ./fitimage { };
  updateInitrd =
    let
      flashScript = pkgs.writeScript "flash-script" ''
        #!/bin/sh
        logger "started flashing new firmware"
        if flashrom \
          --write /update.rom \
          --programmer ${config.flashrom.programmer} \
          ${lib.escapeShellArgs config.flashrom.extraArgs}; then
          logger "flashing succeeded"
          sleep 2
        else
          logger "flashing failed"
          sleep 10
        fi
        reboot
      '';
    in
    pkgs.callPackage ./initramfs.nix {
      extraInittab = ''
        ::once:/sbin/flash-update
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
      package = mkPackageOptionMD pkgs "flashrom" { };
      programmer = mkOption { type = types.str; default = "internal"; };
      layout = mkOption { type = types.nullOr types.lines; default = null; };
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
    };
    verifiedBoot = {
      requiredSystemFeatures = mkOption { type = types.listOf types.str; default = [ ]; };
      # TODO(jared): integrate IMA and vboot keys (they can come from the same RSA key?)
      caCertificate = mkOption { type = types.path; default = ./test/keys/x509_ima.pem; };
      signingPublicKey = mkOption { type = types.path; default = ./test/keys/x509_ima.der; };
      signingPrivateKey = mkOption { type = types.path; default = ./test/keys/privkey_ima.pem; };
      vbootRootKey = mkOption { type = types.path; default = "${pkgs.vboot_reference}/share/vboot/devkeys/root_key.vbpubk"; };
      vbootRecoveryKey = mkOption { type = types.path; default = "${pkgs.vboot_reference}/share/vboot/devkeys/recovery_key.vbpubk"; };
      vbootFirmwarePrivkey = mkOption { type = types.path; default = "${pkgs.vboot_reference}/share/vboot/devkeys/firmware_data_key.vbprivk"; };
      vbootKeyblock = mkOption { type = types.path; default = "${pkgs.vboot_reference}/share/vboot/devkeys/firmware.keyblock"; };
      vbootKernelKey = mkOption { type = types.path; default = "${pkgs.vboot_reference}/share/vboot/devkeys/kernel_subkey.vbpubk"; };
      vbootKeyblockVersion = mkOption { type = types.str; default = "1"; };
      vbootKeyblockPreambleFlags = mkOption { type = types.str; default = "0x0"; };
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
    _module.args = { pkgs = _pkgs; lib = _lib; };

    tinyboot.extraInit = ''
      mkdir -p /home/tinyuser /tmp/tinyboot
      chown -R tinyuser:tinygroup /home/tinyuser /tmp/tinyboot
      cat /etc/resolv.conf.static >/etc/resolv.conf
      cat /etc/ima/policy.conf >/sys/kernel/security/ima/policy
    '';
    tinyboot.extraInittab = ''
      ::respawn:/sbin/tbootd --log-level=${if config.debug then "debug" else "info"}
    '' + (lib.concatLines (map (tty: "${tty}::respawn:/sbin/tbootui") config.tinyboot.ttys));

    linux.commandLine = lib.optional config.debug "debug" ++ [ "lsm=integrity" "ima_appraise=enforce" ];
    linux.extraConfig = ''
      CONFIG_CMDLINE="${toString config.linux.commandLine}"
      CONFIG_SYSTEM_TRUSTED_KEYS="tinyboot/ca.pem"
      CONFIG_IMA_LOAD_X509=y
      CONFIG_IMA_X509_PATH="/etc/keys/x509_ima.der"
    '' + (lib.optionalString config.debug ''
      CONFIG_DEBUG_DRIVER=y
      CONFIG_DEBUG_INFO_DWARF5=y
      CONFIG_DEBUG_KERNEL=y
      CONFIG_DYNAMIC_DEBUG=y
    '');

    coreboot.extraConfig = ''
      CONFIG_VBOOT_ROOT_KEY="${config.verifiedBoot.vbootRootKey}"
      CONFIG_VBOOT_RECOVERY_KEY="${config.verifiedBoot.vbootRecoveryKey}"
      CONFIG_VBOOT_FIRMWARE_PRIVKEY="${config.verifiedBoot.vbootFirmwarePrivkey}"
      CONFIG_VBOOT_KERNEL_KEY="${config.verifiedBoot.vbootKernelKey}"
      CONFIG_VBOOT_KEYBLOCK="${config.verifiedBoot.vbootKeyblock}"
      CONFIG_VBOOT_KEYBLOCK_VERSION=${config.verifiedBoot.vbootKeyblockVersion}
      CONFIG_VBOOT_KEYBLOCK_PREAMBLE_FLAGS=${config.verifiedBoot.vbootKeyblockPreambleFlags}
    '';

    build = {
      initrd = pkgs.callPackage ./initramfs.nix {
        inherit (config.tinyboot) extraInit extraInittab;
        extraContents =
          let
            staticResolvConf = pkgs.writeText "resolv.conf.static" (lib.concatLines (map (n: "nameserver ${n}") config.tinyboot.nameservers));
            imaPolicy = pkgs.substituteAll {
              name = "ima_policy.conf";
              src = ./etc/ima_policy.conf.in;
              extraPolicy = ''
                appraise func=KEXEC_KERNEL_CHECK appraise_type=imasig|modsig
                appraise func=KEXEC_INITRAMFS_CHECK appraise_type=imasig|modsig
              '';
            };
          in
          [
            { object = "${pkgs.tinyboot}/bin"; symlink = "/sbin"; }
            { object = ./etc/group; symlink = "/etc/group"; }
            { object = ./etc/mdev.conf; symlink = "/etc/mdev.conf"; }
            { object = ./etc/passwd; symlink = "/etc/passwd"; }
            { object = staticResolvConf; symlink = "/etc/resolv.conf.static"; }
            { object = imaPolicy; symlink = "/etc/ima/policy.conf"; }
            { object = config.verifiedBoot.signingPublicKey; symlink = "/etc/keys/x509_ima.der"; }
          ];
      };
      linux = (pkgs.callPackage ./linux.nix { inherit (config.linux) basePackage configFile extraConfig; }).overrideAttrs (_: {
        preConfigure = ''
          mkdir tinyboot; cp ${config.verifiedBoot.caCertificate} tinyboot/ca.pem
        '';
        postInstall = ''
          install -Dm755 -t "$out/bin" scripts/sign-file
        '' + lib.optionalString config.debug ''
          cp .config $out/config
          cp vmlinux $out/vmlinux
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
          inherit (config.verifiedBoot) requiredSystemFeatures;
          nativeBuildInputs = with pkgs.buildPackages; [ coreboot-utils vboot_reference ];
          passthru = { inherit (config.build) linux initrd coreboot; };
          meta.platforms = config.platforms;
          env.CBFSTOOL = "${pkgs.buildPackages.coreboot-utils}/bin/cbfstool"; # needed by futility
        }
        ''
          dd if=${config.build.coreboot}/coreboot.rom of=$out

          cbfstool $out expand -r FW_MAIN_A
          ${if pkgs.stdenv.hostPlatform.linuxArch == "x86_64" then ''
          cbfstool $out add-payload \
            -r FW_MAIN_A \
            -n fallback/payload \
            -f ${config.build.linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target} \
            -I ${config.build.initrd}/initrd
          '' else if pkgs.stdenv.hostPlatform.linuxArch == "arm64" then ''
          cbfstool $out add \
            -r FW_MAIN_A \
            -n fallback/payload \
            -t fit_payload \
            -f ${config.build.fitImage}/uImage
          '' else throw "Unsupported architecture"}
          cbfstool $out truncate -r FW_MAIN_A

          cbfstool $out add-payload \
            -r COREBOOT \
            -n fallback/payload \
            -f ${pkgs.libpayload}/libexec/hello.elf

          futility sign \
            --signprivate "${config.verifiedBoot.vbootFirmwarePrivkey}" \
            --keyblock "${config.verifiedBoot.vbootKeyblock}" \
            --kernelkey "${config.verifiedBoot.vbootKernelKey}" \
            --version ${config.verifiedBoot.vbootKeyblockVersion} \
            --flags ${config.verifiedBoot.vbootKeyblockPreambleFlags} \
            $out
        '';
      updateScript = pkgs.writeShellScriptBin "update-firmware" ''
        kexec -l ${config.build.linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target} \
          --initrd=${updateInitrd}/initrd \
          --command-line="${lib.concatStringsSep " " (map (tty: "console=/dev/${tty}") config.tinyboot.ttys)}"
        systemctl kexec
      '';
    };
  };
}
