{
  debug ? false,
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
      ];
    };

    strictDeps = true;

    nativeBuildInputs = [
      pkgsBuildBuild.zig_0_13.hook
    ] ++ lib.optionals withLoader [ xz ] ++ lib.optionals withTools [ pkg-config ];
    buildInputs = lib.optionals withTools [ openssl ];

    doCheck = true;

    deps = callPackage ../../build.zig.zon.nix { };

    zigBuildFlags = [
      "-Dtarget=${stdenv.hostPlatform.qemuArch}-${stdenv.hostPlatform.parsed.kernel.name}-${zigLibc}"
      "-Ddynamic-linker=${stdenv.cc.bintools.dynamicLinker}"
      "-Dloglevel=${toString (if debug then 3 else 2)}" # https://github.com/ziglang/zig/blob/084c2cd90f79d5e7edf76b7ddd390adb95a27f0c/lib/std/log.zig#L78
      "-Dloader=${lib.boolToString withLoader}"
      "-Dtools=${lib.boolToString withTools}"
      "--system"
      "${finalAttrs.deps}"
    ];

    # TODO(jared): The checkPhase should already include the zigBuildFlags,
    # probably a nixpkgs bug.
    zigCheckFlags = finalAttrs.zigBuildFlags;

    # TODO(jared): make embedFile work better with the test key
    preConfigure = ''
      ln -sf ${../../test/keys/tboot/key.der} src/test_key
    '';

    postInstall = lib.optionalString withLoader ''
      xz --check=crc32 --lzma2=dict=512KiB $out/tboot-loader.cpio
    '';

    meta.platforms = lib.platforms.linux;
  }
)
