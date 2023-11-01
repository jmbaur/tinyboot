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
    default = { };
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
            # helpful for early TPM initialization on x86_64 chromebooks
            SPI_INTEL_PCI = yes;
            MFD_INTEL_LPSS_ACPI = yes;
            MFD_INTEL_LPSS_PCI = yes;
          };
        }
        {
          name = "allow-flashrom";
          patch = null;
          extraStructuredConfig.IO_STRICT_DEVMEM = lib.kernel.no;
        }
      ];
      boot.loader.supportsInitrdSecrets = lib.mkForce false;
      boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
      boot.bootspec.enable = true;
      boot.loader.external.enable = true;
      boot.loader.external.installHook = "${pkgs.tinyboot}/bin/tboot-nixos-install --efi-sys-mount-point ${config.boot.loader.efi.efiSysMountPoint} --sign-file ${cfg.build.linux}/bin/sign-file --private-key ${cfg.verifiedBoot.signingPrivateKey} --public-key ${cfg.verifiedBoot.signingPublicKey}";
    }
    (lib.mkIf cfg.coreboot.enable {
      environment.systemPackages = with pkgs; [ cbmem cbfstool nvramtool ];

      programs.flashrom = {
        enable = true;
        package = lib.mkDefault cfg.flashrom.package;
      };

      system.build = { inherit (cfg.build) firmware; };

      boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_testing;
      boot.kernelPatches = with lib.kernel; with (whenHelpers config.boot.kernelPackages.kernel.version); [{
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
