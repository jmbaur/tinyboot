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
      nixosConfigurations = nixpkgs.lib.mapAttrs'
        (system: config: nixpkgs.lib.nameValuePair "extlinux-${system}" (config.extendModules {
          modules = [ ./test/extlinux.nix ];
        }))
        (forAllSystems ({ system, ... }: nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ({ modulesPath, ... }: {
              disabledModules = [ "${modulesPath}/system/boot/loader/generic-extlinux-compatible" ];
              imports = [ "${nixpkgs-extlinux-specialisation}/nixos/modules/system/boot/loader/generic-extlinux-compatible" ];
            })
            ./test/module.nix
          ];
        }));
      overlays.default = nixpkgs.lib.composeManyExtensions [
        rust-overlay.overlays.default
        (final: prev: {
          tinyboot = prev.callPackage ./. { inherit crane; };
          tinyboot-initramfs = prev.callPackage ./initramfs.nix { inherit (final) tinyboot; };
          tinyboot-kernel = prev.callPackage ./kernel.nix { };
        })
      ];
      devShells = forAllSystems ({ pkgs, ... }: {
        default = with pkgs; mkShell ({
          inputsFrom = [ tinyboot ];
          nativeBuildInputs = [ grub2 cargo-watch ];
        } // tinyboot.env);
      });
      packages = forAllSystems ({ pkgs, ... }: {
        default = pkgs.tinyboot;
        initramfs = pkgs.tinyboot-initramfs;
        kernel = pkgs.tinyboot-kernel;
      });
      apps = forAllSystems ({ pkgs, system, ... }: {
        default = { type = "app"; program = toString (pkgs.callPackage ./test { inherit (self) nixosConfigurations; }); };
        x86_64 = { type = "app"; program = toString (pkgs.pkgsCross.gnu64.callPackage ./test { inherit (self) nixosConfigurations; }); };
        aarch64 = { type = "app"; program = toString (pkgs.pkgsCross.aarch64-multiplatform.callPackage ./test { inherit (self) nixosConfigurations; }); };
      });
    };
}
