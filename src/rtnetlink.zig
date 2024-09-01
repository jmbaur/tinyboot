const std = @import("std");
const posix = std.posix;

const nl = @import("netlink");

const linux_headers = @import("linux_headers");

const RtNetlink = @This();

/// Socket where all netlink communication occurs.
sock: posix.fd_t,
nl_handle: nl.Handle,

pub fn init(buf: []u8) !RtNetlink {
    const sock = try posix.socket(
        posix.AF.NETLINK,
        posix.SOCK.RAW,
        posix.system.NETLINK.ROUTE,
    );
    errdefer posix.close(sock);

    return .{
        .sock = sock,
        .nl_handle = nl.Handle.init(sock, buf),
    };
}

pub fn deinit(self: *RtNetlink) void {
    posix.close(self.sock);
}

fn finalizeHeader(self: *RtNetlink, payload_len: u32, hdr: *posix.system.nlmsghdr) void {
    _ = self;
    hdr.*.len = payload_len + @sizeOf(posix.system.nlmsghdr);
}

const LinkListRequest = nl.message.Request(posix.system.NetlinkMessageType.RTM_GETLINK, linux_headers.rtgenmsg);
const LinkResponse = nl.message.Response(posix.system.NetlinkMessageType.RTM_NEWLINK, posix.system.ifinfomsg);

pub fn get_links(self: *RtNetlink) !void {
    const req = try self.nl_handle.new_req(LinkListRequest);
    req.nlh.*.flags |= posix.system.NLM_F_DUMP;
    try self.nl_handle.send(req);

    var res = self.nl_handle.recv_all(LinkResponse);
    while (try res.next()) |payload| {
        std.debug.print("{}\n", .{payload.value});
    }
}

const AddressListRequest = nl.message.Request(posix.system.NetlinkMessageType.RTM_GETADDR, linux_headers.ifaddrmsg);
const AddressResponse = nl.message.Response(posix.system.NetlinkMessageType.RTM_NEWADDR, linux_headers.ifaddrmsg);

fn get_addresses(self: *RtNetlink) !void {
    const req = try self.nl_handle.new_req(AddressListRequest);
    req.nlh.*.flags |= posix.system.NLM_F_DUMP;
    try self.nl_handle.send(req);

    var res = self.nl_handle.recv_all(AddressResponse);
    while (try res.next()) |payload| {
        std.debug.print("{}\n", .{payload.value});
    }
}

pub fn main() !void {
    var buf = [_]u8{0} ** 4096;
    var conn = try RtNetlink.init(&buf);
    defer conn.deinit();

    try conn.get_links();
    try conn.get_addresses();
}
