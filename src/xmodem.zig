const std = @import("std");
const os = std.os;
const Crc16Xmodem = std.hash.crc.Crc16Xmodem;

const linux_headers = @import("linux_headers");

const system = @import("./system.zig");

const Error = error{
    InvalidReceiveLength,
    InvalidSendLength,
    Timeout,
    TooManyNaks,
};

const X_STX: u8 = 0x02;
const X_ACK: u8 = 0x06;
const X_NAK: u8 = 0x15;
const X_EOF: u8 = 0x04;

const XmodemChunk = extern struct {
    start: u8 = 0,
    block: u8 = 0,
    block_neg: u8 = 0,
    payload: [1024]u8 = undefined,
    crc: u16 align(1) = 0,
};

pub fn xmodem_send(fd: os.fd_t, filename: []const u8) !void {
    var file = try std.fs.openFileAbsolute(filename, .{});
    defer file.close();

    const stat = try file.stat();
    var buf = try os.mmap(null, stat.size, os.PROT.READ, os.MAP.PRIVATE, file.handle, 0);
    defer os.munmap(buf);

    std.debug.print("waiting for receiver ping\n", .{});

    const epoll_fd = try os.epoll_create1(0);
    defer os.close(epoll_fd);

    var read_ready_event = os.linux.epoll_event{
        .data = .{ .fd = fd },
        .events = os.linux.EPOLL.IN,
    };
    try os.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, fd, &read_ready_event);

    var num_timeouts: u8 = 0;

    while (true) {
        var events = [_]os.linux.epoll_event{undefined};
        const n_events = os.epoll_wait(epoll_fd, &events, 10 * std.time.ms_per_s);
        if (n_events == 0) {
            // timeout
            if (num_timeouts + 1 >= 10) {
                return Error.Timeout;
            }
            num_timeouts += 1;
            continue;
        } else if (n_events != 1) {
            return Error.InvalidReceiveLength;
        }

        var ping = [_]u8{0};
        const n = try os.read(fd, &ping);
        if (n != ping.len) {
            return Error.InvalidReceiveLength;
        }

        if (ping[0] == 'C') {
            break;
        }
    }

    std.debug.print("sending {s}", .{filename});

    var chunk: XmodemChunk = .{
        .block = 1,
        .start = X_STX,
    };

    var len = stat.size;
    var buf_index: usize = 0;

    var num_errors: u8 = 0;

    while (len > 0 and num_errors < 10) {
        var chunk_len: usize = 0;

        chunk_len = std.mem.min(usize, &.{ len, chunk.payload.len });
        std.mem.copyForwards(u8, &chunk.payload, buf[buf_index .. buf_index + chunk_len]);
        @memset(chunk.payload[chunk_len..], 0xff);

        chunk.crc = std.mem.nativeToBig(u16, Crc16Xmodem.hash(&chunk.payload));
        chunk.block_neg = 0xff - chunk.block;

        const bytes = std.mem.asBytes(&chunk);
        const n = try os.write(fd, bytes);
        if (n != bytes.len) {
            return Error.InvalidSendLength;
        }

        const answer = b: while (true) {
            var answer_buf = [_]u8{0};
            const answer_n_read = try os.read(fd, &answer_buf);
            if (answer_n_read != answer_buf.len) {
                return Error.InvalidReceiveLength;
            }

            // consume remaining initial pings
            if (answer_buf[0] == 'C') {
                continue;
            }
            break :b answer_buf[0];
        };

        const status_char: []const u8 = b: {
            switch (answer) {
                X_ACK => {
                    chunk.block +%= 1;
                    len -= chunk_len;
                    buf_index += chunk_len;
                    break :b ".";
                },
                X_NAK => {
                    num_errors += 1;
                    break :b "N";
                },
                else => {
                    num_errors += 1;
                    break :b "?";
                },
            }
        };

        std.debug.print("{s}", .{status_char});
    }

    if (try os.write(fd, &.{X_EOF}) != 1) {
        return Error.InvalidSendLength;
    }

    var answer_buf = [_]u8{0};
    if (try os.read(fd, &answer_buf) != 1) {
        return Error.InvalidReceiveLength;
    }

    if (answer_buf[0] == X_ACK) {
        std.debug.print("done\n", .{});
        return;
    }

    std.debug.print("\ntoo many errors encountered, sending aborted\n", .{});
}

