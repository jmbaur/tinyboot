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
    mkEnableOption
    mkOption
    optionals
    types
    ;

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
in
{
  imports = [ ./kernel-configs ];

  options = {
    hostPlatform = mkOption {
      type = types.nullOr types.unspecified;
      default = null;
    };

    build = mkOption {
      default = { };
      type = types.submoduleWith {
        modules = [ { freeformType = with types; lazyAttrsOf (uniq unspecified); } ];
      };
    };

    debug = mkEnableOption "debug";

    network = mkEnableOption "network";

    chromebook = mkEnableOption "chromebook";

    efi = mkEnableOption "efi";

    platform = mkOption {
      type = types.nullOr (
        types.attrTag {
          mediatek = mkEnableOption "mediatek";
          qemu = mkEnableOption "qemu";
          qualcomm = mkEnableOption "qualcomm";
        }
      );
      default = null;
    };

    linux = {
      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ./linux { inherit (config.linux) kconfig; };
        defaultText = "tinyboot provided kernel";
      };
      consoles = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      kconfig = kconfigOption;
      firmware = mkOption {
        type = types.listOf types.package;
        default = [ ];
        apply = pkgs.callPackage ./compress-firmware.nix { };
      };
    };
  };

  config = {
    linux.kconfig.CMDLINE = kernel.freeform (
      toString (
        [ "printk.devkmsg=on" ]
        ++ optionals config.debug [ "debug" ]
        ++ map (c: "console=${c}") config.linux.consoles
      )
    );

    build = {
      initrd = pkgs.tinyboot.override { firmwareDirectory = config.linux.firmware; };
      linux = config.linux.package;
    };
  };
}
