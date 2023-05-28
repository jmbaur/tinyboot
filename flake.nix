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
          baseConfig = forAllSystems ({ system, ... }: {
            imports = [
              ({ nixpkgs.hostPlatform = system; nixpkgs.overlays = [ self.overlays.default ]; })
              ./test/module.nix
            ];
          });
          extend = extension: nixpkgs.lib.mapAttrs'
            (system: baseConfig: nixpkgs.lib.nameValuePair "${extension}-${system}" (nixpkgs.lib.nixosSystem {
              modules = [ baseConfig ./test/${extension}.nix ];
            }));
        in
        nixpkgs.lib.foldAttrs (curr: acc: acc // curr) { } (map (b: extend b baseConfig) [ "bls" "grub" "extlinux" ]);
      overlays.default = final: prev: {
        flashrom-cros = prev.callPackage ./flashrom.nix { };
        wolftpm = prev.callPackage ./wolftpm.nix { };
        tinyboot = prev.callPackage ./tinyboot { };
        tinyboot-client = prev.callPackage ./tinyboot { clientOnly = true; };
        coreboot = prev.callPackage ./boards {
          buildFitImage = prev.callPackage ./fitimage { };
          buildCoreboot = prev.callPackage ./coreboot.nix { flashrom = final.flashrom-cros; };
        };
      };
      devShells = forAllSystems ({ pkgs, ... }: {
        default = with pkgs; mkShell {
          inputsFrom = [ tinyboot ];
          nativeBuildInputs = [ bashInteractive grub2 cargo-insta rustfmt cargo-watch cargo-edit clippy ];
          VERIFIED_BOOT_PUBLIC_KEY = ./test/keys/pubkey;
        };
      });
      legacyPackages = forAllSystems ({ pkgs, ... }: pkgs);
      apps = forAllSystems ({ pkgs, system, ... }: (pkgs.lib.concatMapAttrs
        (testName: nixosSystem:
          let
            testScript = {
              type = "app";
              program =
                let
                  myPkgs = if nixosSystem.config.nixpkgs.hostPlatform.system == system then pkgs else {
                    x86_64-linux = myPkgs.pkgsCross.gnu64;
                    aarch64-linux = myPkgs.pkgsCross.aarch64-multiplatform;
                  }.${nixosSystem.config.nixpkgs.hostPlatform.system};
                in
                toString (myPkgs.callPackage ./test { inherit testName; });
            };
            makeTestDiskScript = {
              type = "app";
              program = toString (pkgs.writeShellScript "make-disk-image" ''
                dd if=${nixosSystem.config.system.build.qcow2}/nixos.qcow2 of=nixos-${testName}.qcow2
              '');
            };
          in
          {
            "${testName}-run" = testScript;
            "${testName}-disk" = makeTestDiskScript;
          })
        self.nixosConfigurations) // {
        disk = self.apps.${system}."bls-${system}-disk";
        default = self.apps.${system}."bls-${system}-run";
      });
    };
}
