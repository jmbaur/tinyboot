{ name, nixosSystem, writeShellScript, lib, pkgsBuildBuild, stdenv, substituteAll, tinyboot-initramfs, tinyboot-kernel, ... }:
let
  systemConfig = builtins.getAttr stdenv.hostPlatform.system {
    x86_64-linux = {
      qemuFlags = [ ];
      console = "ttyS0";
    };
    aarch64-linux = {
      qemuFlags = [ "-M" "virt" "-device" "virtio-gpu-pci" ];
      console = "ttyAMA0";
    };
  };
  initramfs = tinyboot-initramfs.override {
    tinybootLog = "trace";
    extraInittab = ''
      ${systemConfig.console}::respawn:/bin/sh
    '';
  };
  disk = toString (nixosSystem.extendModules {
    modules = [ ({ boot.kernelParams = [ "console=${systemConfig.console}" ]; }) ];
  }).config.system.build.qcow2;
in
writeShellScript "tinyboot-test-run.bash" ''
  test -f nixos-${name}.qcow2 || dd if=${disk}/nixos.qcow2 of=nixos-${name}.qcow2
  ${pkgsBuildBuild.qemu}/bin/qemu-system-${stdenv.hostPlatform.qemuArch} \
    ${toString systemConfig.qemuFlags} \
    -serial stdio \
    -m 2G \
    -kernel ${tinyboot-kernel}/${stdenv.hostPlatform.linux-kernel.target} \
    -initrd ${initramfs}/initrd \
    -append console=${systemConfig.console} \
    -drive if=virtio,file=nixos-${name}.qcow2,format=qcow2,media=disk
''
