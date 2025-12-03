const std = @import("std");
const clap = @import("clap");

const mbedtls = @import("./mbedtls.zig");

const C = @cImport({
    @cInclude("mbedtls/ctr_drbg.h");
    @cInclude("mbedtls/pk.h");
    @cInclude("mbedtls/x509_crt.h");
    @cInclude("mbedtls/x509_csr.h");
    @cInclude("time.h");
});

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

test "generalized time" {
    var buf = [_]u8{0} ** "YYYYMMDDHHMMSSZ".len;

    try std.testing.expectEqualStrings(
        "19700101000000Z",
        try generalizedTime(.{ .secs = 0 }, &buf),
    );

    try std.testing.expectEqualStrings(
        "20250513050449Z",
        try generalizedTime(.{ .secs = 1747112689 }, &buf),
    );
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                  Display this help and exit.
        \\-n, --common-name <STR>     Common name for certificate.
        \\-o, --organization <STR>    Organization for certificate.
        \\-c, --country <STR>         Country for certificate.
        \\-s, --valid-seconds <NUM>   Number of seconds the certificate is valid for (defaults to 31536000, 1 year).
        \\-t, --time-now <NUM>        Number of seconds past the Unix epoch (defaults to current time, only set if reproducibility is needed).
        \\
    );

    const parsers = comptime .{
        .STR = clap.parsers.string,
        .NUM = clap.parsers.int(u64, 10),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, &parsers, .{
        .diagnostic = &diag,
        .allocator = arena.allocator(),
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        try clap.usageToFile(.stderr(), clap.Help, &params);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});
    }

    const time_now: u64 = res.args.@"time-now" orelse @intCast(C.time(null));
    const valid_seconds: u64 = res.args.@"valid-seconds" orelse 60 * 60 * 24 * 365;
    const common_name: []const u8 = res.args.@"common-name" orelse {
        try clap.usageToFile(.stderr(), clap.Help, &params);
        return;
    };
    const organization: []const u8 = res.args.organization orelse {
        try clap.usageToFile(.stderr(), clap.Help, &params);
        return;
    };
    const country: []const u8 = res.args.country orelse {
        try clap.usageToFile(.stderr(), clap.Help, &params);
        return;
    };

    var entropy: C.mbedtls_entropy_context = undefined;
    C.mbedtls_entropy_init(&entropy);
    defer C.mbedtls_entropy_free(&entropy);

    var ctr_drbg: C.mbedtls_ctr_drbg_context = undefined;
    C.mbedtls_ctr_drbg_init(&ctr_drbg);
    try mbedtls.wrap(C.mbedtls_ctr_drbg_seed(
        &ctr_drbg,
        C.mbedtls_entropy_func,
        &entropy,
        "tboot-keygen",
        "tboot-keygen".len,
    ));
    defer C.mbedtls_ctr_drbg_free(&ctr_drbg);

    // generate RSA key
    var key: C.mbedtls_pk_context = undefined;
    C.mbedtls_pk_init(&key);
    defer C.mbedtls_pk_free(&key);

    try mbedtls.wrap(C.mbedtls_pk_setup(&key, C.mbedtls_pk_info_from_type(C.MBEDTLS_PK_RSA)));

    try mbedtls.wrap(C.mbedtls_rsa_gen_key(C.mbedtls_pk_rsa(key), C.mbedtls_ctr_drbg_random, &ctr_drbg, 4096, 65537));

    var key_buf = [_]u8{0} ** 16000;

    // NOTE: When we write out PEM files, ensure there is a trailing null byte
    // so that MBEDTLS detects these as PEM files, see https://github.com/Mbed-TLS/mbedtls/blob/6fb5120fde4ab889bea402f5ab230c720b0a3b9a/library/pkparse.c#L994.

    // write out public key
    {
        try mbedtls.wrap(C.mbedtls_pk_write_pubkey_pem(&key, &key_buf, key_buf.len));

        const pub_out = try std.fs.cwd().createFile("tboot-public.pem", .{ .mode = 0o444 });
        defer pub_out.close();

        try pub_out.writeAll(std.mem.trim(u8, &key_buf, &.{0}));
        try pub_out.writeAll(&.{0});
    }

    key_buf = std.mem.zeroes(@TypeOf(key_buf));

    // write out private key
    {
        try mbedtls.wrap(C.mbedtls_pk_write_key_pem(&key, &key_buf, key_buf.len));

        const priv_out = try std.fs.cwd().createFile("tboot-private.pem", .{ .mode = 0o444 });
        defer priv_out.close();

        try priv_out.writeAll(std.mem.trim(u8, &key_buf, &.{0}));
        try priv_out.writeAll(&.{0});
    }

    // generate x509 cert
    var issuer_crt: C.mbedtls_x509_crt = undefined;
    C.mbedtls_x509_crt_init(&issuer_crt);

    var crt: C.mbedtls_x509write_cert = undefined;
    C.mbedtls_x509write_crt_init(&crt);

    var csr: C.mbedtls_x509_csr = undefined;
    C.mbedtls_x509_csr_init(&csr);

    // self-signed
    C.mbedtls_x509write_crt_set_subject_key(&crt, &key);
    C.mbedtls_x509write_crt_set_issuer_key(&crt, &key);

    const name = try std.fmt.allocPrint(arena.allocator(), "CN={s},O={s},C={s}", .{ common_name, organization, country });
    try mbedtls.wrap(C.mbedtls_x509write_crt_set_subject_name(&crt, try arena.allocator().dupeZ(u8, name)));
    try mbedtls.wrap(C.mbedtls_x509write_crt_set_issuer_name(&crt, try arena.allocator().dupeZ(u8, name)));

    C.mbedtls_x509write_crt_set_md_alg(&crt, C.MBEDTLS_MD_SHA256);

    var serial = "1";
    try mbedtls.wrap(C.mbedtls_x509write_crt_set_serial_raw(&crt, @ptrCast(&serial), 1));

    const not_before_seconds = time_now;
    const not_after_seconds = not_before_seconds + valid_seconds;

    var before_buf = [_]u8{0} ** 15;
    var after_buf = [_]u8{0} ** 15;

    // mbedtls expects the 'Z' to not be present
    const not_before_time = try arena.allocator().dupeZ(u8, (try generalizedTime(.{ .secs = not_before_seconds }, &before_buf))[0..14]);
    const not_after_time = try arena.allocator().dupeZ(u8, (try generalizedTime(.{ .secs = not_after_seconds }, &after_buf))[0..14]);

    try mbedtls.wrap(C.mbedtls_x509write_crt_set_validity(
        &crt,
        @ptrCast(not_before_time),
        @ptrCast(not_after_time),
    ));

    try mbedtls.wrap(C.mbedtls_x509write_crt_set_basic_constraints(&crt, 1, -1));

    try mbedtls.wrap(C.mbedtls_x509write_crt_set_subject_key_identifier(&crt));
    try mbedtls.wrap(C.mbedtls_x509write_crt_set_authority_key_identifier(&crt));

    var cert_buf = [_]u8{0} ** 4096;

    // write out certificate in DER format
    {
        const len: usize = @intCast(try mbedtls.wrapMulti(C.mbedtls_x509write_crt_der(
            &crt,
            &cert_buf,
            cert_buf.len,
            C.mbedtls_ctr_drbg_random,
            &ctr_drbg,
        )));

        const cert_der_out = try std.fs.cwd().createFile("tboot-certificate.der", .{ .mode = 0o444 });
        defer cert_der_out.close();

        const start: usize = cert_buf.len - len;
        try cert_der_out.writeAll(std.mem.trim(u8, cert_buf[start .. start + len], &.{0}));
        try cert_der_out.writeAll(&.{0});
    }

    cert_buf = std.mem.zeroes(@TypeOf(cert_buf));

    // write out certificate in PEM format
    {
        try mbedtls.wrap(C.mbedtls_x509write_crt_pem(
            &crt,
            &cert_buf,
            cert_buf.len,
            C.mbedtls_ctr_drbg_random,
            &ctr_drbg,
        ));

        const cert_pem_out = try std.fs.cwd().createFile("tboot-certificate.pem", .{ .mode = 0o444 });
        defer cert_pem_out.close();

        try cert_pem_out.writeAll(&cert_buf);
    }
}
