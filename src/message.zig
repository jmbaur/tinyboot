const std = @import("std");
const json = std.json;

/// Message that can be sent to the server
pub const ClientMsg = union(enum) {
    /// Request to the server that the system should be powered off.
    Poweroff,

    /// Request to the server that the system should be rebooted.
    Reboot,

    /// Empty message
    None,
};

/// Message that can be sent to a client
pub const ServerMsg = union(enum) {
    /// Spawn a shell prompt, even if the user is not present
    ForceShell,
};

pub fn read_message(comptime T: type, r: std.net.Stream.Reader) !T {
    var buf: [1024]u8 = undefined;
    const n_bytes = try r.read(&buf);
    // If we end up here, this means our connection was dropped on the other
    // side. This should only happen if the server has completed successfully
    // or if I wrote a bug :).
    if (n_bytes == 0) {
        return error.EOF;
    }

    var jbuf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&jbuf);
    return try json.parseFromSliceLeaky(T, fba.allocator(), buf[0..n_bytes], .{});
}

pub fn write_message(value: anytype, w: std.net.Stream.Writer) !void {
    try json.stringify(value, .{}, w);
}
