const std = @import("std");

pub const Console = struct {
    serial_char_device: ?[]const u8 = null,

    pub fn parseFromStr(tty: []const u8) !@This() {
        if (std.mem.indexOf(u8, tty, "tty")) |idx| {
            if (idx != 0) {
                return @This(){};
            }
        } else {
            return @This(){};
        }

        var rest = std.mem.trimLeft(u8, tty, "tty");

        _ = std.fmt.parseInt(u8, rest, 10) catch {
            return @This(){ .serial_char_device = tty };
        };

        return @This(){ .serial_char_device = null };
    }
};

// TODO(jared): use a set to exclude duplicate consoles
pub const Config = struct {
    consoles: []Console,

    pub fn parseFromArgs(a: std.mem.Allocator, it: *std.process.ArgIterator) !@This() {
        var cfg = @This(){ .consoles = &[_]Console{} };

        var consoles = std.ArrayList(Console).init(a);
        errdefer consoles.deinit();

        var has_vt = false;
        while (it.next()) |next| {
            var split = std.mem.splitSequence(u8, next, "=");

            const k = split.next();
            const v = split.next();

            if (k != null and v != null) {
                const key = k.?;
                const value = v.?;

                if (std.mem.eql(u8, key, "tboot.console")) {
                    const console = try Console.parseFromStr(value);

                    if (!has_vt and console.serial_char_device == null) {
                        has_vt = true;
                        try consoles.append(console);
                    } else if (console.serial_char_device != null) {
                        try consoles.append(console);
                    }
                }
            }
        }

        cfg.consoles = try consoles.toOwnedSlice();

        return cfg;
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

test "tty parsing" {
    try std.testing.expectEqual(
        Console{ .serial_char_device = null },
        try Console.parseFromStr(""),
    );

    try std.testing.expectEqual(
        Console{ .serial_char_device = null },
        try Console.parseFromStr("tty3"),
    );

    try std.testing.expectEqual(
        Console{ .serial_char_device = "ttyS0" },
        try Console.parseFromStr("ttyS0"),
    );
}
