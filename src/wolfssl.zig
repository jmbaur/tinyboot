const std = @import("std");

const C = @cImport({
    @cDefine("struct_XSTAT", "");
    @cInclude("wolfssl/options.h"); // must come first
    @cInclude("wolfssl/openssl/evp.h");
    @cInclude("wolfssl/openssl/pem.h");
    @cInclude("wolfssl/openssl/ssl.h");
});

pub fn enableDebugging() void {
    _ = C.wolfSSL_Debugging_ON();
}

pub fn evpPkeyNew() !*C.EVP_PKEY {
    return C.EVP_PKEY_new() orelse {
        displayWolfsslErrors(@src());
        return error.WolfsslError;
    };
}

pub fn evpPkeyFree(pkey: *C.EVP_PKEY) void {
    C.EVP_PKEY_free(pkey);
}

pub fn rsaGenerateKey(len: c_int) !*C.RSA {
    return C.RSA_generate_key(len, C.RSA_F4, null, null) orelse {
        displayWolfsslErrors(@src());
        return error.WolfsslError;
    };
}

pub fn evpPkeyAssignRsa(pkey: *C.EVP_PKEY, rsa: *C.RSA) !void {
    if (C.EVP_PKEY_assign_RSA(pkey, rsa) != 1) {
        displayWolfsslErrors(@src());
        return error.WolfsslError;
    }
}

pub fn x509New() !*C.X509 {
    return C.X509_new() orelse {
        displayWolfsslErrors(@src());
        return error.WolfsslError;
    };
}

pub fn x509Free(x509: *C.X509) void {
    C.X509_free(x509);
}

pub fn x509GetSerialNumber(x509: *C.X509) !*C.ASN1_INTEGER {
    return C.X509_get_serialNumber(x509) orelse {
        displayWolfsslErrors(@src());
        return error.WolfsslError;
    };
}

pub fn asn1IntegerSet(integer: *C.ASN1_INTEGER, value: c_long) !void {
    try handleOpensslError(C.ASN1_INTEGER_set(integer, value));
}

pub fn x509GetNotBefore(x509: *C.X509) [*c]C.ASN1_TIME {
    return C.X509_get_notBefore(x509);
}

pub fn x509GetNotAfter(x509: *C.X509) [*c]C.ASN1_TIME {
    return C.X509_get_notAfter(x509);
}

pub fn x509GmtimeAdj(time: [*c]C.ASN1_TIME, value: c_long) void {
    _ = C.X509_gmtime_adj(time, value);
}

pub fn x509SetPubkey(x509: *C.X509, pkey: *C.EVP_PKEY) !void {
    try handleOpensslError(C.X509_set_pubkey(x509, pkey));
}

pub fn x509GetSubjectName(x509: *C.X509) !*C.X509_NAME {
    return C.wolfSSL_X509_get_subject_name(x509) orelse {
        displayWolfsslErrors(@src());
        return error.WolfsslError;
    };
}

pub fn x509NameAddEntryByTxt(name: *C.X509_NAME, field: enum {
    country,
    common_name,
    organization,
}, value: []const u8) !void {
    try handleOpensslError(C.X509_NAME_add_entry_by_txt(
        name,
        switch (field) {
            .country => "C",
            .common_name => "CN",
            .organization => "O",
        },
        C.MBSTRING_ASC,
        value.ptr,
        @intCast(value.len),
        -1,
        0,
    ));
}

pub fn x509SetIssuerName(x509: *C.X509, name: *C.X509_NAME) !void {
    try handleOpensslError(C.X509_set_issuer_name(x509, name));
}

pub fn x509Sign(x509: *C.X509, pkey: *C.EVP_PKEY) !void {
    try handleOpensslError(C.X509_sign(x509, pkey, C.EVP_sha512()));
}

pub fn bioNewFile(name: []const u8) !*C.BIO {
    return C.BIO_new_file(@ptrCast(name), "wb") orelse {
        displayWolfsslErrors(@src());
        return error.WolfsslError;
    };
}

pub fn bioFree(bio: *C.BIO) void {
    _ = C.BIO_free(bio);
}

pub fn pemWriteBioPrivateKey(bio: *C.BIO, pkey: *C.EVP_PKEY) !void {
    try handleOpensslError(C.PEM_write_bio_PrivateKey(
        bio, // write the key to the file we've opened
        pkey, // our key from earlier
        null, // default cipher for encrypting the key on disk
        null, // passphrase required for decrypting the key on disk
        0, // length of the passphrase string
        null, // callback for requesting a password
        null, // data to pass to the callback
    ));
}

pub fn pemWriteBioPubkey(bio: *C.BIO, pkey: *C.EVP_PKEY) !void {
    try handleOpensslError(C.PEM_write_bio_PUBKEY(bio, pkey));
}

pub fn pemWriteBioX509(bio: *C.BIO, x509: *C.X509) !void {
    try handleOpensslError(C.PEM_write_bio_X509(bio, x509));
}

pub fn i2dX509Bio(bio: *C.BIO, x509: *C.X509) !void {
    try handleOpensslError(C.i2d_X509_bio(bio, x509));
}

fn drainOpensslErrors() void {
    if (C.ERR_peek_error() == 0) {
        return;
    }

    while (C.ERR_get_error() != 0) {}
}

inline fn handleOpensslError(openssl_error: c_int) !void {
    if (openssl_error == 0) {
        displayWolfsslErrors(@src());
        return error.WolfsslError;
    }
}

fn displayWolfsslErrors(src: std.builtin.SourceLocation) void {
    if (C.ERR_peek_error() == 0) {
        return;
    }

    var stderr = std.io.getStdErr().writer();
    stderr.print("WolfSSL error at {s}:{}:\n", .{ src.file, src.line }) catch unreachable;

    var buff = [_]u8{0} ** 1024;

    while (true) {
        const rc = C.ERR_get_error();
        if (rc == 0) {
            break;
        }
        _ = C.ERR_error_string(rc, &buff);
        stderr.print("- {s}\n", .{buff}) catch unreachable;
    }
}
