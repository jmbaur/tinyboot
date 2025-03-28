const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap");

const openssl = @import("./openssl.zig");

const C = @cImport({
    @cInclude("openssl/opensslv.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/evp.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/engine.h");
});

pub const std_options = std.Options{ .log_level = if (builtin.mode == .Debug) .debug else .info };

const MODULE_SIG_STRING = "~Module signature appended~\n";

// https://github.com/torvalds/linux/blob/ec9eeb89e60d86fcc0243f47c2383399ce0de8f8/include/linux/module_signature.h#L17
const PkeyIdType = enum(u2) {
    /// OpenPGP generated key ID
    PkeyIdPgp,
    /// X.509 arbitrary subjectKeyIdentifier
    PkeyIdX509,
    /// Signature in PKCS#7 message
    PkeyIdPkcs7,
};

// https://github.com/torvalds/linux/blob/ec9eeb89e60d86fcc0243f47c2383399ce0de8f8/include/linux/module_signature.h#L33
const ModuleSignature = extern struct {
    /// Public-key crypto algorithm [0]
    algo: u8,
    /// Digest algorithm [0]
    hash: u8,
    /// Key identifier type [PKEY_ID_PKCS7]
    id_type: u8,
    /// Length of signer's name [0]
    signer_len: u8,
    /// Length of key identifier [0]
    key_id_len: u8,
    __pad: [3]u8,
    /// Length of signature data
    sig_len: u32, // be32
};

var key_pass: ?[]const u8 = null;

fn pemPasswordCallback(buff: [*c]u8, len: c_int, w: c_int, v: ?*anyopaque) callconv(.C) c_int {
    _ = w;
    _ = v;

    if (key_pass) |pass| {
        if (pass.len >= len) {
            return -1;
        }

        const buff_slice: []u8 = @ptrCast(buff[0..@as(usize, @intCast(len))]);
        std.mem.copyForwards(u8, buff_slice, pass);

        // If it's wrong, don't keep trying it.
        key_pass = null;

        return @as(c_int, @intCast(pass.len));
    } else {
        return -1;
    }
}

fn readPrivateKey(arena_alloc: std.mem.Allocator, filepath: []const u8) !*anyopaque {
    const full_filepath = try std.fs.cwd().realpathAlloc(arena_alloc, filepath);
    const filepathZ = try arena_alloc.dupeZ(u8, full_filepath);

    if (std.mem.startsWith(u8, filepath, "pkcs11:")) {
        C.ENGINE_load_builtin_engines();

        openssl.drainOpensslErrors();

        const engine = C.ENGINE_by_id("pkcs11") orelse {
            openssl.displayOpensslErrors(@src());
            return error.OpensslError;
        };

        if (C.ENGINE_init(engine) == 0) {
            openssl.drainOpensslErrors();
        } else {
            openssl.displayOpensslErrors(@src());
            return error.OpensslError;
        }

        if (key_pass) |pass| {
            if (C.ENGINE_ctrl_cmd_string(engine, "PIN", try arena_alloc.dupeZ(u8, pass), 0) == 0) {
                openssl.displayOpensslErrors(@src());
                return error.OpensslError;
            }
        }

        return C.ENGINE_load_private_key(engine, filepathZ, null, null) orelse {
            openssl.displayOpensslErrors(@src());
            return error.OpensslError;
        };
    } else {
        const b = C.BIO_new_file(filepathZ, "rb") orelse {
            openssl.displayOpensslErrors(@src());
            return error.OpensslError;
        };
        defer _ = C.BIO_free(b);

        return C.PEM_read_bio_PrivateKey(b, null, pemPasswordCallback, null) orelse {
            openssl.displayOpensslErrors(@src());
            return error.OpensslError;
        };
    }
}

fn readX509(arena_alloc: std.mem.Allocator, filepath: []const u8) !*anyopaque {
    const full_filepath = try std.fs.cwd().realpathAlloc(arena_alloc, filepath);
    const filepathZ = try arena_alloc.dupeZ(u8, full_filepath);

    const bio = C.BIO_new_file(filepathZ, "rb") orelse {
        openssl.displayOpensslErrors(@src());
        return error.OpensslError;
    };
    defer _ = C.BIO_free(bio);

    var buf: [2]u8 = undefined;
    const n_read = C.BIO_read(bio, &buf, 2);
    if (n_read != 2) {
        openssl.displayOpensslErrors(@src());
        return error.OpensslError;
    }

    if (C.BIO_reset(bio) != 0) {
        openssl.displayOpensslErrors(@src());
        return error.OpensslError;
    }

    if (buf[0] == 0x30 and buf[1] >= 0x81 and buf[1] <= 0x84) {
        // Using DER encoding
        return C.d2i_X509_bio(bio, null) orelse {
            openssl.displayOpensslErrors(@src());
            return error.OpensslError;
        };
    } else {
        return C.PEM_read_bio_X509(bio, null, null, null) orelse {
            openssl.displayOpensslErrors(@src());
            return error.OpensslError;
        };
    }
}

