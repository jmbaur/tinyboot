{
  description = "A small initramfs for linuxboot";
  inputs = {
    crane.inputs.nixpkgs.follows = "nixpkgs";
    crane.url = "github:ipetkov/crane";
    nixpkgs.url = "nixpkgs/nixos-unstable";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    rust-overlay.url = "github:oxalica/rust-overlay";

    # TODO(jared): delete if/when merged
    nixpkgs-extlinux-specialisation.url = "github:jmbaur/nixpkgs/extlinux-specialisation";
  };
  outputs = inputs: with inputs;
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
      });
    in
    {
      nixosConfigurations =
        let
          base = forAllSystems ({ system, ... }: nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              ({ modulesPath, ... }: {
                disabledModules = [ "${modulesPath}/system/boot/loader/generic-extlinux-compatible" ];
                imports = [ "${nixpkgs-extlinux-specialisation}/nixos/modules/system/boot/loader/generic-extlinux-compatible" ];
              })
              ./test/module.nix
            ];
          });
          extend = extension: nixpkgs.lib.mapAttrs'
            (system: config: nixpkgs.lib.nameValuePair "${extension}-${system}" (config.extendModules {
              modules = [ ./test/${extension}.nix ];
            }));
        in
        nixpkgs.lib.foldAttrs (curr: acc: acc // curr) { } (map (b: extend b base) [ "grub" "extlinux" "iso" ]);
      overlays.default = nixpkgs.lib.composeManyExtensions [
        rust-overlay.overlays.default
        (final: prev: {
          wolftpm = prev.callPackage ./wolftpm.nix { };
          tinyboot = prev.callPackage ./. { inherit crane; };
          tinyboot-kernel = prev.callPackage ./kernel.nix { };
          tinyboot-initramfs = prev.callPackage ./initramfs.nix {
            inherit (final) tinyboot; kernel = final.tinyboot-kernel;
          };
        })
      ];
      devShells = forAllSystems ({ pkgs, ... }: {
        default = with pkgs; mkShellNoCC ({
          inputsFrom = [ tinyboot ];
          nativeBuildInputs = [ bashInteractive grub2 cargo-insta ];
        } // lib.optionalAttrs (tinyboot?env) { inherit (tinyboot) env; });
      });
      packages = forAllSystems ({ pkgs, ... }: {
        default = pkgs.tinyboot;
        initramfs = pkgs.tinyboot-initramfs;
        kernel = pkgs.tinyboot-kernel;
        wolftpm = pkgs.wolftpm;
      });
      apps = forAllSystems ({ pkgs, system, ... }: (pkgs.lib.mapAttrs'
        (name: nixosSystem:
          pkgs.lib.nameValuePair name {
            type = "app";
            program =
              if nixosSystem.config.nixpkgs.system == system then
                toString
                  (pkgs.callPackage ./test {
                    inherit name nixosSystem;
                    isoSystem = self.nixosConfigurations."iso-${system}";
                  })
              else
                let
                  pkgsCross = {
                    x86_64-linux = pkgs.pkgsCross.gnu64;
                    aarch64-linux = pkgs.pkgsCross.aarch64-multiplatform;
                  }.${nixosSystem.config.nixpkgs.system};
                in
                toString (pkgsCross.callPackage ./test {
                  inherit name nixosSystem;
                  isoSystem = self.nixosConfigurations."iso-${system}";
                });
          })
        self.nixosConfigurations) // { default = self.apps.${system}."grub-${system}"; });
    };
}
