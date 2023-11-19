{ config, pkgs, lib, ... }:
let
  boards = builtins.readDir ./boards;
  tinyboot = pkgs.tinyboot.override { corebootSupport = config.coreboot.enable; };
  buildFitImage = pkgs.callPackage ./fitimage { };
  testInitrd = pkgs.makeInitrdNG {
    compressor = "xz";
    contents = [{ object = "${pkgs.busybox}/bin/busybox"; symlink = "/init"; } { object = "${pkgs.busybox}/bin"; symlink = "/bin"; }];
  };
  kconfigOption = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    apply = attrs: {
      inherit attrs;
      __resolved = lib.concatLines (lib.mapAttrsToList
        (option: response:
          if response ? freeform then
            let val = if lib.isInt response.freeform then response.freeform else ''"${response.freeform}"''; in
            "CONFIG_${option}=${val}"
          else assert response ? tristate;
          if response.tristate == null then
            "# CONFIG_${option} is not set"
          else assert response.tristate != "m"; # coreboot does not have modules
          "CONFIG_${option}=${response.tristate}")
        attrs);
    };
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
  imports = [ ./qemu.nix ] ++ lib.mapAttrsToList (board: _: ./boards/${board}/config.nix) boards;
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
    qemu.enable = mkEnableOption "qemu";
    qemu.flags = mkOption { type = types.listOf types.str; default = [ ]; };
    flashrom = {
      package = mkPackageOptionMD pkgs "flashrom-cros" { };
      programmer = mkOption { type = types.str; default = "internal"; };
    };
    linux = {
      package = mkOption { type = types.package; default = pkgs.linux_latest; };
      configFile = mkOption { type = types.path; };
      commandLine = mkOption { type = types.listOf types.str; default = [ ]; };
      dtb = mkOption { type = types.nullOr types.path; default = null; };
      dtbPattern = mkOption { type = types.nullOr types.str; default = null; };
      firmware = mkOption {
        type = types.listOf (types.submodule {
          options.dir = mkOption { type = types.str; };
          options.pattern = mkOption { type = types.str; };
        });
        default = [ ];
      };
    };
    coreboot = {
      enable = mkEnableOption "coreboot integration" // { default = true; };
      wpRange.start = mkOption { type = types.str; };
      wpRange.length = mkOption { type = types.str; };
      kconfig = kconfigOption;
      vpd.ro = vpdOption;
      vpd.rw = vpdOption;
    };
    verifiedBoot = {
      requiredSystemFeatures = mkOption { type = types.listOf types.str; default = [ ]; };
      tbootPublicCertificate = mkOption { type = types.path; default = ./test/keys/tboot/key.der; };
      tbootPrivateKey = mkOption { type = types.path; default = ./test/keys/tboot/key.pem; };
      vbootRootKey = mkOption { type = types.path; default = ./test/keys/root/key.vbpubk; };
      vbootFirmwarePrivkey = mkOption { type = types.path; default = ./test/keys/firmware/key.vbprivk; };
      vbootFirmwareKey = mkOption { type = types.path; default = ./test/keys/firmware/key.vbpubk; };
      vbootKeyblock = mkOption { type = types.path; default = ./test/keys/firmware/key.keyblock; };
    };
    loglevel = mkOption {
      type = types.enum [ "off" "error" "warn" "info" "debug" "trace" ];
      default = "info";
    };
    tinyboot.tty = mkOption { type = types.str; default = "tty1"; };
    extraInitrdContents = mkOption {
      type = types.listOf (types.submodule {
        options.object = mkOption { type = types.path; };
        options.symlink = mkOption { type = types.str; };
      });
      default = [ ];
    };
  };
  config = {
    # The "--" makes linux pass remaining parameters as args to PID1
    linux.commandLine = [ "console=ttynull" "--" "tboot.loglevel=${config.loglevel}" "tboot.tty=${config.tinyboot.tty}" ];

    coreboot.vpd.ro.pubkey = config.verifiedBoot.tbootPublicCertificate;
    coreboot.kconfig = with lib.kernel; {
      "DEFAULT_CONSOLE_LOGLEVEL_${toString { "off" = 2; "error" = 3; "warn" = 4; "info" = 6; "debug" = 7; "trace" = 8; }.${config.loglevel}}" = yes;
      PAYLOAD_NONE = unset;
      VBOOT = yes;
      VBOOT_ALWAYS_ENABLE_DISPLAY = yes;
      VBOOT_FIRMWARE_PRIVKEY = freeform config.verifiedBoot.vbootFirmwarePrivkey;
      VBOOT_KERNEL_KEY = freeform config.verifiedBoot.vbootFirmwareKey;
      VBOOT_KEYBLOCK = freeform config.verifiedBoot.vbootKeyblock;
      VBOOT_RECOVERY_KEY = freeform config.verifiedBoot.vbootFirmwareKey;
      VBOOT_ROOT_KEY = freeform config.verifiedBoot.vbootRootKey;
      VBOOT_SIGN = unset; # don't sign during build
      VPD = yes;
    } // lib.optionalAttrs pkgs.hostPlatform.isx86_64 {
      LINUX_INITRD = freeform "${config.build.initrd}/initrd";
      PAYLOAD_FILE = freeform "${config.build.linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target}";
      PAYLOAD_LINUX = yes;
      VBOOT_SLOTS_RW_AB = lib.mkDefault yes; # x86_64 spi flash is usually large enough for 3 vboot slots
      VBOOT_X86_SHA256_ACCELERATION = yes;
    } // lib.optionalAttrs pkgs.hostPlatform.isAarch64 {
      PAYLOAD_FILE = freeform "${config.build.fitImage}/uImage";
      PAYLOAD_FIT = yes;
      PAYLOAD_FIT_SUPPORT = yes;
      VBOOT_ARMV8_CE_SHA256_ACCELERATION = yes;
      VBOOT_SLOTS_RW_A = lib.mkDefault yes; # aarch64 spi flash is usually not large enough for 3 vboot slots
    };

    build = {
      baseInitrd = pkgs.makeInitrdNG {
        compressor = "xz";
        contents = [{
          symlink = "/lib/firmware";
          object = pkgs.buildPackages.runCommand "linux-firmware" { } ("mkdir -p $out;" + lib.concatLines (map
            ({ dir, pattern }: ''
              pushd ${pkgs.linux-firmware}/lib/firmware
              find ${dir} -type f -name "${pattern}" -exec install -D --target-directory=$out/${dir} {} \;
              popd
            '')
            config.linux.firmware));
        }] ++ config.extraInitrdContents;
      };
      initrd = config.build.baseInitrd.override {
        prepend = (pkgs.makeInitrdNG {
          compressor = "cat"; # prepend cannot be used with a compressed initrd
          contents = [{ symlink = "/init"; object = "${tinyboot}/bin/tboot-loader"; }];
        }) + "/initrd";
      };
      linux = (pkgs.callPackage ./pkgs/linux {
        builtinCmdline = config.linux.commandLine;
        linux = config.linux.package;
        inherit (config.linux) configFile;
      });
      fitImage = buildFitImage {
        inherit (config) board;
        inherit (config.build) linux initrd;
        inherit (config.linux) dtb dtbPattern;
      };
      coreboot = pkgs.callPackage ./pkgs/coreboot {
        inherit (config) board;
        configFile = config.coreboot.kconfig.__resolved;
      };
      firmware = pkgs.runCommand "tinyboot-${config.board}"
        {
          inherit (config.verifiedBoot) requiredSystemFeatures;
          nativeBuildInputs = with pkgs.buildPackages; [ cbfstool vboot_reference vpd ];
          passthru = { inherit (config.build) linux initrd coreboot; };
          meta.platforms = config.platforms;
          env.CBFSTOOL = "${pkgs.buildPackages.cbfstool}/bin/cbfstool"; # needed by futility
        }
        ''
          dd status=none if=${config.build.coreboot}/coreboot.rom of=$out

          vpd -f $out -i RO_VPD -O
          ${lib.concatLines (lib.mapAttrsToList (applyVpd "RO_VPD") config.coreboot.vpd.ro)}
          vpd -f $out -i RW_VPD -O
          ${lib.concatLines (lib.mapAttrsToList (applyVpd "RW_VPD") config.coreboot.vpd.rw)}

          futility sign \
            --signprivate "${config.verifiedBoot.vbootFirmwarePrivkey}" \
            --keyblock "${config.verifiedBoot.vbootKeyblock}" \
            --kernelkey "${config.verifiedBoot.vbootFirmwareKey}" \
            $out
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
