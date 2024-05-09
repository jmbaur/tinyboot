const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const posix = std.posix;

const zbor = @import("zbor");

const system = @import("./system.zig");
const ClientMsg = @import("./message.zig").ClientMsg;
const ServerMsg = @import("./message.zig").ServerMsg;

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
            var msg: ServerMsg = .ForceShell;
            client.writeAll(std.mem.asBytes(&msg)) catch {};
        }
    }

    pub fn handle_new_event(self: *@This(), event: os.linux.epoll_event) !?posix.RebootCommand {
        std.log.debug("got new event on server: {}", .{event.data.fd});
        for (self.clients.items) |client| {
            std.log.debug("looking at client: {}", .{client.handle});
            if (event.data.fd == client.handle) {
                var msg: ClientMsg = .None;
                _ = try client.readAll(std.mem.asBytes(&msg));

                switch (msg) {
                    .Reboot => return posix.RebootCommand.RESTART,
                    .Poweroff => return posix.RebootCommand.POWER_OFF,
                    .None => {},
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
