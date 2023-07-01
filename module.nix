{ config, pkgs, lib, ... }:
let cfg = config.tinyboot; in
{
  options.tinyboot = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule [ (import ./options.nix { _pkgs = pkgs; _lib = lib; }) ]);
    default = null;
  };
  config = lib.mkIf (cfg != null) {
    system.build.firmare = cfg.build.firmware;
    boot.loader.systemd-boot.extraInstallCommands = lib.optionalString cfg.verifiedBoot.enable ''
      echo "signing boot files"
      find /boot/EFI/nixos -type f -name "*.efi" \
        -exec ${cfg.build.linux}/bin/sign-file sha256 ${cfg.verifiedBoot.signingPrivateKey} ${cfg.verifiedBoot.signingPublicKey} {} \;
    '';
    boot.loader.grub.device = "nodev"; # just install grub config file
    boot.loader.grub.extraInstallCommands = ''
      echo "signing boot files"
      find /boot/kernels -type f \
        -exec ${cfg.build.linux}/bin/sign-file sha256 ${cfg.verifiedBoot.signingPrivateKey} ${cfg.verifiedBoot.signingPublicKey} {} \;
    '';
  };
}
