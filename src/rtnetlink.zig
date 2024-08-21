const std = @import("std");
const posix = std.posix;

const linux_headers = @import("linux_headers");

const NLMSG_NOOP = linux_headers.NLMSG_NOOP;
const NLMSG_ERROR = linux_headers.NLMSG_ERROR;
const NLMSG_DONE = linux_headers.NLMSG_DONE;
const NLMSG_OVERRUN = linux_headers.NLMSG_OVERRUN;

const RtNetlink = @This();

/// Socket where all netlink communication occurs.
sock: posix.fd_t,
pid: u32,
seq: u32 = 1,

pub fn init() !RtNetlink {
    const pid = posix.system.getpid();

    const sock = try posix.socket(
        posix.AF.NETLINK,
        posix.SOCK.RAW,
        posix.system.NETLINK.ROUTE,
    );
    errdefer posix.close(sock);

    const nls = posix.sockaddr.nl{
        .groups = 0,
        .pid = @bitCast(pid),
    };
    try posix.bind(sock, @ptrCast(&nls), @sizeOf(posix.sockaddr.nl));

    return .{
        .pid = @bitCast(pid),
        .sock = sock,
    };
}

pub fn deinit(self: *RtNetlink) void {
    posix.close(self.sock);
}

fn sendMessage(self: *RtNetlink, T: anytype, payload: *T, @"type": posix.system.NetlinkMessageType, flags: u16) !void {
    var buf: [@sizeOf(posix.system.nlmsghdr) + @sizeOf(T)]u8 = undefined;

    self.seq += 1;

    const header = posix.system.nlmsghdr{
        // Every message sent to the kernel needs to be a request
        .flags = flags | posix.system.NLM_F_REQUEST,
        .len = @sizeOf(T) + @sizeOf(posix.system.nlmsghdr),
        .pid = self.pid,
        .seq = self.seq,
        .type = @"type",
    };

    @memcpy(buf[0..@sizeOf(posix.system.nlmsghdr)], std.mem.asBytes(&header));
    @memcpy(buf[@sizeOf(posix.system.nlmsghdr)..], std.mem.asBytes(payload));

    const n_wrote = try posix.send(self.sock, &buf, 0);
    if (n_wrote != buf.len) {
        // TODO(jared): use a different error
        return error.InvalidArgument;
    }
}

fn receiveMessage(self: *RtNetlink) !void {
    var buf: [2048]u8 = undefined;
    const n_read = try posix.recvfrom(self.sock, &buf, 0, null, null);
    if (n_read < @sizeOf(posix.system.nlmsghdr)) {
        return error.InvalidArgument;
    }

    const header: *posix.system.nlmsghdr = @ptrCast(@alignCast(buf[0..@sizeOf(posix.system.nlmsghdr)]));
    const payload = buf[0..n_read];

    if (header.type == .ERROR) {
        @panic("NLMSG_ERROR");
    }

    std.log.debug("payload: {any}", .{payload});
}

fn finalizeHeader(self: *RtNetlink, payload_len: u32, hdr: *posix.system.nlmsghdr) void {
    _ = self;
    hdr.*.len = payload_len + @sizeOf(posix.system.nlmsghdr);
}

// RTM_GETLINK
pub fn get_links(self: *RtNetlink) !void {
    var ifinfo = std.mem.zeroes(posix.system.ifinfomsg);

    try self.sendMessage(posix.system.ifinfomsg, &ifinfo, .RTM_GETLINK, posix.system.NLM_F_DUMP);
    try self.receiveMessage();
}

// RTM_SETLINK
fn set_link() void {}
// RTM_NEWLINK
fn net_link() void {}

// RTM_NEWADDR
fn new_addr() void {}
// RTM_DELADDR
fn del_addr() void {}
// RTM_GETADDR
fn get_addr() void {}

// RTM_NEWROUTE
fn new_route() void {}
// RTM_DELROUTE
fn del_route() void {}
// RTM_GETROUTE
fn get_route() void {}

// RTM_NEWNEIGH
fn new_neighbor() void {}
// RTM_DELNEIGH
fn del_neighbor() void {}
// RTM_GETNEIGH
fn get_neighbor() void {}

pub fn main() !void {
    var conn = try RtNetlink.init();
    defer conn.deinit();

    try conn.get_links();
}
