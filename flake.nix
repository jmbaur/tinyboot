{
  description = "A small linuxboot payload for coreboot";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = inputs: {
    formatter = inputs.nixpkgs.lib.mapAttrs (_: pkgs: pkgs.nixfmt-rfc-style) inputs.self.legacyPackages;
    nixosModules.default = {
      imports = [ ./nixos-module.nix ];
      nixpkgs.overlays = [ inputs.self.overlays.default ];
    };
    overlays.default =
      final: prev:
      (
        {
          tinybootTools = final.pkgsStatic.callPackage ./pkgs/tinyboot {
            withLoader = false;
            withTools = true;
          };
          tinybootLoader = final.pkgsStatic.callPackage ./pkgs/tinyboot {
            withLoader = true;
            withTools = false;
            tinybootTools = final.buildPackages.pkgsStatic.tinybootTools; # TODO(jared): this shouldn't be needed
          };
          armTrustedFirmwareMT8183 = final.callPackage ./pkgs/arm-trusted-firmware-cros {
            platform = "mt8183";
          };
          armTrustedFirmwareMT8192 = final.callPackage ./pkgs/arm-trusted-firmware-cros {
            platform = "mt8192";
          };
          armTrustedFirmwareSC7180 = final.callPackage ./pkgs/arm-trusted-firmware-cros {
            platform = "sc7180";
          };
          flashrom-cros = final.callPackage ./pkgs/flashrom-cros { };
          kernelPatches = prev.kernelPatches // {
            ima_tpm_early_init = {
              name = "ima_tpm_early_init";
              patch = ./pkgs/linux/tpm-probe.patch;
            };
          };
        }
        // import ./boards.nix {
          pkgs = final;
          inherit (prev) lib;
        }
      );
    legacyPackages =
      inputs.nixpkgs.lib.genAttrs
        [
          "aarch64-linux"
          "x86_64-linux"
        ]
        (
          system:
          import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.self.overlays.default ];
          }
        );
    devShells = inputs.nixpkgs.lib.mapAttrs (_: pkgs: {
      default = pkgs.mkShell {
        inputsFrom = [ pkgs.tinybootLoader ];
        packages = [
          pkgs.qemu
          pkgs.swtpm
        ] ++ pkgs.tinybootLoader.depsBuildBuild; # depsBuildBuild not inherited by inputsFrom
        env.TINYBOOT_KERNEL = ''${pkgs."tinyboot-qemu-${pkgs.stdenv.hostPlatform.qemuArch}".linux}/kernel'';
      };
    }) inputs.self.legacyPackages;
    checks = inputs.nixpkgs.lib.mapAttrs (_: pkgs: {
      disk = pkgs.callPackage ./tests/disk { };
      ymodem = pkgs.callPackage ./tests/ymodem { };
    }) inputs.self.legacyPackages;
    hydraJobs = inputs.self.checks;
  };
}
