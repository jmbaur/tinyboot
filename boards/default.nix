{ lib, callPackage, buildCoreboot, tinyboot-kernel, tinyboot-initramfs }:
lib.mapAttrs
  (board: _: buildCoreboot {
    boardName = board;
    configfile = lib.path.append ./. "${board}/coreboot.config";
    extraConfig =
      let
        extraExtraConfig = callPackage (lib.path.append ./. "${board}/extra-config.nix") { };
      in
      extraExtraConfig + ''
        CONFIG_PAYLOAD_FILE="${tinyboot-kernel}/bzImage"
        CONFIG_LINUX_INITRD="${tinyboot-initramfs.override { debug = true; }}/initrd"
      '';
  })
  (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.))
