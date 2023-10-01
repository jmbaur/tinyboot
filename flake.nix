{
  description = "A small linuxboot payload for coreboot";
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    coreboot = {
      url = "git+https://github.com/jmbaur/coreboot?ref=tinyboot&submodules=1";
      flake = false;
    };
  };
  outputs = inputs: with inputs;
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
      });
    in
    {
      nixosModules.default = {
        imports = [ ./module.nix ];
        nixpkgs.overlays = [ self.overlays.default ];
      };
      nixosConfigurations =
        let
          baseConfig = forAllSystems ({ system, ... }: {
            imports = [
              ({ nixpkgs.hostPlatform = system; })
              self.nixosModules.default
              ./test/module.nix
            ];
          });
          extend = extension: nixpkgs.lib.mapAttrs'
            (system: baseConfig: nixpkgs.lib.nameValuePair "${extension}-${system}" (nixpkgs.lib.nixosSystem {
              modules = [ baseConfig ./test/${extension}.nix ];
            }));
        in
        nixpkgs.lib.foldAttrs (curr: acc: acc // curr) { } (map (b: extend b baseConfig) [ "bls" ]);
      overlays.default = final: prev: {
        tinyboot = prev.pkgsStatic.callPackage ./. { };
        tinybootKernelPatches = prev.lib.mapAttrs (config: _: ./kernel-configs/${config}) (builtins.readDir ./kernel-configs);
        flashrom-cros = prev.callPackage ./flashrom-cros.nix { };
        libpayload = prev.callPackage ./libpayload.nix { src = inputs.coreboot; flashrom = final.flashrom-cros; };
        buildCoreboot = prev.callPackage ./coreboot.nix { src = inputs.coreboot; flashrom = final.flashrom-cros; };
        coreboot = import ./boards.nix final;
        kernelPatches = prev.kernelPatches // {
          ima_tpm_early_init = { name = "ima_tpm_early_init"; patch = ./patches/linux-tpm-probe.patch; };
        };
      };
      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.tinyboot.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.stdenv.cc ];
          env.CARGO_BUILD_TARGET = pkgs.pkgsStatic.stdenv.hostPlatform.config;
        });
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
                    x86_64-linux = pkgs.pkgsCross.gnu64;
                    aarch64-linux = pkgs.pkgsCross.aarch64-multiplatform;
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
