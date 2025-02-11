{
  config,
  pkgs,
  lib,
  ...
}:

let
  inherit (lib)
    concatLines
    hasPrefix
    isDerivation
    isPath
    isString
    kernel
    mapAttrsToList
    mkDefault
    mkEnableOption
    mkOption
    mkPackageOption
    optionalAttrs
    optionalString
    optionals
    types
    ;

  boardsDir = builtins.readDir ./boards;

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
  '';

  testInitrd = pkgs.makeInitrdNG {
    compressor = "xz";
    contents = [
      {
        source = "${pkgs.busybox}/bin/busybox";
        target = "/init";
      }
      {
        source = "${pkgs.busybox}/bin";
        target = "/bin";
      }
      {
        source = testStartupScript;
        target = "/etc/init.d/rcS";
      }
      {
        source = testInittab;
        target = "/etc/inittab";
      }
      {
        source = "${config.linux.firmware}/lib/firmware";
        target = "/lib/firmware";
      }
    ];
  };

  kconfigOption = mkOption {
    type = types.attrsOf types.anything;
    default = { };
    apply =
      attrs:
      concatLines (
        mapAttrsToList (
          kconfOption: answer:
          let
            optionName = "CONFIG_${kconfOption}";
            kconfLine =
              if answer ? freeform then
                if
                  (
                    (isPath answer.freeform || isDerivation answer.freeform)
                    || (isString answer.freeform && builtins.match "[0-9]+" answer.freeform == null)
                  )
                  && !(hasPrefix "0x" answer.freeform)
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

  vpdOption = mkOption {
    type = types.attrsOf (types.either types.str types.path);
    default = { };
  };

  applyVpd =
    vpdPartition: key: value:
    if isPath value then
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
  imports = [
    ./kernel-configs
  ] ++ (mapAttrsToList (board: _: ./boards/${board}/config.nix) boardsDir);

  options = {
    board = mkOption { type = types.enum (builtins.attrNames boardsDir); };

    build = mkOption {
      default = { };
      type = types.submoduleWith {
        modules = [ { freeformType = with types; lazyAttrsOf (uniq unspecified); } ];
      };
    };

    flashrom = {
      package = mkPackageOption pkgs "flashrom-cros" { };
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
        default = pkgs.linux_6_12;
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
        type = types.listOf types.package;
        default = [ ];
        apply =
          list:
          pkgs.buildEnv {
            name = "firmware";
            paths = map pkgs.compressFirmwareXz list;
            pathsToLink = [ "/lib/firmware" ];
            ignoreCollisions = true;
          };
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
        default = ./tests/keys/tboot/key.der;
      };
      tbootPrivateKey = mkOption {
        type = types.path;
        default = ./tests/keys/tboot/key.pem;
      };
      vbootRootKey = mkOption {
        type = types.path;
        default = ./tests/keys/root/key.vbpubk;
      };
      vbootFirmwarePrivkey = mkOption {
        type = types.path;
        default = ./tests/keys/firmware/key.vbprivk;
      };
      vbootFirmwareKey = mkOption {
        type = types.path;
        default = ./tests/keys/firmware/key.vbpubk;
      };
      vbootKeyblock = mkOption {
        type = types.path;
        default = ./tests/keys/firmware/key.keyblock;
      };
    };
  };

  config = {
    linux.kconfig.CMDLINE = kernel.freeform (
      toString (
        optionals config.video [ "fbcon=logo-count:1" ]
        ++ [
          "printk.devkmsg=on"
          "loglevel=${if config.debug then "8" else "5"}"
        ]
        ++ map (c: "console=${c}") config.linux.consoles
      )
    );

    coreboot.vpd.ro.pubkey = config.verifiedBoot.tbootPublicCertificate;

    coreboot.kconfig =
      {
        "DEFAULT_CONSOLE_LOGLEVEL_${if config.debug then "7" else "6"}" = kernel.yes;
        PAYLOAD_NONE = kernel.unset;
        VBOOT = kernel.yes;
        VBOOT_ALWAYS_ENABLE_DISPLAY = kernel.yes;
        VBOOT_FIRMWARE_PRIVKEY = kernel.freeform config.verifiedBoot.vbootFirmwarePrivkey;
        VBOOT_KERNEL_KEY = kernel.freeform config.verifiedBoot.vbootFirmwareKey;
        VBOOT_KEYBLOCK = kernel.freeform config.verifiedBoot.vbootKeyblock;
        VBOOT_RECOVERY_KEY = kernel.freeform config.verifiedBoot.vbootFirmwareKey;
        VBOOT_ROOT_KEY = kernel.freeform config.verifiedBoot.vbootRootKey;
        VBOOT_SIGN = kernel.unset; # don't sign during build
        VPD = kernel.yes;
      }
      // optionalAttrs pkgs.hostPlatform.isx86_64 {
        LINUX_INITRD = kernel.freeform "${config.build.initrd}/${config.build.initrd.initrdPath}";
        PAYLOAD_FILE = kernel.freeform "${config.build.linux}/${pkgs.stdenv.hostPlatform.linux-kernel.target}";
        PAYLOAD_LINUX = kernel.yes;
        VBOOT_SLOTS_RW_AB = mkDefault kernel.yes; # x86_64 spi flash is usually large enough for 3 vboot slots
        VBOOT_X86_SHA256_ACCELERATION = kernel.yes;
      }
      // optionalAttrs pkgs.hostPlatform.isAarch64 {
        PAYLOAD_FILE = kernel.freeform "${config.build.fitImage}/uImage";
        PAYLOAD_FIT = kernel.yes;
        PAYLOAD_FIT_SUPPORT = kernel.yes;
        VBOOT_ARMV8_CE_SHA256_ACCELERATION = kernel.yes;
        VBOOT_SLOTS_RW_A = mkDefault kernel.yes; # spi flash on aarch64 chromebooks is usually not large enough for 3 vboot slots
      };

    build = {
      inherit testInitrd;

      initrd = pkgs.tinybootLoader.override { firmwareDirectory = config.linux.firmware; };

      linux = (
        pkgs.callPackage ./pkgs/linux {
          linux = config.linux.package;
          inherit (config.linux) kconfig;
        }
      );

      fitImage = (pkgs.callPackage ./fitimage { }) {
        inherit (config) board;
        inherit (config.build) linux initrd;
        inherit (config.linux) dtb dtbPattern;
      };

      coreboot = pkgs.callPackage ./pkgs/coreboot {
        inherit (config) board;
        inherit (config.coreboot) kconfig;
      };

      firmware =
        pkgs.runCommand "tinyboot-${config.board}"
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

            ${optionalString (builtins.trace "TODO: create vpd image in zig" false) ''
              vpd -f $out -i RO_VPD -O
              ${concatLines (mapAttrsToList (applyVpd "RO_VPD") config.coreboot.vpd.ro)}
              vpd -f $out -i RW_VPD -O
              ${concatLines (mapAttrsToList (applyVpd "RW_VPD") config.coreboot.vpd.rw)}
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
            ++ [ "tty0" ]
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
