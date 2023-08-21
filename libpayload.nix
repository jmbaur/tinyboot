{ src, pkgsBuildBuild, stdenvNoCC, pkg-config, flashrom, openssl }:
let
  toolchainArch = { i386 = "i386"; x86_64 = "i386"; arm64 = "aarch64"; arm = "arm"; riscv = "riscv"; powerpc = "ppc64"; }.${stdenvNoCC.hostPlatform.linuxArch};
  toolchain = pkgsBuildBuild.coreboot-toolchain.${toolchainArch};
  defconfig = { i386 = "defconfig"; x86_64 = "defconfig"; arm64 = "config.arm64-generic"; arm = "defconfig-arm"; riscv = "defconfig"; powerpc = "defconfig"; }.${stdenvNoCC.hostPlatform.linuxArch};
in
stdenvNoCC.mkDerivation {
  pname = "libpayload";
  version = src.shortRev or src.dirtyShortRev; # allow for --override-input
  src = "${src}";
  postPatch = ''
    patchShebangs util 3rdparty/vboot/scripts payloads/libpayload
  '';
  configurePhase = ''
    runHook preConfigure
    make -C payloads/libpayload KBUILD_DEFCONFIG=configs/${defconfig} defconfig
    runHook postConfigure
  '';
  depsBuildBuild = [ pkgsBuildBuild.stdenv.cc ];
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ flashrom openssl ];
  makeFlags = [ "-C" "payloads/libpayload" "XGCCPATH=${toolchain}/bin/" ];
  installFlags = [ "DESTDIR=$(out)" ];
  # also build the sample program
  postInstall = ''
    make -C payloads/libpayload/sample LIBPAYLOAD_DIR=$out/libpayload CC=${toolchain}/bin/${toolchainArch}-elf-gcc
    install -Dm755 payloads/libpayload/sample/hello.elf $out/libexec/hello.elf
  '';
  stripDebugFlags = [ "--strip-all" ];
}
