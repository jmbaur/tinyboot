{ name, system, isoSystem, nixosSystem, writeShellScript, lib, pkgsBuildBuild, stdenv, substituteAll, tinyboot-initramfs, tinyboot-kernel, ... }:
let
  systemConfig = builtins.getAttr stdenv.hostPlatform.system {
    x86_64-linux = {
      qemuFlags = [ ];
      console = "ttyS0";
    };
    aarch64-linux = {
      qemuFlags = [ "-M" "virt" "-cpu" "cortex-a53" ];
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
  isoDrv = isoSystem.config.system.build.isoImage;
  iso = "${isoDrv}/iso/${isoDrv.isoName}";
in
writeShellScript "tinyboot-test-run.bash" ''
  if ! test -f nixos-${system}.iso; then
    dd if=${iso} of=nixos-${system}.iso
  fi

  if ! test -f nixos-${name}.qcow2; then
    dd if=${disk}/nixos.qcow2 of=nixos-${name}.qcow2
  fi

  ${pkgsBuildBuild.qemu}/bin/qemu-system-${stdenv.hostPlatform.qemuArch} \
    ${toString systemConfig.qemuFlags} \
    -nographic \
    -smp 2 \
    -m 2G \
    -kernel ${tinyboot-kernel}/${stdenv.hostPlatform.linux-kernel.target} \
    -initrd ${initramfs}/initrd \
    -append console=${systemConfig.console} \
    -device nec-usb-xhci,id=xhci \
    -device usb-storage,bus=xhci.0,drive=stick \
    -drive if=none,id=stick,format=raw,file=nixos-${system}.iso \
    -drive if=virtio,file=nixos-${name}.qcow2,format=qcow2,media=disk \
    "$@"
''
