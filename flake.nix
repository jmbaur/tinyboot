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
      nixosConfigurations.default = nixpkgs.lib.nixosSystem {
        modules = [ self.nixosModules.default ./test/module.nix ];
      };
      overlays.default = final: prev: {
        tinyboot = prev.pkgsStatic.callPackage ./. { };
        tinybootKernelConfigs = prev.lib.mapAttrs (config: _: ./kernel-configs/${config}) (builtins.readDir ./kernel-configs);
        flashrom-cros = prev.callPackage ./flashrom-cros.nix { };
        buildCoreboot = prev.callPackage ./coreboot.nix { src = inputs.coreboot; flashrom = final.flashrom-cros; };
        coreboot = import ./boards.nix final;
        kernelPatches = prev.kernelPatches // {
          ima_tpm_early_init = { name = "ima_tpm_early_init"; patch = ./patches/linux-tpm-probe.patch; };
        };
      };
      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.tinyboot.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ (with pkgs; [ just cpio makeInitrdNGTool xz ]);
        });
      });
      legacyPackages = forAllSystems ({ pkgs, ... }: pkgs);
      apps = forAllSystems ({ pkgs, system, ... }: (
        let
          nixosSystem = self.nixosConfigurations.default.extendModules {
            modules = [ ({ ... }: { nixpkgs.hostPlatform = system; }) ];
          };
        in
        {
          "${system}-disk" = {
            type = "app";
            program = toString (pkgs.writeShellScript "make-disk-image" ''
              dd status=progress if=${nixosSystem.config.system.build.qcow2}/nixos.qcow2 of=nixos-${system}.qcow2
            '');
          };
        }
      ) // {
        default = self.apps.${system}."${system}-disk";
      });
    };
}

