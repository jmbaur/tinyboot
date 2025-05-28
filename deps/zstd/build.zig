const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("zstd", .{});
    const lib = b.addStaticLibrary(.{
        .name = "zstd",
        .target = target,
        .optimize = optimize,
    });

    lib.installHeadersDirectory(upstream.path("lib"), "", .{});

    lib.linkLibC();

    switch (optimize) {
        .Debug, .ReleaseSafe => lib.bundle_compiler_rt = true,
        else => lib.root_module.strip = true,
    }

    lib.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &.{
            "lib/common/debug.c",
            "lib/common/entropy_common.c",
            "lib/common/error_private.c",
            "lib/common/fse_decompress.c",
            "lib/common/pool.c",
            "lib/common/threading.c",
            "lib/common/xxhash.c",
            "lib/common/zstd_common.c",
            "lib/compress/fse_compress.c",
            "lib/compress/hist.c",
            "lib/compress/huf_compress.c",
            "lib/compress/zstd_compress.c",
            "lib/compress/zstd_compress_literals.c",
            "lib/compress/zstd_compress_sequences.c",
            "lib/compress/zstd_compress_superblock.c",
            "lib/compress/zstd_double_fast.c",
            "lib/compress/zstd_fast.c",
            "lib/compress/zstd_lazy.c",
            "lib/compress/zstd_ldm.c",
            "lib/compress/zstd_opt.c",
            "lib/compress/zstd_preSplit.c",
            "lib/compress/zstdmt_compress.c",
            "lib/dictBuilder/cover.c",
            "lib/dictBuilder/divsufsort.c",
            "lib/dictBuilder/fastcover.c",
            "lib/dictBuilder/zdict.c",
        },
        .flags = &.{"-DZSTD_MULTITHREAD"},
    });

    b.installArtifact(lib);
}
