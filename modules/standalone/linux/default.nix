{
  kconfig ? "",
  strict ? true,
  bc,
  bison,
  buildPackages,
  elfutils,
  fetchurl,
  flex,
  gmp,
  hexdump,
  kmod,
  lib,
  libmpc,
  mpfr,
  nettools,
  openssl,
  perl,
  python3Minimal,
  rsync,
  stdenv,
  ubootTools,
  zstd,
}:

let
  kernelFile =
    {
      arm = "zImage";
      arm64 = "Image";
      x86_64 = "bzImage";
    }
    .${stdenv.hostPlatform.linuxArch};
in
stdenv.mkDerivation (finalAttrs: {
  pname = "tinyboot-linux";
  version = "6.14.2";

  src = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${finalAttrs.version}.tar.xz";
    hash = "sha256-xcaCo1TqMZATk1elfTSnnlw3IhrOgjqTjhARa1d6Lhs=";
  };

  depsBuildBuild = [ buildPackages.stdenv.cc ];
  nativeBuildInputs = [
    bc
    bison
    elfutils
    flex
    gmp
    hexdump
    kmod
    libmpc
    mpfr
    nettools
    openssl
    perl
    python3Minimal
    rsync
    ubootTools
    zstd
  ];

  buildFlags = [
    "DTC_FLAGS=-@"
    "KBUILD_BUILD_VERSION=1-tinyboot"
    kernelFile
  ];

  makeFlags = [
    "O=$(buildRoot)"
    "ARCH=${stdenv.hostPlatform.linuxArch}"
    "CROSS_COMPILE=${stdenv.cc.targetPrefix}"
  ];

  installFlags =
    [ "INSTALL_PATH=$(out)" ]
    ++ lib.optionals (with stdenv.hostPlatform; isAarch) [
      "dtbs_install"
      "INSTALL_DTBS_PATH=$(out)/dtbs"
    ];

  installTargets = [ (if kernelFile == "zImage" then "zinstall" else "install") ];

  hardeningDisable = [
    "bindnow"
    "format"
    "fortify"
    "stackprotector"
    "pic"
    "pie"
  ];

  strictDeps = true;
  enableParallelBuilding = true;

  patches = [ ./tpm-probe.patch ];

  inherit kconfig;
  passAsFile = [ "kconfig" ];

  configurePhase = ''
    runHook preConfigure

    cat $kconfigPath >all.config
    make -j$NIX_BUILD_CORES $makeFlags KCONFIG_ALLCONFIG=1 allnoconfig

    start_config=all.config
    end_config=.config

    missing=()
    while read -r line; do
      if ! grep --silent "$line" "$end_config"; then
        missing+=("$line")
      fi
    done <"$start_config"

    if [[ ''${#missing[@]} -gt 0 ]]; then
      echo
      for line in "''${missing[@]}"; do
        echo "\"$line\" not found in final config!"
      done
      echo
      ${lib.optionalString strict ''
        exit 1
      ''}
    fi

    buildFlagsArray+=("KBUILD_BUILD_TIMESTAMP=$(date -u -d @$SOURCE_DATE_EPOCH)")

    runHook postConfigure
  '';

  outputs = [
    "out"
    "dev"
  ];

  preInstall =
    let
      installkernel = buildPackages.writeShellScriptBin "installkernel" ''
        set -x
        echo $@
        cp -av $2 $4
        cp -av $3 $4
      '';
    in
    ''
      installFlagsArray+=("-j$NIX_BUILD_CORES")
      export HOME=${installkernel}
    '';

  postInstall = ''
    install -D -m0644 -t $dev .config vmlinux
  '';

  passthru = { inherit kernelFile; };
})
