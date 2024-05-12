const std = @import("std");
const json = std.json;
const BootEntry = @import("./boot.zig").BootEntry;

fn message(comptime T: type) type {
    return struct {
        msg: T,
    };
}

/// Message that can be sent to the server
pub const ClientMsg = message(union(enum) {
    /// Request to the server that the system should be powered off.
    Poweroff,

    /// Request to the server that the system should be rebooted.
    Reboot,

    /// Request to the server that this boot entry should be booted.
    Boot: BootEntry,

    /// Empty message
    Empty,
});

/// Message that can be sent to a client
pub const ServerMsg = message(union(enum) {
    /// Spawn a shell prompt, even if the user is not present
    ForceShell,
});

// This number is arbitrary, we may need to increase it at some point.
const MAX_BUF_SIZE = 1 << 12;

/// Caller is responsible for return value's memory.
pub fn readMessage(comptime T: type, allocator: std.mem.Allocator, r: std.net.Stream.Reader) !json.Parsed(T) {
    var buf: [MAX_BUF_SIZE]u8 = undefined;

    const n_bytes = try r.read(&buf);

    // If we end up here, this means our connection was dropped on the other
    // side. This should only happen if the server has completed successfully
    // or if I wrote a bug :).
    if (n_bytes == 0) {
        return error.EOF;
    }

    return try json.parseFromSlice(T, allocator, buf[0..n_bytes], .{});
}

pub fn writeMessage(value: anytype, w: std.net.Stream.Writer) !void {
    // Write to fixed buffer first prior to doing write to socket, since the
    // json writer will perform many writes for each character needed to write
    // valid json.
    var buf: [MAX_BUF_SIZE]u8 = undefined;
    var wbuf = std.io.fixedBufferStream(&buf);

    try json.stringify(value, .{}, wbuf.writer());

    try w.writeAll(wbuf.buffer[0..(try wbuf.getPos())]);
}
