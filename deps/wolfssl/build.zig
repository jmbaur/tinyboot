const std = @import("std");

fn isX86(target: std.Build.ResolvedTarget) bool {
    return switch (target.result.cpu.arch) {
        .x86, .x86_64 => true,
        else => false,
    };
}

const base_cflags = [_][]const u8{
    "-DTFM_TIMING_RESISTANT",
    "-DECC_TIMING_RESISTANT",
    "-DWC_RSA_BLINDING",
    "-DNO_INLINE",
    "-DWOLFSSL_TLS13",
    "-DWC_RSA_PSS",
    "-DHAVE_TLS_EXTENSIONS",
    "-DHAVE_SNI",
    "-DHAVE_MAX_FRAGMENT",
    "-DHAVE_TRUNCATED_HMAC",
    "-DHAVE_ALPN",
    "-DHAVE_TRUSTED_CA",
    "-DHAVE_HKDF",
    "-DBUILD_GCM",
    "-DHAVE_AESCCM",
    "-DHAVE_SESSION_TICKET",
    "-DHAVE_CHACHA",
    "-DHAVE_POLY1305",
    "-DHAVE_ECC",
    "-DHAVE_FFDHE_2048",
    "-DHAVE_FFDHE_3072",
    "-DHAVE_FFDHE_4096",
    "-DHAVE_FFDHE_6144",
    "-DHAVE_FFDHE_8192",
    "-DHAVE_ONE_TIME_AUTH",
    "-DSESSION_INDEX",
    "-DSESSION_CERTS",
    "-DOPENSSL_EXTRA",
    "-DOPENSSL_ALL",
    "-DHAVE_PKCS7",
    "-DHAVE_X963_KDF",
    "-DHAVE_AES_KEYWRAP",
    "-DWOLFSSL_AES_DIRECT",
    "-DHAVE_SYS_TIME_H",
    "-DHAVE_PTHREAD",
    "-DWOLFSSL_SHA512",
    "-DWOLFSSL_CERT_GEN",
    "-DNO_DSA",
    "-DWOLFSSL_KEY_GEN",
};

const wolfssl_sources = &[_][]const u8{
    "src/bio.c",
    "src/conf.c",
    "src/crl.c",
    "src/dtls.c",
    "src/dtls13.c",
    "src/internal.c",
    "src/keys.c",
    "src/ocsp.c",
    "src/pk.c",
    "src/quic.c",
    "src/sniffer.c",
    "src/ssl.c",
    "src/ssl_asn1.c",
    "src/ssl_bn.c",
    "src/ssl_certman.c",
    "src/ssl_crypto.c",
    "src/ssl_load.c",
    "src/ssl_misc.c",
    "src/ssl_p7p12.c",
    "src/ssl_sess.c",
    "src/tls.c",
    "src/tls13.c",
    "src/wolfio.c",
    "src/x509.c",
    "src/x509_str.c",
};

