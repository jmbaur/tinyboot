const std = @import("std");
const clap = @import("clap");

const wolfssl = @import("./wolfssl.zig");

const C = @cImport({
    @cInclude("mbedtls/x509_crt.h");
});

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

fn readPrivateKey(arena_alloc: std.mem.Allocator, filepath: []const u8) !*wolfssl.EVP_PKEY {
    const full_filepath = try std.fs.cwd().realpathAlloc(arena_alloc, filepath);
    const filepathZ = try arena_alloc.dupeZ(u8, full_filepath);

    const b = try wolfssl.bioNewFile(filepathZ, "rb");
    defer wolfssl.bioFree(b);

    return try wolfssl.pemReadBioPrivateKey(b);
}

fn readX509(arena_alloc: std.mem.Allocator, filepath: []const u8) !*wolfssl.X509 {
    const full_filepath = try std.fs.cwd().realpathAlloc(arena_alloc, filepath);
    const filepathZ = try arena_alloc.dupeZ(u8, full_filepath);

    const bio = try wolfssl.bioNewFile(filepathZ, "rb");
    defer wolfssl.bioFree(bio);

    var buf: [2]u8 = undefined;
    if (try wolfssl.bioRead(bio, &buf) != buf.len) {
        return error.ReadError;
    }

    try wolfssl.bioReset(bio);

    if (buf[0] == 0x30 and buf[1] >= 0x81 and buf[1] <= 0x84) {
        // Using DER encoding
        std.log.debug("detected x509 in DER form", .{});
        return try wolfssl.d2iX509Bio(bio);
    } else {
        std.log.debug("detected x509 in PEM form", .{});
        return try wolfssl.pemReadBioX509(bio);
    }
}

pub fn signFile(
    arena_alloc: std.mem.Allocator,
    in_file: []const u8,
    out_file: []const u8,
    private_key_filepath: []const u8,
    certificate_filepath: []const u8,
) !void {
    wolfssl.init();

    const in_bio = try wolfssl.bioNewFile(
        try arena_alloc.dupeZ(u8, try std.fs.cwd().realpathAlloc(
            arena_alloc,
            in_file,
        )),
        "rb",
    );
    defer wolfssl.bioFree(in_bio);

    const private_key = try readPrivateKey(arena_alloc, private_key_filepath);

    const certificate = try readX509(arena_alloc, certificate_filepath);

    const pkcs7 = try wolfssl.pkcs7Sign(certificate, private_key, in_bio);
    defer wolfssl.pkcs7Free(pkcs7);

    const out_bio = try wolfssl.bioNewFile(try arena_alloc.dupeZ(u8, out_file), "wb");
    defer wolfssl.bioFree(out_bio);

    // Append the marker and the PKCS#7 message to the destination file
    try wolfssl.bioReset(in_bio);

    var buf = [_]u8{0} ** 4096;
    while (true) {
        const n_read = try wolfssl.bioRead(in_bio, &buf);
        if (n_read == 0) {
            break;
        }

        try wolfssl.bioWrite(out_bio, buf[0..n_read]);
    }

    const out_size = wolfssl.bioNumberWritten(out_bio);

    try wolfssl.i2dPkcs7Bio(out_bio, pkcs7);

    const sig_size = wolfssl.bioNumberWritten(out_bio) - out_size;

    const sig_info = ModuleSignature{
        .sig_len = std.mem.nativeToBig(u32, @intCast(sig_size)),
        .id_type = @intFromEnum(PkeyIdType.PkeyIdPkcs7),
        .algo = 0,
        .hash = 0,
        .__pad = [_]u8{0} ** 3,
        .signer_len = 0,
        .key_id_len = 0,
    };

    try wolfssl.bioWrite(out_bio, std.mem.asBytes(&sig_info));
    try wolfssl.bioWrite(out_bio, MODULE_SIG_STRING);
}

fn mbedtls(allocator: std.mem.Allocator, cert_filepath: []const u8) void {
    const file = std.fs.cwd().openFile(cert_filepath, .{}) catch unreachable;
    defer file.close();

    const bytes = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch unreachable;
    defer allocator.free(bytes);

    var x509: C.mbedtls_x509_crt = undefined;
    C.mbedtls_x509_crt_init(&x509);
    if (C.mbedtls_x509_crt_parse(&x509, @ptrCast(bytes), bytes.len) != 0) {
        unreachable;
    }

    std.debug.print("serial={any}\n", .{x509.serial.p[0..x509.serial.len]});

    var issuer = x509.issuer;
    while (true) {
        if (std.crypto.Certificate.Attribute.map.get(issuer.oid.p[0..issuer.oid.len])) |attribute| {
            switch (attribute) {
                .commonName => std.debug.print("CN={s}\n", .{issuer.val.p[0..issuer.val.len]}),
                .organizationName => std.debug.print("O={s}\n", .{issuer.val.p[0..issuer.val.len]}),
                .countryName => std.debug.print("C={s}\n", .{issuer.val.p[0..issuer.val.len]}),
                else => {},
            }
        }

        if (issuer.next == null) {
            break;
        } else {
            issuer = issuer.next.*;
        }
    }
}

pub fn main() !void {
    wolfssl.enableLogging();

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

    mbedtls(arena.allocator(), certificate_filepath);
    if (true) {
        return;
    }

    return signFile(
        arena.allocator(),
        in_file,
        out_file,
        private_key_filepath,
        certificate_filepath,
    );
}
