const std = @import("std");

const LOG_PREFIX = "boot";

const KMSG = "/dev/char/1:11";

const SYSLOG_FACILITY_USER = 1;

// https://github.com/torvalds/linux/blob/55027e689933ba2e64f3d245fb1ff185b3e7fc81/kernel/printk/internal.h#L38C9-L38C28
// https://github.com/torvalds/linux/blob/55027e689933ba2e64f3d245fb1ff185b3e7fc81/kernel/printk/printk.c#L735
const PRINTKRB_RECORD_MAX = 1024;

var mutex = std.Thread.Mutex{};
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

    const file = kmsg orelse return;

    mutex.lock();
    defer mutex.unlock();

    // The Zig string formatter can make many individual writes to our
    // writer depending on the format string, so we do all the formatting
    // ahead of time here so we can perform the write all at once when the
    // log line goes to the kernel.
    var buf: [PRINTKRB_RECORD_MAX]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    stream.writer().print(
        "<" ++ syslog_prefix ++ ">" ++ LOG_PREFIX ++ ": " ++ format,
        args,
    ) catch {};
    file.writeAll(buf[0..stream.pos]) catch {};
}
