const std = @import("std");

const KMSG = "/dev/char/1:11";

const SYSLOG_FACILITY_USER = 1;

var m = std.Thread.Mutex{};
var kmsg: ?std.fs.File = null;

pub fn init() !void {
    kmsg = try std.fs.cwd().openFile(KMSG, .{ .mode = .write_only });
}

pub fn deinit() void {
    if (kmsg) |file| {
        file.close();
    }
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;

    const syslog_prefix = comptime b: {
        var buf: [2]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);

        // 0 KERN_EMERG
        // 1 KERN_ALERT
        // 2 KERN_CRIT
        // 3 KERN_ERR
        // 4 KERN_WARNING
        // 5 KERN_NOTICE
        // 6 KERN_INFO
        // 7 KERN_DEBUG

        // https://github.com/torvalds/linux/blob/f2661062f16b2de5d7b6a5c42a9a5c96326b8454/Documentation/ABI/testing/dev-kmsg#L1
        const syslog_level = ((SYSLOG_FACILITY_USER << 3) | switch (level) {
            .err => 3,
            .warn => 4,
            .info => 6,
            .debug => 7,
        });

        std.fmt.formatIntValue(syslog_level, "", .{}, fbs.writer()) catch return;
        break :b fbs.getWritten();
    };

    if (kmsg) |file| {
        m.lock();
        defer m.unlock();

        file.writer().print(
            "<" ++ syslog_prefix ++ ">" ++ "boot: " ++ format,
            args,
        ) catch {};
    }
}
