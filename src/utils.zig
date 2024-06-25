const std = @import("std");
const posix = std.posix;

pub fn enumFromStr(T: anytype, value: []const u8) !T {
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, value)) {
            return @field(T, field.name);
        }
    }

    return error.NotFound;
}

pub fn eventfdWriteEnum(T: anytype, eventfd: posix.fd_t, value: T) !void {
    // Add 1 to ensure that new reads on the eventfd descriptor don't block.
    // See eventfd(2).
    var out: u64 = @intFromEnum(value) + 1;
    _ = try posix.write(eventfd, std.mem.asBytes(&out));
}

pub fn eventfdReadEnum(T: anytype, eventfd: posix.fd_t) !T {
    var input: u64 = @typeInfo(T).Enum.fields.len;
    _ = try posix.read(eventfd, std.mem.asBytes(&input));
    // Subtract 1 to ensure we are consistent with eventfdWriteEnum.
    return @enumFromInt(input - 1);
}
