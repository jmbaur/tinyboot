{ name, system, lib, isoSystem, nixosSystem, writeShellScript, pkgsBuildBuild, stdenv, tinyboot-initramfs, tinyboot-kernel, }:
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
  initramfs = tinyboot-initramfs.override { debug = true; tty = systemConfig.console; };
  disk = toString (nixosSystem.extendModules {
    modules = [ ({ boot.kernelParams = [ "console=${systemConfig.console}" ]; }) ];
  }).config.system.build.qcow2;
  isoDrv = isoSystem.config.system.build.isoImage;
  iso = "${isoDrv}/iso/${isoDrv.isoName}";
in
writeShellScript "tinyboot-test-run.bash" ''
  export PATH=$PATH:${lib.makeBinPath (with pkgsBuildBuild; [ qemu swtpm ])}

  stop() { pkill swtpm; }
  trap stop EXIT SIGINT

  mkdir -p /tmp/mytpm1
  swtpm socket --tpmstate dir=/tmp/mytpm1 \
    --ctrl type=unixio,path=/tmp/mytpm1/swtpm-sock \
    --tpm2 &

  if ! test -f nixos-${system}.iso; then
    dd if=${iso} of=nixos-${system}.iso
  fi

  if ! test -f nixos-${name}.qcow2; then
    dd if=${disk}/nixos.qcow2 of=nixos-${name}.qcow2
  fi

  qemu-system-${stdenv.hostPlatform.qemuArch} \
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
    -chardev socket,id=chrtpm,path=/tmp/mytpm1/swtpm-sock \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0
    "$@"
''
