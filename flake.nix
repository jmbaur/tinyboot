{
  description = "A kexec-based bootloader";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs.lib)
        genAttrs
        mapAttrs
        ;
    in
    {
      nixosModules.default = {
        imports = [ ./nixos ];
        nixpkgs.overlays = [ inputs.self.overlays.default ];
      };

      overlays.default = final: prev: ({
        tinyboot = final.callPackage ./package.nix { };
      });

      legacyPackages = genAttrs [ "armv7l-linux" "aarch64-linux" "x86_64-linux" ] (
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
            pkgs.zig_0_14
          ];
          env.TINYBOOT_KERNEL =
            with inputs.self.checks.${system}.disk.nodes.machine.system;
            ''${build.tinybootKernel}/${boot.loader.kernelFile}'';
        };
      }) inputs.self.legacyPackages;

      checks = mapAttrs (
        _: pkgs:
        let
          cross =
            {
              "x86_64-linux" = "gnu64";
              "aarch64-linux" = "aarch64-multiplatform";
              "armv7l-linux" = "armv7l-hf-multiplatform";
            }
            .${pkgs.stdenv.hostPlatform.system};
        in
        {
          disk = pkgs.callPackage ./tests/disk { };
          ymodem = pkgs.callPackage ./tests/ymodem { };
          tinyboot = pkgs.tinyboot;
          tinybootCross = pkgs.pkgsCross.${cross}.tinyboot;
        }
      ) inputs.self.legacyPackages;

      hydraJobs = inputs.self.checks;
    };
}
