{ testName, lib, substituteAll, pkgsBuildBuild, stdenv, coreboot }:
let
  qemuFlags = toString ((builtins.getAttr stdenv.hostPlatform.qemuArch {
    x86_64 = [ "-M q35" ];
    aarch64 = [ "-M virt" "-cpu cortex-a53" ];
  }) ++ lib.optional (stdenv.hostPlatform == stdenv.buildPlatform) "-enable-kvm");
  inherit (coreboot."qemu-${stdenv.hostPlatform.qemuArch}") linux initrd;
in
substituteAll {
  name = "tinyboot-test-run.bash";
  src = ./test.bash;
  isExecutable = true;
  extraPath = lib.makeBinPath (with pkgsBuildBuild; [ qemu swtpm ]);
  qemu = "qemu-system-${stdenv.hostPlatform.qemuArch}";
  kernelFile = stdenv.hostPlatform.linux-kernel.target;
  inherit (stdenv.hostPlatform) system;
  inherit qemuFlags linux initrd testName;
}
