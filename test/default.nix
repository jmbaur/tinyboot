{ name, nixosSystem, writeShellScript, lib, pkgsBuildBuild, stdenv, substituteAll, tinyboot-initramfs, tinyboot-kernel, ... }:
let
  systemConfig = builtins.getAttr stdenv.hostPlatform.system {
    x86_64-linux = {
      qemuFlags = [ ];
      console = "ttyS0";
    };
    aarch64-linux = {
      qemuFlags = [ "-M" "virt" ];
      console = "ttyAMA0";
    };
  };
  initramfs = tinyboot-initramfs.override {
    tinybootLog = "debug";
    tinybootTTY = systemConfig.console;
  };
  disk = toString (nixosSystem.extendModules {
    modules = [ ({ boot.kernelParams = [ "console=${systemConfig.console}" ]; }) ];
  }).config.system.build.qcow2;
in
writeShellScript "tinyboot-test-run.bash" ''
  if ! test -f nixos-${name}.qcow2; then
    dd if=${disk}/nixos.qcow2 of=nixos-${name}.qcow2
  fi

  ${pkgsBuildBuild.qemu}/bin/qemu-system-${stdenv.hostPlatform.qemuArch} \
    ${toString systemConfig.qemuFlags} \
    -nographic \
    -m 2G \
    -kernel ${tinyboot-kernel}/${stdenv.hostPlatform.linux-kernel.target} \
    -initrd ${initramfs}/initrd \
    -append console=${systemConfig.console} \
    -drive if=virtio,file=nixos-${name}.qcow2,format=qcow2,media=disk
''
