const std = @import("std");
const posix = std.posix;

pub const IterResult = enum { @"break", @"continue" };

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

pub fn IoPair(I: type, O: type) type {
    return struct {
        in: posix.fd_t,
        out: posix.fd_t,

        pub const Inverted = IoPair(O, I);

        pub fn init() !@This() {
            return .{
                .in = try posix.eventfd(0, 0),
                .out = try posix.eventfd(0, 0),
            };
        }

        pub fn deinit(self: *@This()) void {
            posix.close(self.in);
            posix.close(self.out);
        }

        pub fn invert(self: *@This()) Inverted {
            return .{
                .in = self.out,
                .out = self.in,
            };
        }

        pub fn write(self: *const @This(), data: O) !void {
            try eventfdWriteEnum(O, self.out, data);
        }

        pub fn read(self: *const @This()) !I {
            return try eventfdReadEnum(I, self.in);
        }
    };
}
