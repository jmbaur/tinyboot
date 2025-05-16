const std = @import("std");
const clap = @import("clap");

const wolfssl = @import("./wolfssl.zig");

// https://stackoverflow.com/questions/256405/programmatically-create-x509-certificate-using-openssl
pub fn main() !void {
    wolfssl.enableLogging();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                  Display this help and exit.
        \\-n, --common-name <STR>     Common name for certificate.
        \\-o, --organization <STR>    Organization for certificate.
        \\-c, --country <STR>         Country for certificate.
        \\-s, --valid-seconds <NUM>   Number of seconds the certificate is valid for (defaults to 31536000, 1 year).
        \\
    );

    const parsers = comptime .{
        .STR = clap.parsers.string,
        .NUM = clap.parsers.int(c_long, 10),
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

    const valid_seconds: c_long = res.args.@"valid-seconds" orelse 60 * 60 * 24 * 365;
    const common_name: []const u8 = res.args.@"common-name" orelse {
        try clap.usage(stderr, clap.Help, &params);
        return;
    };
    const organization: []const u8 = res.args.organization orelse {
        try clap.usage(stderr, clap.Help, &params);
        return;
    };
    const country: []const u8 = res.args.country orelse {
        try clap.usage(stderr, clap.Help, &params);
        return;
    };

    const pkey = try wolfssl.evpPkeyNew();
    defer wolfssl.evpPkeyFree(pkey);

    // No need to free the *RSA, it is freed when *PKEY is freed.
    const rsa = try wolfssl.rsaGenerateKey(4096);

    try wolfssl.evpPkeyAssignRsa(pkey, rsa);

    const x509 = try wolfssl.x509New();
    defer wolfssl.x509Free(x509);

    try wolfssl.asn1IntegerSet(try wolfssl.x509GetSerialNumber(x509), 1);
    wolfssl.x509GmtimeAdj(wolfssl.x509GetNotBefore(x509), 0);
    wolfssl.x509GmtimeAdj(wolfssl.x509GetNotAfter(x509), valid_seconds);

    try wolfssl.x509SetPubkey(x509, pkey);

    const name = try wolfssl.x509GetSubjectName(x509);

    try wolfssl.x509NameAddEntryByTxt(name, .country, country);
    try wolfssl.x509NameAddEntryByTxt(name, .common_name, common_name);
    try wolfssl.x509NameAddEntryByTxt(name, .organization, organization);

    try wolfssl.x509SetIssuerName(x509, name);

    try wolfssl.x509Sign(x509, pkey);

    const private_key_pem_file = try wolfssl.bioNewFile("tboot-private.pem", "wb");
    defer wolfssl.bioFree(private_key_pem_file);

    try wolfssl.pemWriteBioPrivateKey(private_key_pem_file, pkey);

    const public_key_pem_file = try wolfssl.bioNewFile("tboot-public.pem", "wb");
    defer wolfssl.bioFree(public_key_pem_file);

    try wolfssl.pemWriteBioPubkey(public_key_pem_file, pkey);

    const cert_pem_file = try wolfssl.bioNewFile("tboot-certificate.pem", "wb");
    defer wolfssl.bioFree(cert_pem_file);

    try wolfssl.pemWriteBioX509(cert_pem_file, x509);

    const cert_der_file = try wolfssl.bioNewFile("tboot-certificate.der", "wb");
    defer wolfssl.bioFree(cert_der_file);

    try wolfssl.i2dX509Bio(cert_der_file, x509);
}
