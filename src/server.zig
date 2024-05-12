const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const posix = std.posix;

const system = @import("./system.zig");
const ClientMsg = @import("./message.zig").ClientMsg;
const ServerMsg = @import("./message.zig").ServerMsg;
const readMessage = @import("./message.zig").readMessage;
const writeMessage = @import("./message.zig").writeMessage;

pub const Server = struct {
    allocator: std.mem.Allocator,

    /// The underlying server
    inner: std.net.Server,

    /// Clients connected to the server
    clients: std.ArrayList(std.net.Stream),

    pub fn init(allocator: std.mem.Allocator) !@This() {
        const socket_addr = try std.net.Address.initUnix("/run/bus");

        return @This(){
            .allocator = allocator,
            .inner = try socket_addr.listen(.{}),
            .clients = std.ArrayList(std.net.Stream).init(allocator),
        };
    }

    pub fn register_self(self: *@This(), epoll_fd: posix.fd_t) !void {
        try posix.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, self.inner.stream.handle, @constCast(&.{
            .events = os.linux.EPOLL.IN,
            .data = .{ .fd = self.inner.stream.handle },
        }));
    }

    pub fn register_client(self: *@This(), epoll_fd: posix.fd_t, client_stream: std.net.Stream) !void {
        try self.clients.append(client_stream);

        try posix.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, client_stream.handle, @constCast(&.{
            .events = os.linux.EPOLL.IN,
            .data = .{ .fd = client_stream.handle },
        }));
    }

    pub fn force_shell(self: *@This()) void {
        for (self.clients.items) |client| {
            writeMessage(ServerMsg{ .msg = .ForceShell }, client.writer()) catch {};
        }
    }

    pub fn handle_new_event(self: *@This(), event: os.linux.epoll_event) !?posix.RebootCommand {
        std.log.debug("got new event on server: {}", .{event.data.fd});
        for (self.clients.items) |client| {
            if (event.data.fd == client.handle) {
                const msg = readMessage(ClientMsg, self.allocator, client.reader()) catch |err| switch (err) {
                    error.EOF => continue, // Handle client disconnects
                    else => return err,
                };
                defer msg.deinit();

                switch (msg.value.msg) {
                    .Reboot => return posix.RebootCommand.RESTART,
                    .Poweroff => return posix.RebootCommand.POWER_OFF,
                    .Empty => {},
                }
            }
        }

        return null;
    }

    pub fn deinit(self: *@This()) void {
        for (self.clients.items) |client| {
            client.close();
        }
        self.clients.deinit();

        self.inner.stream.close();
        std.fs.cwd().deleteFile("/run/bus") catch {};
    }
};
