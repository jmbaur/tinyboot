const std = @import("std");

var log_file: ?std.fs.File = null;

pub fn initLogger(t: enum {
    Server,
    Client,
}) !void {
    switch (t) {
        .Server => {
            log_file = try std.fs.createFileAbsolute("/run/log", .{
                .truncate = true,
            });
        },
        .Client => {},
    }
}

pub fn deinitLogger() void {
    if (log_file) |file| {
        file.close();
    }
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix1 = comptime level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    if (log_file) |file| {
        // Write the message to the log file, silently ignoring any errors
        file.writer().print(prefix1 ++ prefix2 ++ format ++ "\n", args) catch {};
    } else {
        // Print the message to stderr, silently ignoring any errors
        std.debug.print(prefix1 ++ prefix2 ++ format ++ "\n", args);
    }
}
