{
  description = "A small linuxboot payload for coreboot";
  inputs = {
    coreboot.flake = false;
    coreboot.url = "git+https://github.com/coreboot/coreboot?ref=refs/tags/24.08&submodules=1";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
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
          buildCoreboot = import ./pkgs/coreboot {
            corebootSrc = inputs.coreboot.outPath;
            version = "24.08";
          };
          tinybootLoader = prev.callPackage ./pkgs/tinyboot {
            withLoader = true;
            withTools = false;
          };
          tinybootTools = prev.callPackage ./pkgs/tinyboot {
            withLoader = false;
            withTools = true;
          };
          armTrustedFirmwareMT8183 = prev.callPackage ./pkgs/arm-trusted-firmware-cros {
            platform = "mt8183";
          };
          armTrustedFirmwareMT8192 = prev.callPackage ./pkgs/arm-trusted-firmware-cros {
            platform = "mt8192";
          };
          armTrustedFirmwareSC7180 = prev.callPackage ./pkgs/arm-trusted-firmware-cros {
            platform = "sc7180";
          };
          flashrom-cros = prev.callPackage ./pkgs/flashrom-cros { };
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
        inputsFrom = [
          pkgs.tinybootLoader
          pkgs.tinybootTools
        ];
        packages = with pkgs; [
          swtpm
          qemu
          zon2nix
        ];
        # https://github.com/NixOS/nixpkgs/issues/270415
        shellHook = ''
          unset ZIG_GLOBAL_CACHE_DIR
        '';
        env.TINYBOOT_KERNEL = ''${pkgs."tinyboot-qemu-${pkgs.stdenv.hostPlatform.qemuArch}".linux}/kernel'';
      };
    }) inputs.self.legacyPackages;
    checks = inputs.nixpkgs.lib.mapAttrs (_: pkgs: {
      disk = pkgs.callPackage ./tests/disk { };
      ymodem = pkgs.callPackage ./tests/ymodem { };
    }) inputs.self.legacyPackages;
  };
}
