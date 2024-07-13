{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.tinyboot;
in
{
  options.tinyboot =
    with lib;
    mkOption {
      type = types.submoduleWith {
        specialArgs.pkgs = pkgs;
        modules = [
          ./options.nix
          (
            { lib, ... }:
            {
              options = with lib; {
                enable = mkEnableOption "tinyboot bootloader";
                maxFailedBootAttempts = mkOption {
                  type = types.int;
                  default = 3;
                };
              };
            }
          )
        ];
      };
      default = { };
    };
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        boot.kernelPatches =
          with lib.kernel;
          with (whenHelpers config.boot.kernelPackages.kernel.version);
          [
            pkgs.kernelPatches.ima_tpm_early_init
            {
              name = "enable-ima";
              patch = null;
              extraStructuredConfig =
                {
                  IMA = yes;
                  TCG_TIS_SPI = yes;
                  IMA_DEFAULT_HASH_SHA256 = yes;
                }
                // lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
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
        boot.loader.external = lib.mkIf (with config.system.switch; enable || enableNg) {
          enable = true;
          installHook = toString [
            (lib.getExe' pkgs.tinybootTools "tboot-nixos-install")
            "--esp-mnt=${config.boot.loader.efi.efiSysMountPoint}"
            "--private-key=${cfg.verifiedBoot.tbootPrivateKey}"
            "--public-key=${cfg.verifiedBoot.tbootPublicCertificate}"
            "--timeout=${toString config.boot.loader.timeout}"
            "--max-tries=${toString cfg.maxFailedBootAttempts}"
          ];
        };
        systemd.generators.tboot-bless-boot-generator = lib.getExe' pkgs.tinybootTools "tboot-bless-boot-generator";
        systemd.services.tboot-bless-boot = {
          description = "Mark the current boot loader entry as good";
          documentation = [ "https://github.com/jmbaur/tinyboot" ];
          requires = [ "boot-complete.target" ];
          conflicts = [ "shutdown.target" ];
          before = [ "shutdown.target" ];
          after = [
            "local-fs.target"
            "boot-complete.target"
          ];
          unitConfig.DefaultDependencies = false;
          restartIfChanged = false; # Only run at boot
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${lib.getExe' pkgs.tinybootTools "tboot-bless-boot"} --esp-mnt=${config.boot.loader.efi.efiSysMountPoint} good";
          };
        };
      }
      (lib.mkIf cfg.coreboot.enable {
        environment.systemPackages = with pkgs; [
          cbmem
          cbfstool
          nvramtool
        ];

        programs.flashrom = {
          enable = true;
          package = lib.mkDefault cfg.flashrom.package;
        };

        system.build = {
          inherit (cfg.tinyboot.build) firmware;
        };

        boot.kernelPackages = lib.mkDefault (pkgs.linuxPackagesFor cfg.linux.package);
        boot.kernelPatches = [
          {
            name = "enable-coreboot";
            patch = null;
            extraStructuredConfig.GOOGLE_FIRMWARE = lib.kernel.yes;
          }
        ];
      })
    ]
  );
}
