{
  config,
  pkgs,
  lib,
  board,
  ...
}:
let
  tinyboot = pkgs.tinyboot.override {
    inherit (config) debug;
    corebootSupport = config.coreboot.enable;
  };
  buildFitImage = pkgs.callPackage ./fitimage { };
  testStartupScript = pkgs.writeScript "installer-startup-script" ''
    #!/bin/sh
    mkdir -p /proc && mount -t proc proc /proc
    mkdir -p /sys && mount -t sysfs sysfs /sys
    mkdir -p /dev && mount -t devtmpfs devtmpfs /dev
    mkdir -p /dev/pts && mount -t devpts devpts /dev/pts
    mkdir -p /run && mount -t tmpfs tmpfs /run
    ln -sfn /proc/self/fd /dev/fd
    ln -sfn /proc/self/fd/0 /dev/stdin
    ln -sfn /proc/self/fd/1 /dev/stdout
    ln -sfn /proc/self/fd/2 /dev/stderr
    touch /etc/fstab
  '';
  testInittab = pkgs.writeText "inittab" ''
    ::sysinit:/etc/init.d/rcS
    ::askfirst:/bin/sh
    ::ctrlaltdel:/bin/reboot
    ::shutdown:/bin/swapoff -a
    ::shutdown:/bin/umount -a -r
    ::restart:/bin/init
    tty2::askfirst:/bin/sh
    tty3::askfirst:/bin/sh
    tty4::askfirst:/bin/sh
    ttyS0::askfirst:/bin/sh
  '';
  testInitrd = pkgs.makeInitrdNG {
    compressor = "xz";
    contents = [
      {
        object = "${pkgs.busybox}/bin/busybox";
        symlink = "/init";
      }
      {
        object = "${pkgs.busybox}/bin";
        symlink = "/bin";
      }
      {
        object = testStartupScript;
        symlink = "/etc/init.d/rcS";
      }
      {
        object = testInittab;
        symlink = "/etc/inittab";
      }
    ] ++ config.extraInitrdContents;
  };
  kconfigOption = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    apply =
      attrs:
      lib.concatLines (
        lib.mapAttrsToList (
          kconfOption: answer:
          let
            optionName = "CONFIG_${kconfOption}";
            kconfLine =
              if answer ? freeform then
                if
                  (
                    (lib.isPath answer.freeform || lib.isDerivation answer.freeform)
                    || (lib.isString answer.freeform && builtins.match "[0-9]+" answer.freeform == null)
                  )
                  && !(lib.hasPrefix "0x" answer.freeform)
                then
                  "${optionName}=\"${answer.freeform}\""
                else
                  "${optionName}=${toString answer.freeform}"
              else
                assert answer ? tristate;
                assert answer.tristate != "m";
                if answer.tristate == null then
                  "# ${optionName} is not set"
                else
                  "${optionName}=${toString answer.tristate}";
          in
          kconfLine
        ) attrs
      );
  };
  vpdOption = lib.mkOption {
    type = lib.types.attrsOf (lib.types.either lib.types.str lib.types.path);
    default = { };
  };
  applyVpd =
    vpdPartition: key: value:
    if lib.isPath value then
      ''
        base64 <${value} >tmp.base64
        vpd -f $out -i ${vpdPartition} -S ${key}=tmp.base64
        rm tmp.base64
      ''
    else
      ''
        vpd -f $out -i ${vpdPartition} -s ${key}=${value}
      '';
