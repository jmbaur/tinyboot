{ config, pkgs, lib, ... }:
let
  cfg = config.tinyboot;
in
{
  options.tinyboot = with lib; mkOption {
    type = types.submodule [
      { _module.args = { inherit pkgs; }; }
      ./options.nix
      { options.enable = mkEnableOption "tinyboot bootloader"; }
    ];
  };
  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      boot.kernelPatches = with lib.kernel; with (whenHelpers config.boot.kernelPackages.kernel.version); [
        pkgs.kernelPatches.ima_tpm_early_init
        {
          name = "enable-ima";
          patch = null;
          extraStructuredConfig = {
            IMA = yes;
            TCG_TIS_SPI = yes;
            IMA_DEFAULT_HASH_SHA256 = yes;
          } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
            SPI_INTEL_PCI = yes;
            MFD_INTEL_LPSS_ACPI = yes;
            MFD_INTEL_LPSS_PCI = yes;
          };
        }
      ];
      boot.loader.supportsInitrdSecrets = lib.mkForce false;
      boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
      boot.loader.systemd-boot.extraInstallCommands = ''
        echo "signing boot files"
        find /boot/EFI/nixos -type f -name "*.efi" \
          -exec ${cfg.build.linux}/bin/sign-file sha256 ${cfg.verifiedBoot.signingPrivateKey} ${cfg.verifiedBoot.signingPublicKey} {} \;
      '';
    }
    (lib.mkIf cfg.coreboot.enable {
      environment.systemPackages = with pkgs; [ cbmem cbfstool nvramtool cfg.build.updateScript ];

      programs.flashrom = {
        enable = true;
        package = lib.mkDefault cfg.flashrom.package;
      };

      system.build = { inherit (cfg.build) firmware; };

      boot.kernelPackages = with lib.kernel; with (whenHelpers config.boot.kernelPackages.kernel.version); [{
        name = "enable-coreboot";
        patch = null;
        extraStructuredConfig = {
          GOOGLE_CBMEM = whenAtLeast "6.2" yes;
          GOOGLE_COREBOOT_TABLE = yes;
          GOOGLE_FIRMWARE = yes;
          GOOGLE_MEMCONSOLE_COREBOOT = yes;
          GOOGLE_VPD = yes;
        };
      }];
    })
  ]);
}
