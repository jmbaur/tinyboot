{ testName, lib, substituteAll, pkgsBuildBuild, stdenv, coreboot }:
let
  systemConfig = builtins.getAttr stdenv.hostPlatform.qemuArch {
    x86_64 = { qemuFlags = [ ]; };
    aarch64 = { qemuFlags = [ "-M" "virt,secure=on" "-cpu" "cortex-a53" ]; };
  };
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
  inherit qemuFlags corebootROM testName;
}
