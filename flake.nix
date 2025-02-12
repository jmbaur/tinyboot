{
  description = "A small linuxboot payload for coreboot";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zls.inputs.nixpkgs.follows = "nixpkgs";
    zls.url = "github:zigtools/zls";
  };

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
          zigForTinyboot = inputs.zig-overlay.packages.${final.stdenv.buildPlatform.system}.master;
          tinybootTools = final.pkgsStatic.callPackage ./pkgs/tinyboot {
            withLoader = false;
            withTools = true;
          };
          tinybootLoader = final.pkgsStatic.callPackage ./pkgs/tinyboot {
            withLoader = true;
            withTools = false;
            tinybootTools = final.buildPackages.pkgsStatic.tinybootTools;
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
          inputs.zls.packages.${pkgs.stdenv.hostPlatform.system}.default
          pkgs.qemu
          pkgs.swtpm
        ];
        env.TINYBOOT_KERNEL = ''${pkgs."tinyboot-qemu-${pkgs.stdenv.hostPlatform.qemuArch}".linux}/kernel'';
      };
    }) inputs.self.legacyPackages;
    checks = inputs.nixpkgs.lib.mapAttrs (_: pkgs: {
      disk = pkgs.callPackage ./tests/disk { };
      ymodem = pkgs.callPackage ./tests/ymodem { };
    }) inputs.self.legacyPackages;
  };
}
