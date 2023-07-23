{ config, pkgs, lib, ... }:
let
  cfg = config.tinyboot;
in
{
  options.tinyboot = {
    enable = lib.mkEnableOption "tinyboot bootloader";
    settings = lib.mkOption {
      type = lib.types.submodule [ (import ./options.nix { _pkgs = pkgs; _lib = lib; }) ];
      default = { };
    };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ cbmem cbfstool nvramtool ectool tinyboot config.system.build.updateScript ];
    programs.flashrom = {
      enable = true;
      package = lib.mkDefault cfg.settings.flashrom.package;
    };
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
    system.build = { inherit (cfg.settings.build) firmware updateScript; };
    boot.loader.supportsInitrdSecrets = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
    boot.loader.systemd-boot.extraInstallCommands = ''
      echo "signing boot files"
      find /boot/EFI/nixos -type f -name "*.efi" \
        -exec ${cfg.settings.build.linux}/bin/sign-file sha256 ${cfg.settings.verifiedBoot.signingPrivateKey} ${cfg.settings.verifiedBoot.signingPublicKey} {} \;
    '';
    boot.loader.grub.device = "nodev"; # just install grub config file
    boot.loader.grub.extraInstallCommands = ''
      echo "signing boot files"
      find /boot/kernels -type f \
        -exec ${cfg.settings.build.linux}/bin/sign-file sha256 ${cfg.settings.verifiedBoot.signingPrivateKey} ${cfg.settings.verifiedBoot.signingPublicKey} {} \;
    '';
  };
}
