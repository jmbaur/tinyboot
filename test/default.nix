{ nixpkgs, system, pkgsBuildBuild, stdenv, substituteAll, tinyboot-initramfs, tinyboot-kernel, ... }:
let
  config = builtins.getAttr stdenv.hostPlatform.system {
    x86_64-linux = {
      qemuFlags = "";
      console = "ttyS0";
      module = modulesPath: "${modulesPath}/installer/sd-card/sd-image-x86_64.nix";
    };
    aarch64-linux = {
      qemuFlags = "-M virt";
      console = "ttyAMA0";
      module = modulesPath: "${modulesPath}/installer/sd-card/sd-image-aarch64.nix";
    };
  };
in
substituteAll {
  src = ./run.bash;
  isExecutable = true;
  path = with pkgsBuildBuild; [ zstd qemu ];
  inherit (pkgsBuildBuild) bash;
  inherit (config) console qemuFlags;
  kernel = "${tinyboot-kernel}/${stdenv.hostPlatform.linux-kernel.target}";
  initrd = "${tinyboot-initramfs}/initrd";
  drive = toString (
    (nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ({ modulesPath, ... }: {
          imports = [ (config.module modulesPath) ];
          specialisation.other.configuration.boot.kernelParams = [ "console=tty" ];
          system.stateVersion = "23.05";
        })
      ];
    }).config.system.build.sdImage
  );
}
