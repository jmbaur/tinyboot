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
  options.tinyboot = lib.mkOption {
    type = lib.types.submoduleWith {
      specialArgs.pkgs = pkgs;
      modules = [
        ./options.nix
        {
          options = {
            enable = lib.mkEnableOption "tinyboot bootloader";
            extraInstallCommands = lib.mkOption {
              type = lib.types.lines;
              default = "";
            };
            maxFailedBootAttempts = lib.mkOption {
              type = lib.types.int;
              default = 3;
            };
          };
        }
      ];
    };
    default = { };
  };
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
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
                IMA = lib.kernel.yes;
                TCG_TIS_SPI = lib.kernel.yes;
                IMA_DEFAULT_HASH_SHA256 = lib.kernel.yes;
              }
              // lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
                # helpful for early TPM initialization on x86_64 chromebooks
                SPI_INTEL_PCI = lib.kernel.yes;
                MFD_INTEL_LPSS_ACPI = lib.kernel.yes;
                MFD_INTEL_LPSS_PCI = lib.kernel.yes;
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
        boot.loader.external = {
          enable = true;
          installHook = pkgs.writeScript "install-bls.sh" ''
            #!${pkgs.runtimeShell}
            ${
              toString [
                (lib.getExe' pkgs.tinybootTools "tboot-nixos-install")
                "--esp-mnt=${config.boot.loader.efi.efiSysMountPoint}"
                "--private-key=${cfg.verifiedBoot.tbootPrivateKey}"
                "--public-key=${cfg.verifiedBoot.tbootPublicCertificate}"
                "--timeout=${toString config.boot.loader.timeout}"
                "--max-tries=${toString cfg.maxFailedBootAttempts}"
              ]
            } "$@"
            ${cfg.extraInstallCommands}
          '';

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
        environment.systemPackages = [
          pkgs.cbmem
          pkgs.cbfstool
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
