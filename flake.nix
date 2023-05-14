{
  description = "A small linuxboot payload for coreboot";
  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";
  outputs = inputs: with inputs;
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
      });
    in
    {
      nixosConfigurations =
        let
          base = forAllSystems ({ system, ... }: nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [ ./test/module.nix ];
          });
          extend = extension: nixpkgs.lib.mapAttrs'
            (system: config: nixpkgs.lib.nameValuePair "${extension}-${system}" (config.extendModules {
              modules = [ ./test/${extension}.nix ];
            }));
        in
        nixpkgs.lib.foldAttrs (curr: acc: acc // curr) { } (map (b: extend b base) [ "bls" "grub" "extlinux" ]);
      overlays.default = final: prev: {
        flashrom = prev.callPackage ./flashrom.nix { };
        wolftpm = prev.callPackage ./wolftpm.nix { };
        coreboot = prev.callPackage ./boards {
          buildFitImage = prev.callPackage ./fitimage { };
          buildCoreboot = prev.callPackage ./coreboot.nix { };
        };
      };
      devShells = forAllSystems ({ pkgs, ... }: {
        default = with pkgs; mkShell {
          inputsFrom = [ (callPackage ./tinyboot { }) ];
          nativeBuildInputs = [ bashInteractive grub2 cargo-insta rustfmt cargo-edit clippy ];
          VERIFIED_BOOT_PUBLIC_KEY = ./test/keys/pubkey;
        };
      });
      legacyPackages = forAllSystems ({ pkgs, ... }: pkgs);
      apps = forAllSystems ({ pkgs, system, ... }: (pkgs.lib.mapAttrs'
        (testName: nixosSystem:
          pkgs.lib.nameValuePair testName {
            type = "app";
            program =
              if nixosSystem.config.nixpkgs.system == system then
                toString (pkgs.callPackage ./test { inherit testName nixosSystem; })
              else
                let
                  pkgsCross = {
                    x86_64-linux = pkgs.pkgsCross.gnu64;
                    aarch64-linux = pkgs.pkgsCross.aarch64-multiplatform;
                  }.${nixosSystem.config.nixpkgs.system};
                in
                toString (pkgsCross.callPackage ./test { inherit testName nixosSystem; });
          })
        self.nixosConfigurations) // { default = self.apps.${system}."bls-${system}"; });
    };
}