pub fn xmodem_recv(
    allocator: std.mem.Allocator,
    fd: os.fd_t,
) ![]u8 {
    const epoll_fd = try os.epoll_create1(0);
    defer os.close(epoll_fd);

    // We create a oneshot epoll event since VTIME does not return if the
    // receiver has yet to receive any bytes. So we use epoll to wait for our
    // first bytes, then we use VTIME.
    var read_ready_event = os.linux.epoll_event{
        .data = .{ .fd = fd },
        .events = os.linux.EPOLL.IN | os.linux.EPOLL.ONESHOT,
    };
    try os.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, fd, &read_ready_event);

    var started = false;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var have_bytes = false;
    var ms_without_bytes: u32 = 0;

    outer: while (true) {
        const ping_n = try os.write(fd, &.{'C'});
        if (ping_n != 1) {
            return Error.InvalidSendLength;
        }

        var block_index: u8 = 1;
        var num_errors: u8 = 0;

        var unused_buf_len: usize = 0;
        var unused_buf: [@sizeOf(XmodemChunk)]u8 = undefined;

        while (num_errors < 10) {
            if (!have_bytes) {
                var events = [_]os.linux.epoll_event{undefined};
                const n_events = os.epoll_wait(epoll_fd, &events, 5 * std.time.ms_per_s);
                if (n_events == 0) {
                    if (ms_without_bytes * std.time.ms_per_s > 25) {
                        return Error.Timeout;
                    }
                    ms_without_bytes += 5 + std.time.ms_per_s;
                    continue :outer;
                } else {
                    ms_without_bytes = 0;
                    have_bytes = true;
                }
            }

            var chunk: XmodemChunk = .{};
            var raw_chunk: [@sizeOf(XmodemChunk)]u8 = undefined;

            const chunk_n_read = try os.read(fd, &raw_chunk);

            if (chunk_n_read == 0) {
                ms_without_bytes += 100; // VTIME is 1 tenth of a second
                if (!started and std.time.ms_per_s * ms_without_bytes >= 5) {
                    continue :outer; // resend ping
                }
                continue;
            } else {
                ms_without_bytes = 0;
            }

            if (unused_buf_len + chunk_n_read >= @sizeOf(XmodemChunk)) {
                const len_for_unused = @sizeOf(XmodemChunk) - unused_buf_len;
                std.mem.copyForwards(u8, unused_buf[unused_buf_len..], raw_chunk[0..len_for_unused]);
                @memcpy(std.mem.asBytes(&chunk), &unused_buf);
                std.mem.copyForwards(u8, &unused_buf, raw_chunk[len_for_unused..]);
                unused_buf_len = chunk_n_read - len_for_unused;

                if (!started and chunk.start != X_STX) {
                    try nak(fd);
                    continue :outer;
                } else {
                    started = true;
                }

                // process chunk
                if (block_index == chunk.block -% 1) {
                    // The sender did not increment the block number,
                    // possibly indicating that they did not receive our
                    // prior ack. Resend an ack in the hopes that they will
                    // increment the block number they send.
                    try ack(fd);
                    continue;
                } else if (block_index != chunk.block) {
                    num_errors += 1;
                    try nak(fd);
                    continue;
                }

                block_index +%= 1;

                const crc_got = std.mem.nativeToBig(
                    u16,
                    Crc16Xmodem.hash(&chunk.payload),
                );

                if (crc_got != chunk.crc) {
                    num_errors += 1;
                    try nak(fd);
                    continue;
                }

                try buf.appendSlice(&chunk.payload);
                try ack(fd);
            } else {
                @memcpy(unused_buf[unused_buf_len .. unused_buf_len + chunk_n_read], raw_chunk[0..chunk_n_read]);
                unused_buf_len += chunk_n_read;
            }

            if (unused_buf[0] == X_EOF) {
                try ack(fd);
                return try buf.toOwnedSlice();
            }
        }
    }

    return Error.TooManyNaks;
}

fn ack(fd: os.fd_t) !void {
    if (try os.write(fd, &.{X_ACK}) != 1) {
        return Error.InvalidSendLength;
    }
}

fn nak(fd: os.fd_t) !void {
    if (try os.write(fd, &.{X_NAK}) != 1) {
        return Error.InvalidSendLength;
    }
}

fn usage(prog_name: []const u8) noreturn {
    std.debug.print(
        \\{s} <action> <serial-device> <file>
        \\  action:            "send" or "recv"
        \\  serial-device:     path to serial device (e.g. /dev/ttyUSB0)
        \\  file:              filepath to send from or receive into
        \\
        \\To use with sx/rx, use binary transfer with 1K block sizes and CRC16.
        \\For example:
        \\  send: sx -kb /path/to/send_file < /dev/ttyUSB0 > /dev/ttyUSB0
        \\  recv: rx -cb /path/to/recv_file < /dev/ttyUSB0 > /dev/ttyUSB0
        \\
    , .{prog_name});

    std.process.exit(1);
}

pub fn main() !void {
    var args = std.process.args();
    const prog_name = std.fs.path.basename(args.next().?);

    const action = args.next() orelse usage(prog_name);

    var serial = try std.fs.openFileAbsolute(
        args.next() orelse usage(prog_name),
        .{ .mode = .read_write, .lock = .exclusive },
    );
    defer serial.close();

    const filepath = args.next() orelse usage(prog_name);

    try system.setupTty(serial.handle, .file_transfer);

    if (std.mem.eql(u8, action, "send")) {
        try xmodem_send(serial.handle, filepath);
    } else if (std.mem.eql(u8, action, "recv")) {
        var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        defer _ = gpa.deinit();

        const allocator = gpa.allocator();

        var file = try std.fs.createFileAbsolute(filepath, .{});
        defer file.close();

        const file_bytes = try xmodem_recv(allocator, serial.handle);
        defer allocator.free(file_bytes);

        try file.writeAll(file_bytes);

        std.debug.print("saved file {s} ({d} bytes)\n", .{ filepath, file_bytes.len });
    } else {
        usage(prog_name);
    }
}
