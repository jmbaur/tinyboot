{
  withLoader ? true,
  withTools ? true,

  callPackage,
  lib,
  openssl,
  pkg-config,
  pkgsBuildBuild,
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
        ../../test/keys/tboot/key.der
      ];
    };

    strictDeps = true;

    nativeBuildInputs = [
      pkg-config
      pkgsBuildBuild.zig_0_13.hook
      xz
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
      xz --check=crc32 --lzma2=dict=512KiB $out/tboot-loader.cpio
    '';

    meta.platforms = lib.platforms.linux;
  }
)