const wolfcrypt_sources = &[_][]const u8{
    "wolfcrypt/src/aes.c",
    "wolfcrypt/src/arc4.c",
    "wolfcrypt/src/ascon.c",
    "wolfcrypt/src/asm.c",
    "wolfcrypt/src/asn.c",
    "wolfcrypt/src/blake2b.c",
    "wolfcrypt/src/blake2s.c",
    "wolfcrypt/src/camellia.c",
    "wolfcrypt/src/chacha.c",
    "wolfcrypt/src/chacha20_poly1305.c",
    "wolfcrypt/src/cmac.c",
    "wolfcrypt/src/coding.c",
    "wolfcrypt/src/compress.c",
    "wolfcrypt/src/cpuid.c",
    "wolfcrypt/src/cryptocb.c",
    "wolfcrypt/src/curve25519.c",
    "wolfcrypt/src/curve448.c",
    "wolfcrypt/src/des3.c",
    "wolfcrypt/src/dh.c",
    "wolfcrypt/src/dilithium.c",
    "wolfcrypt/src/dsa.c",
    "wolfcrypt/src/ecc.c",
    "wolfcrypt/src/ecc_fp.c",
    "wolfcrypt/src/eccsi.c",
    "wolfcrypt/src/ed25519.c",
    "wolfcrypt/src/ed448.c",
    "wolfcrypt/src/error.c",
    "wolfcrypt/src/evp.c",
    "wolfcrypt/src/ext_lms.c",
    "wolfcrypt/src/ext_mlkem.c",
    "wolfcrypt/src/ext_xmss.c",
    "wolfcrypt/src/falcon.c",
    "wolfcrypt/src/fe_448.c",
    "wolfcrypt/src/fe_low_mem.c",
    "wolfcrypt/src/fe_operations.c",
    "wolfcrypt/src/ge_448.c",
    "wolfcrypt/src/ge_low_mem.c",
    "wolfcrypt/src/ge_operations.c",
    "wolfcrypt/src/hash.c",
    "wolfcrypt/src/hmac.c",
    "wolfcrypt/src/hpke.c",
    "wolfcrypt/src/integer.c",
    "wolfcrypt/src/kdf.c",
    "wolfcrypt/src/logging.c",
    "wolfcrypt/src/md2.c",
    "wolfcrypt/src/md4.c",
    "wolfcrypt/src/md5.c",
    "wolfcrypt/src/memory.c",
    "wolfcrypt/src/misc.c",
    "wolfcrypt/src/pkcs12.c",
    "wolfcrypt/src/pkcs7.c",
    "wolfcrypt/src/poly1305.c",
    "wolfcrypt/src/pwdbased.c",
    "wolfcrypt/src/random.c",
    "wolfcrypt/src/rc2.c",
    "wolfcrypt/src/ripemd.c",
    "wolfcrypt/src/rsa.c",
    "wolfcrypt/src/sakke.c",
    "wolfcrypt/src/sha.c",
    "wolfcrypt/src/sha256.c",
    "wolfcrypt/src/sha3.c",
    "wolfcrypt/src/sha512.c",
    "wolfcrypt/src/signature.c",
    "wolfcrypt/src/siphash.c",
    "wolfcrypt/src/sm2.c",
    "wolfcrypt/src/sm3.c",
    "wolfcrypt/src/sm4.c",
    "wolfcrypt/src/sp_arm32.c",
    "wolfcrypt/src/sp_arm64.c",
    "wolfcrypt/src/sp_armthumb.c",
    "wolfcrypt/src/sp_c32.c",
    "wolfcrypt/src/sp_c64.c",
    "wolfcrypt/src/sp_cortexm.c",
    "wolfcrypt/src/sp_dsp32.c",
    "wolfcrypt/src/sp_int.c",
    "wolfcrypt/src/sp_sm2_arm32.c",
    "wolfcrypt/src/sp_sm2_arm64.c",
    "wolfcrypt/src/sp_sm2_armthumb.c",
    "wolfcrypt/src/sp_sm2_c32.c",
    "wolfcrypt/src/sp_sm2_c64.c",
    "wolfcrypt/src/sp_sm2_cortexm.c",
    "wolfcrypt/src/sp_sm2_x86_64.c",
    "wolfcrypt/src/sp_x86_64.c",
    "wolfcrypt/src/sphincs.c",
    "wolfcrypt/src/srp.c",
    "wolfcrypt/src/tfm.c",
    "wolfcrypt/src/wc_dsp.c",
    "wolfcrypt/src/wc_encrypt.c",
    "wolfcrypt/src/wc_lms.c",
    "wolfcrypt/src/wc_lms_impl.c",
    "wolfcrypt/src/wc_mlkem.c",
    "wolfcrypt/src/wc_mlkem_poly.c",
    "wolfcrypt/src/wc_pkcs11.c",
    "wolfcrypt/src/wc_port.c",
    "wolfcrypt/src/wc_xmss.c",
    "wolfcrypt/src/wc_xmss_impl.c",
    "wolfcrypt/src/wolfevent.c",
    "wolfcrypt/src/wolfmath.c",
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("wolfssl", .{});

    // {} void == define, null == undef
    const config = b.addConfigHeader(.{
        .style = .{ .cmake = upstream.path("cmake/options.h.in") },
        .include_path = "wolfssl/options.h",
    }, .{
        .ECC_SHAMIR = {},
        .ECC_TIMING_RESISTANT = {},
        .GCM_TABLE_4BIT = {},
        .HAVE_AESGCM = {},
        .HAVE_CHACHA = {},
        .HAVE_DH_DEFAULT_PARAMS = {},
        .HAVE_ECC = {},
        .HAVE_ENCRYPT_THEN_MAC = {},
        .HAVE_EXTENDED_MASTER = {},
        .HAVE_FFDHE_2048 = {},
        .HAVE_HASHDRBG = {},
        .HAVE_HKDF = {},
        .HAVE_POLY1305 = {},
        .HAVE_PTHREAD = if (target.result.abi != .msvc) {} else null,
        .HAVE_SUPPORTED_CURVES = {},
        .HAVE_THREAD_LS = {},
        .HAVE_TLS_EXTENSIONS = {},
        .HAVE_ONE_TIME_AUTH = {},
        .NO_DES3 = {},
        .NO_DSA = {},
        .NO_MD4 = {},
        .NO_PSK = {},
        .WOLFSSL_BASE64_ENCODE = {},
        .WOLFSSL_PSS_LONG_SALT = {},
        .WOLFSSL_SHA224 = {},
        .WOLFSSL_SHA384 = {},
        .WOLFSSL_SHA3 = null,
        .WOLFSSL_SHA512 = {},
        .WOLFSSL_SYS_CA_CERTS = {},
        .WOLFSSL_TLS13 = {},
        .WOLFSSL_USE_ALIGN = {},
        .WOLFSSL_X86_64_BUILD = if (isX86(target)) {} else null,
        .WC_NO_ASYNC_THREADING = {},
        .WC_RSA_BLINDING = {},
        .WC_RSA_PSS = {},
        .TFM_ECC256 = {},
        .TFM_TIMING_RESISTANT = {},
        .OPENSSL_EXTRA = {},
        .OPENSSL_ALL = {},
        .HAVE_PKCS7 = {},
        .HAVE_X963_KDF = {},
        .HAVE_AES_KEYWRAP = {},
        .WOLFSSL_AES_DIRECT = {},
    });

    const lib = b.addStaticLibrary(.{
        .name = "wolfssl",
        .target = target,
        .optimize = optimize,
    });

    switch (optimize) {
        .Debug, .ReleaseSafe => lib.bundle_compiler_rt = true,
        else => lib.root_module.strip = true,
    }

    lib.root_module.addIncludePath(upstream.path("."));

    var cflags = std.ArrayList([]const u8).init(b.allocator);
    defer cflags.deinit();

    try cflags.appendSlice(&base_cflags);

    if (optimize == .Debug) {
        try cflags.append("-DDEBUG_WOLFSSL");
    }

    lib.root_module.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = wolfssl_sources ++ wolfcrypt_sources,
        .flags = cflags.items,
    });

    if (lib.rootModuleTarget().isMinGW()) {
        lib.linkSystemLibrary("ws2_32"); // inet_pton and friends
        lib.linkSystemLibrary("pthread");
    }

    lib.linkLibC();

    lib.installHeadersDirectory(upstream.path("."), "", .{});

    lib.installConfigHeader(config);

    b.installArtifact(lib);
}
