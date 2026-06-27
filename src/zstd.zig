const std = @import("std");
const zstd = @import("zstd_c");

pub const Compressed = struct {
    allocator: std.mem.Allocator,
    buf: []u8,
    end: usize,

    pub fn content(self: *const @This()) []u8 {
        return self.buf[0..self.end];
    }

    pub fn deinit(self: *const @This()) void {
        self.allocator.free(self.buf);
    }
};

pub fn compress(allocator: std.mem.Allocator, buf: []const u8) !Compressed {
    const compressed_size = zstd.ZSTD_compressBound(buf.len);
    const compressed_buf = try allocator.alloc(u8, compressed_size);
    errdefer allocator.free(compressed_buf);

    const rc = zstd.ZSTD_compress(
        @ptrCast(compressed_buf),
        compressed_size,
        @ptrCast(buf),
        buf.len,
        1,
    );

    if (zstd.ZSTD_isError(rc) == 1) {
        std.log.err("failed to compress: {s}", .{zstd.ZSTD_getErrorName(rc)});
        return error.CompressFail;
    }

    return .{
        .allocator = allocator,
        .buf = compressed_buf,
        .end = rc,
    };
}