in
{
  imports = [ ./kernel-configs ];
  options = with lib; {
    build = mkOption {
      default = { };
      type = types.submoduleWith {
        modules = [ { freeformType = with types; lazyAttrsOf (uniq unspecified); } ];
      };
    };
    flashrom = {
      package = mkPackageOptionMD pkgs "flashrom-cros" { };
      programmer = mkOption {
        type = types.str;
        default = "internal";
      };
    };
    debug = mkEnableOption "debug";
    video = mkEnableOption "video";
    network = mkEnableOption "network";
    chromebook = mkEnableOption "chromebook";
    platform = mkOption {
      type = types.nullOr (
        types.attrTag {
          alderlake = mkEnableOption "alderlake";
          mediatek = mkEnableOption "mediatek";
          qemu = mkEnableOption "qemu";
          qualcomm = mkEnableOption "qualcomm";
          tigerlake = mkEnableOption "tigerlake";
        }
      );
      default = null;
    };
    linux = {
      package = mkOption {
        type = types.package;
        default = pkgs.linux_6_8;
      };
      consoles = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      kconfig = kconfigOption;
      dtb = mkOption {
        type = types.nullOr types.path;
        default = null;
      };
      dtbPattern = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      firmware = mkOption {
        type = types.listOf (
          types.submodule {
            options.dir = mkOption { type = types.str; };
            options.pattern = mkOption { type = types.str; };
          }
        );
        default = [ ];
      };
    };
    coreboot = {
      enable = mkEnableOption "coreboot integration" // {
        default = config.chromebook;
      };
      wpRange.start = mkOption { type = types.str; };
      wpRange.length = mkOption { type = types.str; };
      kconfig = kconfigOption;
      vpd.ro = vpdOption;
      vpd.rw = vpdOption;
    };
    verifiedBoot = {
      requiredSystemFeatures = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      tbootPublicCertificate = mkOption {
        type = types.path;
        default = ./test/keys/tboot/key.der;
      };
      tbootPrivateKey = mkOption {
        type = types.path;
        default = ./test/keys/tboot/key.pem;
      };
      vbootRootKey = mkOption {
        type = types.path;
        default = ./test/keys/root/key.vbpubk;
      };
      vbootFirmwarePrivkey = mkOption {
        type = types.path;
        default = ./test/keys/firmware/key.vbprivk;
      };
      vbootFirmwareKey = mkOption {
        type = types.path;
        default = ./test/keys/firmware/key.vbpubk;
      };
      vbootKeyblock = mkOption {
        type = types.path;
        default = ./test/keys/firmware/key.keyblock;
      };
    };
    extraInitrdContents = mkOption {
      type = types.listOf (
        types.submodule {
          options.object = mkOption { type = types.path; };
          options.symlink = mkOption { type = types.str; };
        }
      );
      default = [ ];
    };
  };
  config = {
    linux.kconfig.CMDLINE = lib.kernel.freeform (
      toString (
        lib.optionals config.video [ "fbcon=logo-count:1" ]
        ++ [ (if config.debug then "debug" else "quiet") ]
        ++ map (c: "console=${c}") config.linux.consoles
      )
    );
    extraInitrdContents = lib.optional (config.linux.firmware != [ ]) {
      symlink = "/lib/firmware";
      object = pkgs.buildPackages.runCommand "linux-firmware" { } (
        "mkdir -p $out;"
        + lib.concatLines (
          map (
            { dir, pattern }:
            ''
              pushd ${pkgs.linux-firmware}/lib/firmware
              find ${dir} -type f -name "${pattern}" -exec install -Dm0444 --target-directory=$out/${dir} {} \;
              popd
            ''
          ) config.linux.firmware
        )
      );
    };

    coreboot.vpd.ro.pubkey = config.verifiedBoot.tbootPublicCertificate;
    coreboot.kconfig =
      with lib.kernel;
      {
        "DEFAULT_CONSOLE_LOGLEVEL_${if config.debug then "7" else "6"}" = yes;
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
      }
      // lib.optionalAttrs pkgs.hostPlatform.isx86_64 {
        LINUX_INITRD = freeform "${config.build.initrd}/initrd";
        PAYLOAD_FILE = freeform "${config.build.linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target}";
        PAYLOAD_LINUX = yes;
        VBOOT_SLOTS_RW_AB = lib.mkDefault yes; # x86_64 spi flash is usually large enough for 3 vboot slots
        VBOOT_X86_SHA256_ACCELERATION = yes;
      }
      // lib.optionalAttrs pkgs.hostPlatform.isAarch64 {
        PAYLOAD_FILE = freeform "${config.build.fitImage}/uImage";
        PAYLOAD_FIT = yes;
        PAYLOAD_FIT_SUPPORT = yes;
        VBOOT_ARMV8_CE_SHA256_ACCELERATION = yes;
        VBOOT_SLOTS_RW_A = lib.mkDefault yes; # spi flash on aarch64 chromebooks is usually not large enough for 3 vboot slots
      };

    build = {
      inherit testInitrd;
      initrd = pkgs.makeInitrdNG {
        prepend = [ "${tinyboot}/tboot-loader.cpio.xz" ];
        compressor = "xz";
        contents = config.extraInitrdContents ++ [
          {
            symlink = "/empty";
            object = pkgs.emptyFile;
          }
        ];
      };
      linux = (
        pkgs.callPackage ./pkgs/linux {
          linux = config.linux.package;
          inherit (config.linux) kconfig;
        }
      );
      fitImage = buildFitImage {
        inherit board;
        inherit (config.build) linux initrd;
        inherit (config.linux) dtb dtbPattern;
      };
      coreboot = pkgs.callPackage ./pkgs/coreboot {
        inherit board;
        inherit (config.coreboot) kconfig;
      };
      firmware =
        pkgs.runCommand "tinyboot-${board}"
          {
            inherit (config.verifiedBoot) requiredSystemFeatures;
            nativeBuildInputs = with pkgs.buildPackages; [
              cbfstool
              vboot_reference # vpd
            ];
            passthru = {
              inherit (config.build)
                linux
                initrd
                testInitrd
                coreboot
                ;
            };
            env.CBFSTOOL = "${pkgs.buildPackages.cbfstool}/bin/cbfstool"; # needed by futility
          }
          ''
            dd status=none if=${config.build.coreboot}/coreboot.rom of=$out

            ${lib.optionalString (lib.trace "TODO: create vpd image in zig" false) ''
              vpd -f $out -i RO_VPD -O
              ${lib.concatLines (lib.mapAttrsToList (applyVpd "RO_VPD") config.coreboot.vpd.ro)}
              vpd -f $out -i RW_VPD -O
              ${lib.concatLines (lib.mapAttrsToList (applyVpd "RW_VPD") config.coreboot.vpd.rw)}
            ''}

            futility sign \
              --signprivate "${config.verifiedBoot.vbootFirmwarePrivkey}" \
              --keyblock "${config.verifiedBoot.vbootKeyblock}" \
              --kernelkey "${config.verifiedBoot.vbootFirmwareKey}" \
              $out
          '';
      # useful for testing kernel configurations
      testScript =
        let
          commonConsoles = map (console: "console=${console}") (
            (map (serial: "${serial},115200") [
              "ttyS0"
              "ttyAMA0"
              "ttyMSM0"
              "ttymxc0"
              "ttyO0"
              "ttySAC2"
            ])
            ++ [ "tty1" ]
          );
        in
        pkgs.writeShellScriptBin "tboot-test" ''
          kexec -l ${config.build.linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target} \
          --initrd=${testInitrd}/initrd \
          --command-line="${toString commonConsoles}"
          systemctl kexec
        '';
    };
  };
}
