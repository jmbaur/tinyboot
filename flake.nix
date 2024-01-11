{
  description = "A small linuxboot payload for coreboot";
  inputs.nixpkgs.url = "github:jmbaur/nixpkgs/nixos-unstable"; # we use this for so we can get vpd
  outputs = inputs:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: inputs.nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = import inputs.nixpkgs { inherit system; overlays = [ inputs.self.overlays.default ]; };
      });
    in
    {
      nixosModules.default = {
        imports = [ ./module.nix ];
        nixpkgs.overlays = [ inputs.self.overlays.default ];
      };
      overlays.default = final: prev: {
        tinyboot = prev.callPackage ./pkgs/tinyboot.nix { };
        tinybootKernelConfigs = prev.lib.mapAttrs (config: _: ./kernel-configs/${config}) (builtins.readDir ./kernel-configs);
        armTrustedFirmwareMT8183 = prev.callPackage ./pkgs/arm-trusted-firmware-cros.nix { platform = "mt8183"; };
        armTrustedFirmwareMT8192 = prev.callPackage ./pkgs/arm-trusted-firmware-cros.nix { platform = "mt8192"; };
        armTrustedFirmwareSC7180 = prev.callPackage ./pkgs/arm-trusted-firmware-cros.nix { platform = "sc7180"; };
        flashrom-cros = prev.callPackage ./pkgs/flashrom-cros { };
        coreboot = import ./boards.nix final;
        kernelPatches = prev.kernelPatches // {
          ima_tpm_early_init = { name = "ima_tpm_early_init"; patch = ./pkgs/linux/tpm-probe.patch; };
        };
      };
      legacyPackages = forAllSystems ({ pkgs, ... }: pkgs);
      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          inputsFrom = [ pkgs.tinyboot ];
          env.TINYBOOT_KERNEL = ''${pkgs.coreboot."qemu-${pkgs.stdenv.hostPlatform.qemuArch}".config.build.linux}/kernel'';
        };
      });
      apps = forAllSystems ({ pkgs, system, ... }: (
        let
          nixosSystem = inputs.nixpkgs.lib.nixosSystem {
            modules = [ inputs.self.nixosModules.default ./test/module.nix ({ nixpkgs.hostPlatform = system; }) ];
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
        default = inputs.self.apps.${system}."${system}-disk";
      });
    };
}
