{ nixpkgs, system, stdenv, substituteAll, zstd, qemu, bash, tinyboot-initramfs, tinyboot-kernel, ... }:
let
  console = if stdenv.hostPlatform.system == "aarch64-linux" then "ttyAMA0" else "ttyS0";
in
substituteAll {
  src = ./run.bash;
  isExecutable = true;
  path = [ zstd qemu ];
  qemu = "${qemu}/bin/qemu-system-${stdenv.hostPlatform.qemuArch}";
  inherit bash;
  inherit console;
  kernel = "${tinyboot-kernel}/${stdenv.hostPlatform.linux-kernel.target}";
  initrd = "${tinyboot-initramfs}/initrd";
  drive = toString (
    (nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ({ modulesPath, ... }: {
          imports = [
            (if system == "aarch64-linux" then
              "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
            else if system == "x86_64-linux" then
              "${modulesPath}/installer/sd-card/sd-image-x86_64.nix"
            else throw "unsupported system")
          ];
          specialisation.other.configuration.boot.kernelParams = [ "console=tty" ];
          system.stateVersion = "23.05";
        })
      ];
    }).config.system.build.sdImage
  );
}
