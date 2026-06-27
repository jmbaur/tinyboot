const std = @import("std");
const mbedtls_c = @import("mbedtls_c");

const asn1 = std.crypto.codecs.asn1;
const sha2 = std.crypto.hash.sha2;

const Pkcs7 = @import("./pkcs7.zig");

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

const MODULE_SIG_STRING = "~Module signature appended~\n";

const country_name_oid = asn1.Oid.fromDotComptime("2.5.4.6");
const common_name_oid = asn1.Oid.fromDotComptime("2.5.4.3");
const organization_name_oid = asn1.Oid.fromDotComptime("2.5.4.10");

var err_buf: [1024]u8 = undefined;

pub fn wrapMulti(return_code: c_int) !c_int {
    return wrapReturnCode(.negative, c_int, return_code);
}

pub fn wrap(return_code: c_int) !void {
    return wrapReturnCode(.positive, void, return_code);
}

fn wrapReturnCode(
    comptime return_code_type: enum { negative, positive },
    comptime T: type,
    return_code: c_int,
) !T {
    if ((return_code_type == .negative and return_code < 0) or (return_code_type == .positive and return_code != 0)) {
        mbedtls_c.mbedtls_strerror(return_code, &err_buf, err_buf.len);
        std.log.err("mbedtls error({}): {s}", .{ @abs(return_code), err_buf });
        return error.MbedtlsError;
    }

    if (return_code_type == .negative) {
        return return_code;
    }
}

fn getAttribute(x509: *mbedtls_c.mbedtls_x509_crt, attribute: std.crypto.Certificate.Attribute) ?[]const u8 {
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

pub fn signFile(
    io: std.Io,
    arena_alloc: std.mem.Allocator,
    in_filepath: []const u8,
    out_filepath: []const u8,
    private_key_filepath: []const u8,
    certificate_filepath: []const u8,
) !void {
    var scratch_buf: [4096]u8 = undefined;

    const input_file = try std.Io.Dir.cwd().openFile(io, in_filepath, .{});
    defer input_file.close(io);

    errdefer std.Io.Dir.cwd().deleteFile(io, out_filepath) catch {};

    const output_file = try std.Io.Dir.cwd().createFile(io, out_filepath, .{});
    defer output_file.close(io);

    var entropy: mbedtls_c.mbedtls_entropy_context = undefined;
    mbedtls_c.mbedtls_entropy_init(&entropy);
    defer mbedtls_c.mbedtls_entropy_free(&entropy);

    var ctr_drbg: mbedtls_c.mbedtlstr_drbg_context = undefined;
    mbedtls_c.mbedtlstr_drbg_init(&ctr_drbg);
    defer mbedtls_c.mbedtlstr_drbg_free(&ctr_drbg);

    var pk: mbedtls_c.mbedtls_pk_context = undefined;
    mbedtls_c.mbedtls_pk_init(&pk);
    defer mbedtls_c.mbedtls_pk_free(&pk);

    try mbedtls_c.wrap(mbedtls_c.mbedtlstr_drbg_seed(
        &ctr_drbg,
        mbedtls_c.mbedtls_entropy_func,
        &entropy,
        "tinyboot",
        "tinyboot".len,
    ));

    const certificate_file = try std.Io.Dir.cwd().openFile(io, certificate_filepath, .{});
    defer certificate_file.close(io);
    var certificate_file_reader = certificate_file.reader(io, &.{});
    const certificate_bytes = try certificate_file_reader.interface.allocRemaining(arena_alloc, .unlimited);

    var x509: mbedtls_c.mbedtls_x509_crt = undefined;
    mbedtls_c.mbedtls_x509_crt_init(&x509);
    try mbedtls_c.wrap(mbedtls_c.mbedtls_x509_crt_parse(&x509, @ptrCast(certificate_bytes), certificate_bytes.len));
    defer mbedtls_c.mbedtls_x509_crt_free(&x509);

    const common_name = getAttribute(&x509, .commonName) orelse return error.MissingCommonName;
    const organization_name = getAttribute(&x509, .organizationName) orelse return error.MissingOrganizationName;
    const country_name = getAttribute(&x509, .countryName) orelse return error.MissingCountryName;
    const serial_number = x509.serial.p[0..x509.serial.len];

    const private_key_file = try std.Io.Dir.cwd().openFile(io, private_key_filepath, .{});
    defer private_key_file.close(io);

    // NOTE: mbedtls requires the PEM-encoded private key to have a
    // null-byte terminator, or else we run into this issue:
    // ```
    // error: mbedtls error(15616): PK - Invalid key tag or value
    // ```
    const private_key_size: usize = @intCast((try private_key_file.stat(io)).size);
    var private_key_bytes = try arena_alloc.alloc(u8, private_key_size + 1);
    @memset(private_key_bytes, 0);
    var private_key_file_reader = private_key_file.reader(io, &.{});
    _ = try private_key_file_reader.interface.readSliceShort(private_key_bytes[0..private_key_size]);

    try mbedtls_c.wrap(mbedtls_c.mbedtls_pk_parse_key(
        &pk,
        @ptrCast(private_key_bytes),
        private_key_bytes.len,
        null,
        0,
        mbedtls_c.mbedtlstr_drbg_random,
        &ctr_drbg,
    ));

    if (mbedtls_c.mbedtls_pk_can_do(&pk, mbedtls_c.MBEDTLS_PK_RSA) == 0) {
        std.log.err("detected non RSA key", .{});
        return error.InvalidPrivateKey;
    }

    try mbedtls_c.wrap(mbedtls_c.mbedtls_rsa_set_padding(
        mbedtls_c.mbedtls_pk_rsa(pk),
        mbedtls_c.MBEDTLS_RSA_PKCS_V15,
        mbedtls_c.MBEDTLS_MD_SHA256,
    ));

    var hash = [_]u8{0} ** sha2.Sha256.digest_length;
    var hasher = sha2.Sha256.init(.{});
    while (true) {
        var input_file_reader = input_file.reader(io, &.{});
        const bytes_read = try input_file_reader.interface.readSliceShort(&scratch_buf);
        if (bytes_read == 0) {
            break;
        }

        hasher.update(scratch_buf[0..bytes_read]);
    }
    hasher.final(&hash);

    scratch_buf = std.mem.zeroes(@TypeOf(scratch_buf));

    var signature_len: usize = 0;
    var signature_buf = [_]u8{0} ** mbedtls_c.MBEDTLS_MPI_MAX_SIZE;
    try mbedtls_c.wrap(mbedtls_c.mbedtls_pk_sign(
        &pk,
        mbedtls_c.MBEDTLS_MD_SHA256,
        &hash,
        hash.len,
        &signature_buf,
        signature_buf.len,
        &signature_len,
        mbedtls_c.mbedtlstr_drbg_random,
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
        const bytes_read = try input_file.read(&scratch_buf);
        if (bytes_read == 0) {
            break;
        }

        try output_file.writeAll(scratch_buf[0..bytes_read]);
    }

    try output_file.writeAll(pkcs7_encoded);

    const sig_info = ModuleSignature{
        .sig_len = std.mem.nativeToBig(u32, @intCast(pkcs7_encoded.len)),
        .id_type = @intFromEnum(PkeyIdType.PkeyIdPkcs7),
        .algo = 0,
        .hash = 0,
        .__pad = [_]u8{0} ** 3,
        .signer_len = 0,
        .key_id_len = 0,
    };

    try output_file.writeAll(std.mem.asBytes(&sig_info));
    try output_file.writeAll(MODULE_SIG_STRING);
}
