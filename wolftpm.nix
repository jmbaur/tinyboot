{ lib, stdenv, fetchFromGitHub, wolfssl, automake, autoconf, libtool }:
stdenv.mkDerivation rec {
  pname = "wolftpm";
  version = "2.7.0";
  src = fetchFromGitHub {
    owner = "wolfSSL";
    repo = "wolfTPM";
    rev = "v${version}";
    hash = "sha256-HaQPMwzCvv1TqNE70d470y3HsYkQJFKYhtxtgFFXdco=";
  };
  strictDeps = true;
  preConfigure = ''
    ./autogen.sh
  '';
  configureFlags = [ "--enable-devtpm" ];
  outputs = [ "dev" "doc" "lib" "out" ];
  propagatedBuildInputs = [ wolfssl ];
  nativeBuildInputs = [ automake autoconf libtool ];
  postInstall = ''
    # fix recursive cycle:
    # wolftpm-config points to dev, dev propagates bin
    moveToOutput bin/wolftpm-config "$dev"
    # moveToOutput also removes "$out" so recreate it
    mkdir -p "$out"
  '';
  doCheck = false;
  meta = with lib; {
    description = "A highly portable TPM 2.0 library, designed for embedded use";
    homepage = "https://www.wolfssl.com/products/wolftpm/";
    platforms = platforms.all;
    license = licenses.gpl2Plus;
    maintainers = with maintainers; [ jmbaur ];
  };
}
