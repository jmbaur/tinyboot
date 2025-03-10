{
  kconfig ? "",
  lib,
  linux,
  stdenv,
}:
stdenv.mkDerivation {
  inherit (linux)
    pname
    version
    src
    buildInputs
    nativeBuildInputs
    depsBuildBuild
    makeFlags
    preInstall
    enableParallelBuilding
    ;
  patches = [ ./tpm-probe.patch ];
  postPatch = ''
    cp ${./boots_ascii_16.ppm} drivers/video/logo/logo_linux_vga16.ppm
  '';
  inherit kconfig;
  passAsFile = [ "kconfig" ];
  postConfigure = ''
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
      exit 1
    fi
  '';
  buildFlags = [
    "DTC_FLAGS=-@"
    "KBUILD_BUILD_VERSION=1-tinyboot"
  ];
  installFlags =
    [ "INSTALL_PATH=$(out)" ]
    ++ lib.optionals stdenv.hostPlatform.isAarch [
      "dtbs_install"
      "INSTALL_DTBS_PATH=$(out)/dtbs"
    ];
  outputs = [
    "out"
    "dev"
  ];
  postInstall = ''
    ln -s $out/${stdenv.hostPlatform.linux-kernel.target} $out/kernel
    install -Dt $dev .config vmlinux
  '';
}
