{
  description = "A kexec-based bootloader";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs.lib)
        evalModules
        genAttrs
        mapAttrs
        recursiveUpdate
        ;
    in
    {
      nixosModules.default = {
        imports = [ ./nixos-module.nix ];
        nixpkgs.overlays = [ inputs.self.overlays.default ];
      };

      overlays.default = final: prev: ({
        tinybootTools = final.pkgsStatic.callPackage ./package.nix {
          withLoader = false;
          withTools = true;
        };
        tinybootLoader = final.pkgsStatic.callPackage ./package.nix {
          withLoader = true;
          withTools = false;
          tinybootTools = final.buildPackages.pkgsStatic.tinybootTools; # TODO(jared): this shouldn't be needed
        };
        kernelPatches = prev.kernelPatches // {
          ima_tpm_early_init = {
            name = "ima_tpm_early_init";
            patch = ./modules/standalone/linux/tpm-probe.patch;
          };
        };
      });

      legacyPackages = genAttrs [ "aarch64-linux" "x86_64-linux" ] (
        system:
        import inputs.nixpkgs {
          inherit system;
          overlays = [ inputs.self.overlays.default ];
        }
      );

      packages =
        genAttrs
          [
            "aarch64-linux"
            "x86_64-linux"
          ]
          (
            system:
            mapAttrs (
              name: _:
              let
                eval = evalModules {
                  modules = [
                    ./modules/standalone
                    ./examples/${name}
                    (
                      { config, lib, ... }:
                      let
                        localSystem = lib.systems.elaborate system;
                        crossSystem = lib.systems.elaborate config.hostPlatform;
                      in
                      {
                        _module.args.pkgs = import inputs.nixpkgs (
                          {
                            localSystem = system;
                            overlays = [ inputs.self.overlays.default ];
                          }
                          // lib.optionalAttrs (!(lib.systems.equals localSystem crossSystem)) {
                            crossSystem = config.hostPlatform;
                          }
                        );
                      }
                    )
                  ];
                };
              in
              eval._module.args.pkgs.symlinkJoin {
                inherit name;
                paths = builtins.attrValues eval.config.build;
              }
            ) (builtins.readDir ./examples)
          );

      devShells = mapAttrs (system: pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ pkgs.tinybootLoader ];
          packages = [
            pkgs.qemu
            pkgs.swtpm
          ] ++ pkgs.tinybootLoader.depsBuildBuild; # depsBuildBuild not inherited by inputsFrom
          env.TINYBOOT_KERNEL =
            with inputs.self.checks.${system}.disk.nodes.machine.tinyboot.build;
            ''${linux}/${linux.kernelFile}'';
        };
      }) inputs.self.legacyPackages;

      checks = mapAttrs (_: pkgs: {
        disk = pkgs.callPackage ./tests/disk { };
        ymodem = pkgs.callPackage ./tests/ymodem { };
      }) inputs.self.legacyPackages;

      hydraJobs = recursiveUpdate inputs.self.checks inputs.self.packages;
    };
}
