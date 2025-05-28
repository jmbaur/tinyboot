const std = @import("std");
const clap = @import("clap");

const asn1 = std.crypto.asn1;
const sha2 = std.crypto.hash.sha2;

const Pkcs7 = @import("./pkcs7.zig");

const mbedtls = @import("./mbedtls.zig");

const C = @cImport({
    @cInclude("mbedtls/ctr_drbg.h");
    @cInclude("mbedtls/entropy.h");
    @cInclude("mbedtls/pk.h");
    @cInclude("mbedtls/rsa.h");
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

const country_name_oid = asn1.Oid.fromDotComptime("2.5.4.6");
const common_name_oid = asn1.Oid.fromDotComptime("2.5.4.3");
const organization_name_oid = asn1.Oid.fromDotComptime("2.5.4.10");

pub fn signFile(
    arena_alloc: std.mem.Allocator,
    in_filepath: []const u8,
    out_filepath: []const u8,
    private_key_filepath: []const u8,
    certificate_filepath: []const u8,
) !void {
    var scratch_buf = [_]u8{0} ** 4096;

    const input_file = try std.fs.cwd().openFile(in_filepath, .{});
    defer input_file.close();

    errdefer std.fs.cwd().deleteFile(out_filepath) catch {};

    const output_file = try std.fs.cwd().createFile(out_filepath, .{});
    defer output_file.close();

    var entropy: C.mbedtls_entropy_context = undefined;
    C.mbedtls_entropy_init(&entropy);
    defer C.mbedtls_entropy_free(&entropy);

    var ctr_drbg: C.mbedtls_ctr_drbg_context = undefined;
    C.mbedtls_ctr_drbg_init(&ctr_drbg);
    defer C.mbedtls_ctr_drbg_free(&ctr_drbg);

    var pk: C.mbedtls_pk_context = undefined;
    C.mbedtls_pk_init(&pk);
    defer C.mbedtls_pk_free(&pk);

    try mbedtls.wrap(C.mbedtls_ctr_drbg_seed(
        &ctr_drbg,
        C.mbedtls_entropy_func,
        &entropy,
        "tinyboot",
        "tinyboot".len,
    ));

    const certificate_file = try std.fs.cwd().openFile(certificate_filepath, .{});
    defer certificate_file.close();
    const certificate_bytes = try certificate_file.readToEndAlloc(arena_alloc, std.math.maxInt(usize));

    var x509: C.mbedtls_x509_crt = undefined;
    C.mbedtls_x509_crt_init(&x509);
    try mbedtls.wrap(C.mbedtls_x509_crt_parse(&x509, @ptrCast(certificate_bytes), certificate_bytes.len));
    defer C.mbedtls_x509_crt_free(&x509);

    const common_name = getAttribute(&x509, .commonName) orelse return error.MissingCommonName;
    const organization_name = getAttribute(&x509, .organizationName) orelse return error.MissingOrganizationName;
    const country_name = getAttribute(&x509, .countryName) orelse return error.MissingCountryName;
    const serial_number = x509.serial.p[0..x509.serial.len];

    const private_key_file = try std.fs.cwd().openFile(private_key_filepath, .{});
    defer private_key_file.close();
    const private_key_bytes = try private_key_file.readToEndAlloc(arena_alloc, std.math.maxInt(usize));

    try mbedtls.wrap(C.mbedtls_pk_parse_key(
        &pk,
        @ptrCast(private_key_bytes),
        private_key_bytes.len,
        null,
        0,
        C.mbedtls_ctr_drbg_random,
        &ctr_drbg,
    ));

    if (C.mbedtls_pk_can_do(&pk, C.MBEDTLS_PK_RSA) == 0) {
        std.log.err("detected non RSA key", .{});
        return error.InvalidPrivateKey;
    }

    try mbedtls.wrap(C.mbedtls_rsa_set_padding(
        C.mbedtls_pk_rsa(pk),
        C.MBEDTLS_RSA_PKCS_V15,
        C.MBEDTLS_MD_SHA256,
    ));

    var hash = [_]u8{0} ** sha2.Sha256.digest_length;
    var hasher = sha2.Sha256.init(.{});
    while (true) {
        const bytes_read = try input_file.reader().read(&scratch_buf);
        if (bytes_read == 0) {
            break;
        }

        hasher.update(scratch_buf[0..bytes_read]);
    }
    hasher.final(&hash);

    scratch_buf = std.mem.zeroes(@TypeOf(scratch_buf));

    var signature_len: usize = 0;
    var signature_buf = [_]u8{0} ** C.MBEDTLS_MPI_MAX_SIZE;
    try mbedtls.wrap(C.mbedtls_pk_sign(
        &pk,
        C.MBEDTLS_MD_SHA256,
        &hash,
        hash.len,
        &signature_buf,
        signature_buf.len,
        &signature_len,
        C.mbedtls_ctr_drbg_random,
        &ctr_drbg,
    ));

    const signature = signature_buf[0..signature_len];

    var encoder = asn1.der.Encoder.init(arena_alloc);
    defer encoder.deinit();

    try encoder.any(Pkcs7{
        .content_type = .signed_data,
        .content = .{
            .signed_data = .{
                .version = 1,
                .digest_algorithms = .{ .inner = .{ .algorithm = .sha256, .parameters = .{} } },
                .encapsulated_content_info = .{ .content_type = .pkcs7 },
                .signer_infos = .{
                    .inner = &.{
                        .{
                            .version = 1,
                            .issuer_and_serial_number = .{
                                .serial_number = serial_number,
                                .rdn_sequence = .{
                                    .relative_distinguished_name = .{
                                        .inner = &.{
                                            .{ .inner = .{ .type = country_name_oid, .value = country_name } },
                                            .{ .inner = .{ .type = organization_name_oid, .value = organization_name } },
                                            .{ .inner = .{ .type = common_name_oid, .value = common_name } },
                                        },
                                    },
                                },
                            },
                            .digest_algorithm = .{ .algorithm = .sha256, .parameters = .{} },
                            .signature_algorithm = .{ .algorithm = .rsa, .parameters = .{} },
                            .signature = .{ .data = signature },
                        },
                    },
                },
            },
        },
    });

    const pkcs7_encoded = encoder.buffer.data;

    try input_file.seekTo(0);
    while (true) {
        const bytes_read = try input_file.reader().read(&scratch_buf);
        if (bytes_read == 0) {
            break;
        }

        try output_file.writer().writeAll(scratch_buf[0..bytes_read]);
    }

    try output_file.writer().writeAll(pkcs7_encoded);

    const sig_info = ModuleSignature{
        .sig_len = std.mem.nativeToBig(u32, @intCast(pkcs7_encoded.len)),
        .id_type = @intFromEnum(PkeyIdType.PkeyIdPkcs7),
        .algo = 0,
        .hash = 0,
        .__pad = [_]u8{0} ** 3,
        .signer_len = 0,
        .key_id_len = 0,
    };

    try output_file.writer().writeAll(std.mem.asBytes(&sig_info));
    try output_file.writer().writeAll(MODULE_SIG_STRING);
}

fn getAttribute(x509: *C.mbedtls_x509_crt, attribute: std.crypto.Certificate.Attribute) ?[]const u8 {
    var issuer = x509.issuer;

    while (true) {
        if (std.crypto.Certificate.Attribute.map.get(issuer.oid.p[0..issuer.oid.len])) |a| {
            if (a == attribute) {
                return issuer.val.p[0..issuer.val.len];
            }
        }

        if (issuer.next == null) {
            break;
        } else {
            issuer = issuer.next.*;
        }
    }

    return null;
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
