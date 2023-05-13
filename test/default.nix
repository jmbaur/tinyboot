{ testName, lib, nixosSystem, substituteAll, pkgsBuildBuild, stdenv, coreboot }:
let
  systemConfig = builtins.getAttr stdenv.hostPlatform.qemuArch {
    x86_64 = { qemuFlags = [ ]; console = "ttyS0"; };
    aarch64 = { qemuFlags = [ "-M" "virt,secure=on" "-cpu" "cortex-a53" ]; console = "ttyAMA0"; };
  };
  disk = toString (nixosSystem.extendModules {
    modules = [ ({ boot.kernelParams = [ "console=${systemConfig.console}" ]; }) ];
  }).config.system.build.qcow2;
  corebootROM = coreboot."qemu-${stdenv.hostPlatform.qemuArch}";
  qemuFlags = toString (systemConfig.qemuFlags ++ lib.optional (stdenv.hostPlatform == stdenv.buildPlatform) "-enable-kvm");
in
substituteAll {
  name = "tinyboot-test-run.bash";
  src = ./test.bash;
  isExecutable = true;
  extraPath = lib.makeBinPath (with pkgsBuildBuild; [ qemu swtpm ]);
  qemu = "qemu-system-${stdenv.hostPlatform.qemuArch}";
  inherit (stdenv.hostPlatform) system;
  inherit qemuFlags corebootROM disk testName;
}
