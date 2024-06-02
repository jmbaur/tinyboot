{
  callPackage,
  debug ? false,
  lib,
  openssl,
  pkg-config,
  pkgsBuildBuild,
  stdenv,
  xz,
  zigSrc,
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
    zigArgs = [
      "-Doptimize=ReleaseSafe"
      "-Dtarget=${stdenv.hostPlatform.qemuArch}-${stdenv.hostPlatform.parsed.kernel.name}-${zigLibc}"
      "-Ddynamic-linker=${stdenv.cc.bintools.dynamicLinker}"
      "-Dloglevel=${toString (if debug then 3 else 2)}" # https://github.com/ziglang/zig/blob/084c2cd90f79d5e7edf76b7ddd390adb95a27f0c/lib/std/log.zig#L78
      "--system"
      "${finalAttrs.deps}"
    ];
  in
  {
    pname = "tinyboot";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../build.zig
        ../build.zig.zon
        ../src
      ];
    };

    strictDeps = true;

    nativeBuildInputs = [
      (pkgsBuildBuild.zig_0_12.overrideAttrs (_: {
        src = zigSrc;
      }))
      xz
      pkg-config
    ];

    buildInputs = [ openssl ];

    doCheck = true;

    deps = callPackage ../build.zig.zon.nix { };

    # TODO(jared): make embedFile work better with the test key
    preConfigure = ''
      ln -sf ${../test/keys/tboot/key.der} src/test_key
      export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
    '';

    buildPhase = ''
      runHook preBuild
      zig build ${toString zigArgs}
      runHook postBuild
    '';

    checkPhase = ''
      runHook preCheck
      zig build test ${toString zigArgs}
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      zig build install --prefix $out ${toString zigArgs}
      xz --check=crc32 --lzma2=dict=512KiB $out/tboot-loader.cpio
      runHook postInstall
    '';

    meta.platforms = lib.platforms.linux;
  }
)
