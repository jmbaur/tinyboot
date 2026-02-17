{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.boot.loader.tinyboot;

  inherit (lib)
    escapeShellArgs
    getExe'
    kernel
    mkEnableOption
    mkForce
    mkIf
    mkOption
    optionals
    types
    versionAtLeast
    ;
in
{
  options.boot.loader.tinyboot = {
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

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.boot.bootspec.enable;
        message = "Bootloader install program depends on bootspec";
      }
      {
        assertion = versionAtLeast config.boot.kernelPackages.kernel.version "6.19";
        message = "Must use Linux kernel 6.19 or newer for liveupdate";
      }
    ];
    boot.kernelParams = [
      "ima_hash=sha256"
      "kho=on"
      "liveupdate=on"
    ];
    boot.kernelPatches = [
      {
        name = "tinyboot-support";
        patch = null;
        structuredExtraConfig = {
          IMA = kernel.yes;
          LIVEUPDATE = kernel.yes;
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
          escapeShellArgs (
            [
              (getExe' pkgs.tinyboot "tboot-nixos-install")
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
    systemd.generators.tboot-bless-boot-generator = getExe' pkgs.tinyboot "tboot-bless-boot-generator";
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
        ExecStart = "${getExe' pkgs.tinyboot "tboot-bless-boot"} --esp-mnt=${config.boot.loader.efi.efiSysMountPoint} good";
      };
    };
  };
}
