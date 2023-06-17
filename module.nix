{ config, pkgs, lib, ... }: {
  options.boot.loader.tinyboot.privateKey = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = lib.mdDoc ''
      Path to ed25519 private key.
    '';
  };
  config = lib.mkIf (config.boot.loader.tinyboot.privateKey != null) {
    boot.loader.systemd-boot.extraInstallCommands = ''
      find /boot/EFI/nixos -type f -name "*.efi" \
        -exec ${pkgs.pkgsStatic.tinyboot-client}/bin/tbootctl verified-boot sign --verbose --private-key ${config.boot.loader.tinyboot.privateKey} --file {} \;
    '';
    boot.loader.grub.device = "nodev"; # just install grub config file
    boot.loader.grub.extraInstallCommands = ''
      find /boot/kernels -type f \
        -exec ${pkgs.pkgsStatic.tinyboot-client}/bin/tbootctl verified-boot sign --verbose --private-key ${config.boot.loader.tinyboot.privateKey} --file {} \;
    '';
  };
}
