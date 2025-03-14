const std = @import("std");

const C = @cImport({
    @cInclude("openssl/err.h");
});

pub fn drainOpensslErrors() void {
    if (C.ERR_peek_error() == 0) {
        return;
    }

    while (C.ERR_get_error() != 0) {}
}

pub fn displayOpensslErrors(src: std.builtin.SourceLocation) void {
    if (C.ERR_peek_error() == 0) {
        return;
    }

    var stderr = std.io.getStdErr().writer();
    stderr.print("OpenSSL error at {s}:{}:\n", .{ src.file, src.line }) catch unreachable;

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
