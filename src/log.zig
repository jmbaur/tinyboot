const std = @import("std");

const LOG_PREFIX = "boot";

const KMSG = "/dev/char/1:11";

const SYSLOG_FACILITY_USER = 1;

// https://github.com/torvalds/linux/blob/55027e689933ba2e64f3d245fb1ff185b3e7fc81/kernel/printk/internal.h#L38C9-L38C28
// https://github.com/torvalds/linux/blob/55027e689933ba2e64f3d245fb1ff185b3e7fc81/kernel/printk/printk.c#L735
const PRINTKRB_RECORD_MAX = 1024;

var mutex: std.Io.Mutex = .init;
var kmsg: ?std.Io.File = null;
var io_: ?std.Io = null;

// The Zig string formatter can make many individual writes to our
// writer depending on the format string, so we do all the formatting
// ahead of time here so we can perform the write all at once when the
// log line goes to the kernel.
var log_buf: [PRINTKRB_RECORD_MAX]u8 = undefined;

pub fn init(io: std.Io) !void {
    if (std.Io.Dir.cwd().openFile(
        io,
        "/proc/sys/kernel/printk_devkmsg",
        .{ .mode = .write_only },
    )) |printk_devkmsg| {
        defer printk_devkmsg.close(io);
        var writer = printk_devkmsg.writer(io, &.{});
        writer.interface.writeAll("on\n") catch {};
    } else |_| {}

    kmsg = try std.Io.Dir.cwd().openFile(io, KMSG, .{ .mode = .write_only });
    io_ = io;
}

pub fn deinit(io: std.Io) void {
    if (kmsg) |file| {
        file.close(io);
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
        var fbs = std.Io.Writer.fixed(&buf);

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

        fbs.print("{d}", .{syslog_level}) catch return;
        break :b fbs.buffered();
    };

    const file = kmsg orelse return;
    const io = io_ orelse return;

    mutex.lock(io) catch return;
    defer mutex.unlock(io);

    var writer = file.writer(io, &log_buf);
    writer.interface.print(
        "<" ++ syslog_prefix ++ ">" ++ LOG_PREFIX ++ ": " ++ format ++ "\n",
        args,
    ) catch {};
    writer.interface.flush() catch {};
}
