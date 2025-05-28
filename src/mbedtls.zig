const std = @import("std");

const C = @cImport({
    @cInclude("mbedtls/error.h");
});

var err_buf = [_]u8{0} ** 1024;

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
        C.mbedtls_strerror(return_code, &err_buf, err_buf.len);
        std.log.err("mbedtls error({}): {s}", .{ @abs(return_code), err_buf });
        return error.MbedtlsError;
    }

    if (return_code_type == .negative) {
        return return_code;
    }
}
