{
  description = "A kexec-based bootloader";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs.lib)
        attrNames
        filter
        genAttrs
        listToAttrs
        mapAttrs
        optionalAttrs
        ;
    in
    {
      nixosModules.default = {
        imports = [ ./nixos ];
        nixpkgs.overlays = [ inputs.self.overlays.default ];
      };

      overlays.default = final: prev: {
        tinyboot = final.callPackage ./package.nix { };
      };

      legacyPackages = genAttrs [ "aarch64-linux" "x86_64-linux" "aarch64-darwin" ] (
        system:
        import inputs.nixpkgs {
          inherit system;
          overlays = [ inputs.self.overlays.default ];
        }
      );

      devShells = mapAttrs (system: pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.lldb
            pkgs.qemu
            pkgs.swtpm
            pkgs.zig_0_15
          ];
          # NOTE: Optionally populating $TINYBOOT_KERNEL so that darwin
          # builders can do zig builds without pulling in the linux kernel
          # (which does not build on darwin).
          env = optionalAttrs pkgs.stdenv.buildPlatform.isLinux {
            TINYBOOT_KERNEL =
              with inputs.self.checks.${system}.disk.nodes.machine.system;
              ''${build.tinybootKernel}/${boot.loader.kernelFile}'';
          };
        };
      }) inputs.self.legacyPackages;

      checks = mapAttrs (
        system: pkgs:
        {
          disk = pkgs.callPackage ./tests/disk { };
          ymodem = pkgs.callPackage ./tests/ymodem { };
          tinybootNative = pkgs.tinyboot;
        }
        // listToAttrs (
          map
            (
              system:
              let
                pkgs' =
                  pkgs.pkgsCross.${
                    {
                      "riscv64-linux" = "riscv64";
                      "x86_64-linux" = "gnu64";
                      "aarch64-linux" = "aarch64-multiplatform";
                      "armv7l-linux" = "armv7l-hf-multiplatform";
                    }
                    .${system}
                  };
              in
              {
                name = "tinybootCross-${pkgs'.stdenv.hostPlatform.qemuArch}";
                value = pkgs'.tinyboot;
              }
            )
            [
              "armv7l-linux"
              "aarch64-linux"
              "x86_64-linux"
            ]
        )
      ) inputs.self.legacyPackages;

      hydraJobs = inputs.self.checks;
    };
}
