{ config, pkgs, lib, ... }:
let
  cfg = config.tinyboot;
in
{
  options.tinyboot = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule [ (import ./options.nix { _pkgs = pkgs; _lib = lib; }) ]);
    default = null;
  };
  config = lib.mkIf (cfg != null) {
    environment.systemPackages = with pkgs; [ coreboot-utils tinyboot ];
    boot.kernelPatches =
      with lib.kernel;
      with (lib.kernel.whenHelpers config.boot.kernelPackages.kernel.version);
      [
        pkgs.kernelPatches.ima_tpm_early_init
        {
          name = "enable-ima";
          patch = null;
          extraStructuredConfig = { IMA = yes; IMA_DEFAULT_HASH_SHA256 = yes; };
        }
        {
          name = "enable-coreboot";
          patch = null;
          extraStructuredConfig = {
            GOOGLE_CBMEM = whenAtLeast "6.2" yes;
            GOOGLE_COREBOOT_TABLE = yes;
            GOOGLE_FIRMWARE = yes;
            GOOGLE_MEMCONSOLE_COREBOOT = yes;
            GOOGLE_VPD = yes;
          };
        }
      ];
    system.build.firmware = cfg.build.firmware;
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
