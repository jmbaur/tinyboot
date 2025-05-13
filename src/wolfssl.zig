const std = @import("std");

const C = @cImport({
    @cDefine("struct_XSTAT", "");
    @cInclude("wolfssl/options.h");
    @cInclude("wolfssl/openssl/ssl.h");
});

pub fn drainOpensslErrors() void {
    if (C.ERR_peek_error() == 0) {
        return;
    }

    while (C.ERR_get_error() != 0) {}
}

pub inline fn handleOpensslError(openssl_error: c_int) !void {
    if (openssl_error == 0) {
        displayOpensslErrors(@src());
        return error.OpensslError;
    }
}

pub fn displayOpensslErrors(src: std.builtin.SourceLocation) void {
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
