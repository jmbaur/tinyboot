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

    var input_file_reader = input_file.reader(io, &.{});

    errdefer std.Io.Dir.cwd().deleteFile(io, out_filepath) catch {};

    const output_file = try std.Io.Dir.cwd().createFile(io, out_filepath, .{});
    defer output_file.close(io);
    var output_file_writer = output_file.writer(io, &.{});

    var entropy: mbedtls_c.mbedtls_entropy_context = undefined;
    mbedtls_c.mbedtls_entropy_init(&entropy);
    defer mbedtls_c.mbedtls_entropy_free(&entropy);

    var ctr_drbg: mbedtls_c.mbedtls_ctr_drbg_context = undefined;
    mbedtls_c.mbedtls_ctr_drbg_init(&ctr_drbg);
    defer mbedtls_c.mbedtls_ctr_drbg_free(&ctr_drbg);

    var pk: mbedtls_c.mbedtls_pk_context = undefined;
    mbedtls_c.mbedtls_pk_init(&pk);
    defer mbedtls_c.mbedtls_pk_free(&pk);

    try wrap(mbedtls_c.mbedtls_ctr_drbg_seed(
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
    try wrap(mbedtls_c.mbedtls_x509_crt_parse(&x509, @ptrCast(certificate_bytes), certificate_bytes.len));
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

    try wrap(mbedtls_c.mbedtls_pk_parse_key(
        &pk,
        @ptrCast(private_key_bytes),
        private_key_bytes.len,
        null,
        0,
        mbedtls_c.mbedtls_ctr_drbg_random,
        &ctr_drbg,
    ));

    if (mbedtls_c.mbedtls_pk_can_do(&pk, mbedtls_c.MBEDTLS_PK_RSA) == 0) {
        std.log.err("detected non RSA key", .{});
        return error.InvalidPrivateKey;
    }

    try wrap(mbedtls_c.mbedtls_rsa_set_padding(
        mbedtls_c.mbedtls_pk_rsa(pk),
        mbedtls_c.MBEDTLS_RSA_PKCS_V15,
        mbedtls_c.MBEDTLS_MD_SHA256,
    ));

    var hash: [sha2.Sha256.digest_length]u8 = @splat(0);
    var hasher = sha2.Sha256.init(.{});
    while (true) {
        const bytes_read = try input_file_reader.interface.readSliceShort(&scratch_buf);
        if (bytes_read == 0) {
            break;
        }

        hasher.update(scratch_buf[0..bytes_read]);
    }
    hasher.final(&hash);

    scratch_buf = std.mem.zeroes(@TypeOf(scratch_buf));

    var signature_len: usize = 0;
    var signature_buf: [mbedtls_c.MBEDTLS_MPI_MAX_SIZE]u8 = @splat(0);
    try wrap(mbedtls_c.mbedtls_pk_sign(
        &pk,
        mbedtls_c.MBEDTLS_MD_SHA256,
        &hash,
        hash.len,
        &signature_buf,
        signature_buf.len,
        &signature_len,
        mbedtls_c.mbedtls_ctr_drbg_random,
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

    try input_file_reader.seekTo(0);
    while (true) {
        const bytes_read = try input_file_reader.interface.readSliceShort(&scratch_buf);
        if (bytes_read == 0) {
            break;
        }

        try output_file_writer.interface.writeAll(scratch_buf[0..bytes_read]);
    }

    try output_file_writer.interface.writeAll(pkcs7_encoded);

    const sig_info = ModuleSignature{
        .sig_len = std.mem.nativeToBig(u32, @intCast(pkcs7_encoded.len)),
        .id_type = @intFromEnum(PkeyIdType.PkeyIdPkcs7),
        .algo = 0,
        .hash = 0,
        .__pad = @splat(0),
        .signer_len = 0,
        .key_id_len = 0,
    };

    try output_file_writer.interface.writeAll(std.mem.asBytes(&sig_info));
    try output_file_writer.interface.writeAll(MODULE_SIG_STRING);
    try output_file_writer.interface.flush();
}

fn fixed_seed(ctx: ?*anyopaque, buffer: [*c]u8, len: usize) callconv(.c) c_int {
    const seed: *[]const u8 = @ptrCast(@alignCast(ctx.?));
    const buf = buffer[0..len];
    if (seed.len > len) {
        std.mem.copyForwards(u8, buf, seed.*[0..len]);
    } else {
        std.mem.copyForwards(u8, buf, seed.*);
    }
    return 0;
}

/// Returns the generalized time (https://datatracker.ietf.org/doc/html/rfc5280#section-4.1.2.5.2) of an
/// instant, requires the input buffer's length to be >= 15.
fn generalizedTime(epoch_seconds: std.time.epoch.EpochSeconds, buf: []u8) ![]u8 {
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    // YYYYMMDDHHMMSSZ
    return std.fmt.bufPrint(buf, "{:0>4}{:0>2}{:0>2}{:0>2}{:0>2}{:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

test generalizedTime {
    var buf: ["YYYYMMDDHHMMSSZ".len]u8 = @splat(0);

    try std.testing.expectEqualStrings(
        "19700101000000Z",
        try generalizedTime(.{ .secs = 0 }, &buf),
    );

    try std.testing.expectEqualStrings(
        "20250513050449Z",
        try generalizedTime(.{ .secs = 1747112689 }, &buf),
    );
}

pub fn generateKeyAndCert(
    io: std.Io,
    arena_alloc: std.mem.Allocator,
    outdir: std.Io.Dir,
    time_now_: ?u64,
    valid_seconds_: ?u64,
    common_name: []const u8,
    organization: []const u8,
    country: []const u8,
    seed: ?[]const u8,
) !void {
    const time_now: u64 = time_now_ orelse @intCast(mbedtls_c.time(null));
    const valid_seconds: u64 = valid_seconds_ orelse 60 * 60 * 24 * 365;

    var entropy: mbedtls_c.mbedtls_entropy_context = undefined;
    mbedtls_c.mbedtls_entropy_init(&entropy);
    defer mbedtls_c.mbedtls_entropy_free(&entropy);

    var ctr_drbg: mbedtls_c.mbedtls_ctr_drbg_context = undefined;
    mbedtls_c.mbedtls_ctr_drbg_init(&ctr_drbg);
    try wrap(mbedtls_c.mbedtls_ctr_drbg_seed(
        &ctr_drbg,
        if (seed != null) &fixed_seed else mbedtls_c.mbedtls_entropy_func,
        if (seed) |seed_| @ptrCast(@constCast(&seed_)) else &entropy,
        "tboot-keygen",
        "tboot-keygen".len,
    ));
    defer mbedtls_c.mbedtls_ctr_drbg_free(&ctr_drbg);

    // generate RSA key
    var key: mbedtls_c.mbedtls_pk_context = undefined;
    mbedtls_c.mbedtls_pk_init(&key);
    defer mbedtls_c.mbedtls_pk_free(&key);

    try wrap(mbedtls_c.mbedtls_pk_setup(&key, mbedtls_c.mbedtls_pk_info_from_type(mbedtls_c.MBEDTLS_PK_RSA)));

    try wrap(mbedtls_c.mbedtls_rsa_gen_key(mbedtls_c.mbedtls_pk_rsa(key), mbedtls_c.mbedtls_ctr_drbg_random, &ctr_drbg, 4096, 65537));

    var key_buf: [16000]u8 = @splat(0);

    // NOTE: When we write out PEM files, ensure there is a trailing null byte
    // so that MBEDTLS detects these as PEM files, see https://github.com/Mbed-TLS/mbedtls/blob/6fb5120fde4ab889bea402f5ab230c720b0a3b9a/library/pkparse.c#L994.

    // write out public key
    {
        try wrap(mbedtls_c.mbedtls_pk_write_pubkey_pem(&key, &key_buf, key_buf.len));

        const pub_out = try outdir.createFile(io, "tboot-public.pem", .{ .permissions = .fromMode(0o444) });
        defer pub_out.close(io);

        try pub_out.writeStreamingAll(io, std.mem.trim(u8, &key_buf, &.{0}));
    }

    key_buf = std.mem.zeroes(@TypeOf(key_buf));

    // write out private key
    {
        try wrap(mbedtls_c.mbedtls_pk_write_key_pem(&key, &key_buf, key_buf.len));

        const priv_out = try outdir.createFile(
            io,
            "tboot-private.pem",
            .{ .permissions = .fromMode(0o444) },
        );
        defer priv_out.close(io);

        try priv_out.writeStreamingAll(io, std.mem.trim(u8, &key_buf, &.{0}));
    }

    // generate x509 cert
    var issuer_crt: mbedtls_c.mbedtls_x509_crt = undefined;
    mbedtls_c.mbedtls_x509_crt_init(&issuer_crt);

    var crt: mbedtls_c.mbedtls_x509write_cert = undefined;
    mbedtls_c.mbedtls_x509write_crt_init(&crt);

    var csr: mbedtls_c.mbedtls_x509_csr = undefined;
    mbedtls_c.mbedtls_x509_csr_init(&csr);

    // self-signed
    mbedtls_c.mbedtls_x509write_crt_set_subject_key(&crt, &key);
    mbedtls_c.mbedtls_x509write_crt_set_issuer_key(&crt, &key);

    const name = try std.fmt.allocPrint(arena_alloc, "CN={s},O={s},C={s}", .{ common_name, organization, country });
    try wrap(mbedtls_c.mbedtls_x509write_crt_set_subject_name(&crt, try arena_alloc.dupeSentinel(u8, name, 0)));
    try wrap(mbedtls_c.mbedtls_x509write_crt_set_issuer_name(&crt, try arena_alloc.dupeSentinel(u8, name, 0)));

    mbedtls_c.mbedtls_x509write_crt_set_md_alg(&crt, mbedtls_c.MBEDTLS_MD_SHA256);

    var serial = "1";
    try wrap(mbedtls_c.mbedtls_x509write_crt_set_serial_raw(&crt, @ptrCast(&serial), 1));

    const not_before_seconds = time_now;
    const not_after_seconds = not_before_seconds + valid_seconds;

    var before_buf: [15]u8 = @splat(0);
    var after_buf: [15]u8 = @splat(0);

    // mbedtls expects the 'Z' to not be present
    const not_before_time = try arena_alloc.dupeSentinel(u8, (try generalizedTime(.{ .secs = not_before_seconds }, &before_buf))[0..14], 0);
    const not_after_time = try arena_alloc.dupeSentinel(u8, (try generalizedTime(.{ .secs = not_after_seconds }, &after_buf))[0..14], 0);

    try wrap(mbedtls_c.mbedtls_x509write_crt_set_validity(
        &crt,
        @ptrCast(not_before_time),
        @ptrCast(not_after_time),
    ));

    try wrap(mbedtls_c.mbedtls_x509write_crt_set_basic_constraints(&crt, 1, -1));

    try wrap(mbedtls_c.mbedtls_x509write_crt_set_subject_key_identifier(&crt));
    try wrap(mbedtls_c.mbedtls_x509write_crt_set_authority_key_identifier(&crt));

    var cert_buf: [4096]u8 = @splat(0);

    // write out certificate in DER format
    {
        const len: usize = @intCast(try wrapMulti(mbedtls_c.mbedtls_x509write_crt_der(
            &crt,
            &cert_buf,
            cert_buf.len,
            mbedtls_c.mbedtls_ctr_drbg_random,
            &ctr_drbg,
        )));

        const cert_der_out = try outdir.createFile(io, "tboot-certificate.der", .{ .permissions = .fromMode(0o444) });
        defer cert_der_out.close(io);

        const start: usize = cert_buf.len - len;
        try cert_der_out.writeStreamingAll(io, std.mem.trim(u8, cert_buf[start .. start + len], &.{0}));
    }

    cert_buf = std.mem.zeroes(@TypeOf(cert_buf));

    // write out certificate in PEM format
    {
        try wrap(mbedtls_c.mbedtls_x509write_crt_pem(
            &crt,
            &cert_buf,
            cert_buf.len,
            mbedtls_c.mbedtls_ctr_drbg_random,
            &ctr_drbg,
        ));

        const cert_pem_out = try outdir.createFile(io, "tboot-certificate.pem", .{ .permissions = .fromMode(0o444) });
        defer cert_pem_out.close(io);

        try cert_pem_out.writeStreamingAll(io, std.mem.trim(u8, &cert_buf, &.{0}));
    }
}
