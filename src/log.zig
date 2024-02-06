const std = @import("std");
const os = std.os;
const O = std.os.O;
const S = std.os.S;

const ServerMsg = @import("./message.zig").ServerMsg;

const LOG_BUFFER_SIZE = 2 << 12;

pub var log_buffer: ?[]align(std.mem.page_size) u8 = null;

var console_comm_fds = [_]?os.fd_t{null} ** 10; // arbitrary limit of 10 consoles
var offset: usize = 0;

pub fn initLogger() !void {
    if (log_buffer == null) {
        log_buffer = try os.mmap(
            null,
            LOG_BUFFER_SIZE,
            os.PROT.READ | os.PROT.WRITE,
            os.MAP.SHARED | os.MAP.ANONYMOUS,
            -1,
            0,
        );
    }
}

pub fn addConsole(new_fd: os.fd_t) void {
    for (&console_comm_fds) |*fd| {
        if (fd.* == null) {
            fd.* = new_fd;
            break;
        }
    }
}

pub fn deinitLogger() void {
    if (log_buffer) |buf| {
        os.munmap(buf);
    }
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    var buf = [_]u8{0} ** 256;
    const print = std.fmt.bufPrint(&buf, level_txt ++ prefix ++ format ++ "\n", args) catch return;

    if (offset + print.len > LOG_BUFFER_SIZE) {
        offset = 0;
    }

    if (log_buffer) |log_buf| {
        @memcpy(log_buf[offset .. offset + print.len], print);
    }

    offset += print.len;

    for (console_comm_fds) |fd| {
        if (fd) |real_fd| {
            var msg: ServerMsg = .{ .NewLogOffset = offset };
            _ = os.write(real_fd, std.mem.asBytes(&msg)) catch continue;
        } else {
            break;
        }
    }
}
