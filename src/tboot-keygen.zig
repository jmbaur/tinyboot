const std = @import("std");
const clap = @import("clap");
const builtin = @import("builtin");

const openssl = @import("./wolfssl.zig");

const handleOpensslError = openssl.handleOpensslError;
const displayOpensslErrors = openssl.displayOpensslErrors;

const C = @cImport({
    @cDefine("struct_XSTAT", "");
    @cInclude("wolfssl/options.h");
    @cInclude("wolfssl/openssl/ssl.h");
    @cInclude("wolfssl/openssl/evp.h");
    @cInclude("wolfssl/openssl/pem.h");
});

// https://stackoverflow.com/questions/256405/programmatically-create-x509-certificate-using-openssl
pub fn main() !void {
    if (builtin.mode == .Debug) {
        _ = C.wolfSSL_Debugging_ON();
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                  Display this help and exit.
        \\-n, --common-name <STR>     Common name for certificate.
        \\-o, --organization <STR>    Organization for certificate.
        \\-c, --country <STR>         Country for certificate.
        \\-v, --valid-seconds <NUM>   Number of seconds the certificate is valid for (defaults to 31536000, 1 year).
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

    const pkey = C.EVP_PKEY_new() orelse {
        displayOpensslErrors(@src());
        return error.OpensslError;
    };
    defer C.EVP_PKEY_free(pkey);

    // No need to free the *RSA, it is freed when *PKEY is freed.
    const rsa = C.RSA_generate_key(4096, C.RSA_F4, null, null) orelse {
        displayOpensslErrors(@src());
        return error.OpensslError;
    };

    if (C.EVP_PKEY_assign_RSA(pkey, rsa) != 1) {
        displayOpensslErrors(@src());
        return error.OpensslError;
    }

    const x509 = C.X509_new() orelse {
        displayOpensslErrors(@src());
        return error.OpensslError;
    };
    defer C.X509_free(x509);

    try handleOpensslError(C.ASN1_INTEGER_set(C.X509_get_serialNumber(x509), 1));
    _ = C.X509_gmtime_adj(C.X509_get_notBefore(x509), 0);
    _ = C.X509_gmtime_adj(C.X509_get_notAfter(x509), valid_seconds);

    try handleOpensslError(C.X509_set_pubkey(x509, pkey));

    const name = C.wolfSSL_X509_get_subject_name(x509) orelse {
        displayOpensslErrors(@src());
        return error.OpensslError;
    };

    try handleOpensslError(
        C.X509_NAME_add_entry_by_txt(name, "C", C.MBSTRING_ASC, country.ptr, @intCast(country.len), -1, 0),
    );

    try handleOpensslError(
        C.X509_NAME_add_entry_by_txt(name, "CN", C.MBSTRING_ASC, common_name.ptr, @intCast(common_name.len), -1, 0),
    );

    try handleOpensslError(
        C.X509_NAME_add_entry_by_txt(name, "O", C.MBSTRING_ASC, organization.ptr, @intCast(organization.len), -1, 0),
    );

    try handleOpensslError(C.X509_set_issuer_name(x509, name));

    try handleOpensslError(C.X509_sign(x509, pkey, C.EVP_sha512()));

    const private_key_pem_file = C.BIO_new_file("tboot-private.pem", "wb") orelse {
        displayOpensslErrors(@src());
        return error.OpensslError;
    };
    defer _ = C.BIO_free(private_key_pem_file);

    try handleOpensslError(C.PEM_write_bio_PrivateKey(
        private_key_pem_file, // write the key to the file we've opened
        pkey, // our key from earlier
        null, // default cipher for encrypting the key on disk
        null, // passphrase required for decrypting the key on disk
        0, // length of the passphrase string
        null, // callback for requesting a password
        null, // data to pass to the callback
    ));

    const public_key_pem_file = C.BIO_new_file("tboot-public.pem", "wb") orelse {
        displayOpensslErrors(@src());
        return error.OpensslError;
    };
    defer _ = C.BIO_free(public_key_pem_file);

    try handleOpensslError(C.PEM_write_bio_PUBKEY(public_key_pem_file, pkey));

    const cert_pem_file = C.fopen("tboot-certificate.pem", "wb") orelse {
        displayOpensslErrors(@src());
        return error.OpensslError;
    };
    defer _ = C.fclose(cert_pem_file);

    try handleOpensslError(C.PEM_write_X509(
        cert_pem_file, // write the certificate to the file we've opened
        x509, // our certificate
    ));

    const cert_der_file = C.BIO_new_file("tboot-certificate.der", "wb") orelse {
        displayOpensslErrors(@src());
        return error.OpensslError;
    };
    defer _ = C.BIO_free(cert_der_file);

    try handleOpensslError(C.i2d_X509_bio(cert_der_file, x509));
}
