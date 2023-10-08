{ config, pkgs, lib, ... }:
let
  boards = builtins.readDir ./boards;
  buildFitImage = pkgs.callPackage ./fitimage { };
  updateInitrd = pkgs.callPackage ./initramfs.nix {
    extraContents = [
      { object = config.build.firmware; symlink = "/update.rom"; }
      { object = "${config.flashrom.package}/bin/flashrom"; symlink = "/bin/flashrom"; }
      { object = "${pkgs.tinyboot}/bin/tboot-update"; symlink = "/init"; }
    ];
  };
  testInitrd = pkgs.makeInitrdNG {
    compressor = "xz";
    contents = [{ object = "${pkgs.busybox}/bin/busybox"; symlink = "/init"; } { object = "${pkgs.busybox}/bin"; symlink = "/bin"; }];
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
    };
    linux = {
      package = mkOption { type = types.package; default = pkgs.linux_testing; };
      configFile = mkOption { type = types.path; };
      commandLine = mkOption { type = types.listOf types.str; default = [ ]; };
      dtb = mkOption { type = types.nullOr types.path; default = null; };
      dtbPattern = mkOption { type = types.nullOr types.str; default = null; };
      firmware = mkOption { type = types.nullOr types.path; default = null; };
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
    loglevel = mkOption {
      type = types.enum [ "off" "error" "warn" "info" "debug" "trace" ];
      default = "warn";
    };
    tinyboot = {
      tty = mkOption { type = types.str; default = "tty1"; };
      nameservers = mkOption {
        type = types.listOf types.str;
        default = [ "8.8.8.8" "8.8.4.4" "2001:4860:4860::8888" "2001:4860:4860::8844" ];
      };
    };
  };
  config = {
    # The "--" makes linux pass remaining parameters as args to PID1
    linux.commandLine = [ "console=ttynull" "--" "tboot.loglevel=${config.loglevel}" "tboot.tty=${config.tinyboot.tty}" "tboot.programmer=${config.flashrom.programmer}" ];

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
      baseInitrd = pkgs.callPackage ./initramfs.nix {
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
            { object = staticResolvConf; symlink = "/etc/resolv.conf.static"; }
            { object = imaPolicy; symlink = "/etc/ima/policy.conf"; }
            { object = config.verifiedBoot.signingPublicKey; symlink = "/etc/keys/x509_ima.der"; }
          ] ++ (lib.optional (config.linux.firmware != null) { object = config.linux.firmware; symlink = "/lib/firmware"; });
      };
      initrd = config.build.baseInitrd.override {
        prepend =
          let
            initrd = (pkgs.makeInitrdNG {
              compressor = "cat";
              contents = [{ object = "${pkgs.tinyboot}/bin/tboot-init"; symlink = "/init"; }];
            });
          in
          [ "${initrd}/initrd" ];
      };
      linux = (pkgs.callPackage ./linux.nix {
        builtinCmdline = config.linux.commandLine;
        linux = config.linux.package;
        inherit (config.linux) configFile;
      }).overrideAttrs (old: {
        preConfigure = (old.preConfigure or "") + ''
          mkdir tinyboot; cp ${config.verifiedBoot.caCertificate} tinyboot/ca.pem
        '';
        postInstall = (old.postInstall or "") + ''
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
        kexec -l ${config.build.linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target} --initrd=${updateInitrd}/initrd
        systemctl kexec
      '';
      # useful for testing kernel configurations
      testScript =
        let
          commonConsoles = map (console: "console=${console}")
            ((map (serial: "${serial},115200") [ "ttyS0" "ttyAMA0" "ttyMSM0" "ttymxc0" "ttyO0" "ttySAC2" ]) ++ [ "tty1" ]);
          linux = config.build.linux.override { builtinCmdline = [ ]; };
        in
        pkgs.writeShellScriptBin "tboot-test" ''
          kexec -l ${linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target} \
            --initrd=${testInitrd}/initrd \
            --command-line="${toString commonConsoles}"
          systemctl kexec
        '';
    };
  };
}