pub fn signFile(
    arena_alloc: std.mem.Allocator,
    in_file: []const u8,
    out_file: []const u8,
    private_key_filepath: []const u8,
    certificate_filepath: []const u8,
) !void {
    _ = C.OPENSSL_init_crypto(C.OPENSSL_INIT_ADD_ALL_CIPHERS | C.OPENSSL_INIT_ADD_ALL_DIGESTS, null);
    _ = C.OPENSSL_init_crypto(C.OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);
    C.ERR_clear_error();

    var env = try std.process.getEnvMap(arena_alloc);

    key_pass = env.get("TBOOT_SIGN_PIN");

    const in_bio = C.BIO_new_file(
        try arena_alloc.dupeZ(u8, try std.fs.cwd().realpathAlloc(
            arena_alloc,
            in_file,
        )),
        "rb",
    ) orelse {
        openssl.displayOpensslErrors(@src());
        return error.OpensslError;
    };
    defer _ = C.BIO_free(in_bio);

    const private_key = try readPrivateKey(arena_alloc, private_key_filepath);

    const certificate = try readX509(arena_alloc, certificate_filepath);

    _ = C.OPENSSL_init_crypto(C.OPENSSL_INIT_ADD_ALL_DIGESTS, null);
    openssl.displayOpensslErrors(@src());
    const digest_algo = C.EVP_get_digestbyname("sha256") orelse {
        openssl.displayOpensslErrors(@src());
        return error.OpensslError;
    };
    _ = digest_algo;

    const pkcs7 = C.PKCS7_sign(
        @ptrCast(certificate),
        @ptrCast(private_key),
        null,
        in_bio,
        C.PKCS7_NOCERTS | C.PKCS7_BINARY | C.PKCS7_DETACHED | C.PKCS7_NOATTR,
    );

    const out_bio = C.BIO_new_file(try arena_alloc.dupeZ(u8, out_file), "wb") orelse {
        openssl.displayOpensslErrors(@src());
        return error.OpensslError;
    };
    defer _ = C.BIO_free(out_bio);

    // Append the marker and the PKCS#7 message to the destination file
    if (C.BIO_reset(in_bio) < 0) {
        openssl.displayOpensslErrors(@src());
        return error.OpensslError;
    }

    var buff = [_]u8{0} ** 4096;
    while (true) {
        const n_read = C.BIO_read(in_bio, @ptrCast(&buff), buff.len);
        if (n_read == 0) {
            break;
        }

        if (C.BIO_write(out_bio, @ptrCast(&buff), n_read) < 0) {
            openssl.displayOpensslErrors(@src());
            return error.OpensslError;
        }
    }

    const out_size = C.BIO_number_written(out_bio);

    if (C.i2d_PKCS7_bio(out_bio, pkcs7) != 1) {
        openssl.displayOpensslErrors(@src());
        return error.OpensslError;
    }

    const sig_size = C.BIO_number_written(out_bio) - out_size;

    const sig_info = ModuleSignature{
        .sig_len = std.mem.nativeToBig(u32, @intCast(sig_size)),
        .id_type = @intFromEnum(PkeyIdType.PkeyIdPkcs7),
        .algo = 0,
        .hash = 0,
        .__pad = [_]u8{0} ** 3,
        .signer_len = 0,
        .key_id_len = 0,
    };

    if (C.BIO_write(out_bio, std.mem.asBytes(&sig_info), @sizeOf(@TypeOf(sig_info))) < 0) {
        openssl.displayOpensslErrors(@src());
        return error.OpensslError;
    }

    if (C.BIO_write(out_bio, MODULE_SIG_STRING, MODULE_SIG_STRING.len) < 0) {
        openssl.displayOpensslErrors(@src());
        return error.OpensslError;
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Display this help and exit.
        \\--private-key <FILE>    Private key to sign with.
        \\--certificate <FILE>    X509 certificate to sign with.
        \\<FILE>                  Input file.
        \\<FILE>                  Output file.
        \\
    );

    const parsers = comptime .{
        .FILE = clap.parsers.string,
    };

    const stderr = std.io.getStdErr().writer();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, &parsers, .{
        .diagnostic = &diag,
        .allocator = arena.allocator(),
    }) catch |err| {
        try diag.report(stderr, err);
        try clap.usage(stderr, clap.Help, &params);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }

    if (res.positionals[0] == null or
        res.positionals[1] == null or
        res.args.@"private-key" == null or
        res.args.certificate == null)
    {
        try diag.report(stderr, error.InvalidArgument);
        try clap.usage(stderr, clap.Help, &params);
        return;
    }

    const in_file = res.positionals[0].?;
    const out_file = res.positionals[1].?;
    const private_key_filepath = res.args.@"private-key".?;
    const certificate_filepath = res.args.certificate.?;

    return signFile(
        arena.allocator(),
        in_file,
        out_file,
        private_key_filepath,
        certificate_filepath,
    );
}
