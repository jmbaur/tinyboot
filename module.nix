{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.tinyboot;

  inherit
    ((lib.evalModules {
      modules = [
        ({
          _module.args = {
            inherit pkgs;
            inherit (cfg) board;
          };
        })
        ./options.nix
        ./boards/${cfg.board}/config.nix
      ];
    }).config.build
    )
    firmware
    ;
in
{
  options.tinyboot = with lib; {
    enable = mkEnableOption "tinyboot bootloader";
    board = mkOption { type = types.enum (builtins.attrNames (builtins.readDir ./boards)); };
    maxFailedBootAttempts = mkOption {
      type = types.int;
      default = 3;
    };
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
        boot.loader.external.enable = true;
        boot.loader.external.installHook = toString [
          (lib.getExe' pkgs.tinyboot "tboot-nixos-install")
          "--esp-mnt=${config.boot.loader.efi.efiSysMountPoint}"
          "--private-key=${cfg.verifiedBoot.tbootPrivateKey}"
          "--public-key=${cfg.verifiedBoot.tbootPublicCertificate}"
          "--timeout=${toString config.boot.loader.timeout}"
          "--max-tries=${toString cfg.maxFailedBootAttempts}"
        ];
        systemd.additionalUpstreamSystemUnits = [ "boot-complete.target" ];
        systemd.generators.tboot-bless-boot-generator = lib.getExe' pkgs.tinyboot "tboot-bless-boot-generator";
        systemd.services.tboot-bless-boot = {
          description = "Mark the Current Boot Loader Entry as Good";
          documentation = [ "github.com/jmbaur/tinyboot" ];
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
            ExecStart = "${lib.getExe' pkgs.tinyboot "tboot-bless-boot"} ${config.boot.loader.efi.efiSysMountPoint} good";
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
          inherit firmware;
        };

        boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
        boot.kernelPatches =
          with lib.kernel;
          with (whenHelpers config.boot.kernelPackages.kernel.version);
          [
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
      })
    ]
  );
}
