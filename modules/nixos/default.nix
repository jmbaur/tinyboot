{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.tinyboot;

  inherit (lib)
    getExe'
    kernel
    mkEnableOption
    mkForce
    mkIf
    mkMerge
    mkOption
    optionalAttrs
    optionals
    types
    ;
in
{
  options.tinyboot = mkOption {
    type = types.submoduleWith {
      specialArgs = { inherit pkgs; };
      modules = [
        ../standalone
        {
          options = {
            enable = mkEnableOption "tinyboot bootloader";
            extraInstallCommands = mkOption {
              type = types.lines;
              default = "";
            };
            maxFailedBootAttempts = mkOption {
              type = types.ints.positive;
              default = 3;
            };
            verifiedBoot = {
              enable = mkEnableOption "verified boot";
              certificate = mkOption { type = types.path; };
              privateKey = mkOption { type = types.path; };
            };
          };
        }
      ];
    };
    default = { };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = config.boot.bootspec.enable;
          message = "Bootloader install program depends on bootspec";
        }
      ];

      boot.kernelPatches = [
        pkgs.kernelPatches.ima_tpm_early_init
        {
          name = "enable-ima";
          patch = null;
          extraStructuredConfig =
            {
              IMA = kernel.yes;
              TCG_TIS_SPI = kernel.yes;
              IMA_DEFAULT_HASH_SHA256 = kernel.yes;
            }
            // optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
              # helpful for early TPM initialization on x86_64 chromebooks
              SPI_INTEL_PCI = kernel.yes;
              MFD_INTEL_LPSS_ACPI = kernel.yes;
              MFD_INTEL_LPSS_PCI = kernel.yes;
            };
        }
      ];
      boot.loader.supportsInitrdSecrets = mkForce false;
      boot.loader.efi.canTouchEfiVariables = mkForce false;
      boot.loader.external = {
        enable = true;
        installHook = pkgs.writeScript "install-bootloaderspec.sh" ''
          #!${pkgs.runtimeShell}
          ${
            toString (
              [
                (getExe' pkgs.tinybootTools "tboot-nixos-install")
                "--esp-mnt=${config.boot.loader.efi.efiSysMountPoint}"
                "--timeout=${toString config.boot.loader.timeout}"
                "--max-tries=${toString cfg.maxFailedBootAttempts}"
              ]
              ++ optionals cfg.verifiedBoot.enable [
                "--private-key=${cfg.verifiedBoot.privateKey}"
                "--certificate=${cfg.verifiedBoot.certificate}"
              ]
            )
          } "$@"
          ${cfg.extraInstallCommands}
        '';
      };
      systemd.generators.tboot-bless-boot-generator = getExe' pkgs.tinybootTools "tboot-bless-boot-generator";
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
          ExecStart = "${getExe' pkgs.tinybootTools "tboot-bless-boot"} --esp-mnt=${config.boot.loader.efi.efiSysMountPoint} good";
        };
      };
    }
  ]);
}
