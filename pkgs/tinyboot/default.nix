{
  withLoader ? true,
  withTools ? true,

  callPackage,
  lib,
  openssl,
  pkg-config,
  pkgsBuildBuild,
  pkgsBuildHost,
  runCommand,
  stdenv,
  xz,
}:
stdenv.mkDerivation (
  finalAttrs:
  let
    zigLibc =
      {
        "glibc" = "gnu";
        "musl" = "musl";
      }
      .${stdenv.hostPlatform.libc} or "none";
  in
  {
    pname = "tinyboot";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = ../../.;
      fileset = lib.fileset.unions [
        ../../build.zig
        ../../build.zig.zon
        ../../src
        ../../tests/keys/tboot/key.der
      ];
    };

    strictDeps = true;

    nativeBuildInputs = [
      pkgsBuildBuild.zig_0_13.hook
      xz
      pkg-config
      # Can remove when https://github.com/ziglang/zig/commit/d263f1ec0eb988f0e4ed1859351f5040f590996b is included in a release.
      (runCommand "pkg-config-for-zig" { } ''
        mkdir -p $out/bin; ln -s ${pkgsBuildHost.pkg-config}/bin/${stdenv.cc.targetPrefix}pkg-config $out/bin/pkg-config
      '')
    ];
    buildInputs = [ openssl ];

    doCheck = true;

    deps = callPackage ../../build.zig.zon.nix { };

    zigBuildFlags = [
      "-Dtarget=${stdenv.hostPlatform.qemuArch}-${stdenv.hostPlatform.parsed.kernel.name}-${zigLibc}"
      "-Ddynamic-linker=${stdenv.cc.bintools.dynamicLinker}"
      "-Dloader=${lib.boolToString withLoader}"
      "-Dtools=${lib.boolToString withTools}"
      "--system"
      "${finalAttrs.deps}"
    ];

    # TODO(jared): The checkPhase should already include the zigBuildFlags,
    # probably a nixpkgs bug.
    zigCheckFlags = finalAttrs.zigBuildFlags;

    postInstall = lib.optionalString withLoader ''
      xz --threads=$NIX_BUILD_CORES --check=crc32 --lzma2=dict=512KiB $out/tboot-loader.cpio
    '';

    meta.platforms = lib.platforms.linux;
  }
)
