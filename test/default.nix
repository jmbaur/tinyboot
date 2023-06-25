{ testName, lib, substituteAll, pkgsBuildBuild, stdenv, coreboot }:
let
  qemuFlags = toString (builtins.getAttr stdenv.hostPlatform.qemuArch {
    x86_64 = [ "-M q35" ] ++ lib.optional (stdenv.hostPlatform == stdenv.buildPlatform) "-enable-kvm";
    aarch64 = [ "-M virt,secure=on" "-cpu cortex-a53" ]; # kvm not available with machine settings secure=on
  });
  corebootROM = coreboot."qemu-${stdenv.hostPlatform.qemuArch}";
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
