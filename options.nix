{ config, pkgs, lib, ... }:
let
  tinyboot = pkgs.tinyboot.override {
    corebootSupport = config.coreboot.enable;
  };
  boards = builtins.readDir ./boards;
  buildFitImage = pkgs.callPackage ./fitimage { };
  installInitrd = pkgs.callPackage ./initramfs.nix {
    extraContents = [
      { object = "${config.flashrom.package}/bin/flashrom"; symlink = "/bin/flashrom"; }
    ];
  };
  updateInitrd = pkgs.callPackage ./initramfs.nix {
    extraContents = [
      { object = config.build.firmware; symlink = "/update.rom"; }
      { object = "${config.flashrom.package}/bin/flashrom"; symlink = "/bin/flashrom"; }
      { object = "${tinyboot}/bin/tboot-update"; symlink = "/init"; }
      { object = "${tinyboot}/bin/tboot-update"; symlink = "/bin/nologin"; }
    ];
  };
  testInitrd = pkgs.makeInitrdNG {
    compressor = "xz";
    contents = [{ object = "${pkgs.busybox}/bin/busybox"; symlink = "/init"; } { object = "${pkgs.busybox}/bin"; symlink = "/bin"; }];
  };
  vpdOption = lib.mkOption {
    type = lib.types.attrsOf (lib.types.either lib.types.str lib.types.path);
    default = { };
  };
  applyVpd = vpdPartition: key: value:
    if lib.isPath value then ''
      base64 <${value} >tmp.base64
      vpd -f $out -i ${vpdPartition} -S ${key}=tmp.base64
      rm tmp.base64
    '' else ''
      vpd -f $out -i ${vpdPartition} -s ${key}=${value}
    '';
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
      enable = mkEnableOption "coreboot integration" // { default = true; };
      configFile = mkOption { type = types.path; };
      vpd.ro = vpdOption;
      vpd.rw = vpdOption;
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
    tinyboot.tty = mkOption { type = types.str; default = "tty1"; };
  };
  config = {
    # The "--" makes linux pass remaining parameters as args to PID1
    linux.commandLine = [ "console=ttynull" "--" "tboot.loglevel=${config.loglevel}" "tboot.tty=${config.tinyboot.tty}" "tboot.programmer=${config.flashrom.programmer}" ];

    coreboot.vpd.ro.pubkey = config.verifiedBoot.signingPublicKey;
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
        extraContents = [
          { object = ./etc/ima_policy.conf; symlink = "/etc/ima/policy.conf"; }
        ] ++ (lib.optional (config.linux.firmware != null) { object = config.linux.firmware; symlink = "/lib/firmware"; });
      };
      initrd = config.build.baseInitrd.override {
        prepend =
          let
            initrd = (pkgs.makeInitrdNG {
              compressor = "cat"; # prepend cannot be used with a compressed initrd
              contents = [
                { object = "${tinyboot}/bin/tboot-loader"; symlink = "/init"; }
                { object = "${tinyboot}/bin/tboot-loader"; symlink = "/bin/nologin"; }
              ];
            });
          in
          [ "${initrd}/initrd" ];
      };
      linux = (pkgs.callPackage ./linux.nix {
        builtinCmdline = config.linux.commandLine;
        linux = config.linux.package;
        inherit (config.linux) configFile;
      });
      fitImage = buildFitImage {
        inherit (config) board;
        inherit (config.build) linux initrd;
        inherit (config.linux) dtb dtbPattern;
      };
      coreboot = pkgs.buildCoreboot {
        inherit (config) board;
        inherit (config.coreboot) configFile extraConfig;
      };
      firmware = pkgs.runCommand "tinyboot-${config.build.coreboot.name}"
        {
          inherit (config.verifiedBoot) requiredSystemFeatures;
          nativeBuildInputs = with pkgs.buildPackages; [ cbfstool vboot_reference vpd ];
          passthru = { inherit (config.build) linux initrd coreboot; };
          meta.platforms = config.platforms;
          env.CBFSTOOL = "${pkgs.buildPackages.cbfstool}/bin/cbfstool"; # needed by futility
        }
        ''
          dd if=${config.build.coreboot}/coreboot.rom of=$out

          vpd -f $out -O
          ${lib.concatLines (lib.mapAttrsToList (applyVpd "RO_VPD") config.coreboot.vpd.ro)}
          ${lib.concatLines (lib.mapAttrsToList (applyVpd "RW_VPD") config.coreboot.vpd.rw)}

          for section in "FW_MAIN_A" "COREBOOT"; do
          cbfstool $out expand -r $section
          ${if pkgs.stdenv.hostPlatform.isx86_64 then ''
          cbfstool $out add-payload \
            -r $section \
            -n fallback/payload \
            -f ${config.build.linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target} \
            -I ${config.build.initrd}/initrd
          '' else if pkgs.stdenv.hostPlatform.isAarch64 then ''
          cbfstool $out add \
            -r $section \
            -n fallback/payload \
            -t fit_payload \
            -f ${config.build.fitImage}/uImage
          '' else throw "unsupported architecture"}
          cbfstool $out truncate -r $section
          done

          futility sign \
            --signprivate "${config.verifiedBoot.vbootFirmwarePrivkey}" \
            --keyblock "${config.verifiedBoot.vbootKeyblock}" \
            --kernelkey "${config.verifiedBoot.vbootKernelKey}" \
            --version ${config.verifiedBoot.vbootKeyblockVersion} \
            --flags ${config.verifiedBoot.vbootKeyblockPreambleFlags} \
            $out
        '';
      installScript = pkgs.writeShellScriptBin "install-tinyboot" ''
        kexec -l ${config.build.linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target} --initrd=${installInitrd}/initrd
        systemctl kexec
      '';
      updateScript = pkgs.writeShellScriptBin "update-tinyboot" ''
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

