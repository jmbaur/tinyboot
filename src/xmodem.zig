const std = @import("std");
const os = std.os;
const posix = std.posix;
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

pub fn xmodem_send(fd: posix.fd_t, filename: []const u8) !void {
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    const stat = try file.stat();
    var buf = try posix.mmap(
        null,
        stat.size,
        posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer posix.munmap(buf);

    std.debug.print("waiting for receiver ping\n", .{});

    const epoll_fd = try posix.epoll_create1(linux_headers.EPOLL_CLOEXEC);
    defer posix.close(epoll_fd);

    var read_ready_event = os.linux.epoll_event{
        .data = .{ .fd = fd },
        .events = os.linux.EPOLL.IN,
    };
    try posix.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, fd, &read_ready_event);

    var num_timeouts: u8 = 0;

    while (true) {
        var events: [1]os.linux.epoll_event = undefined;
        const n_events = posix.epoll_wait(epoll_fd, &events, 10 * std.time.ms_per_s);
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
        const n = try posix.read(fd, &ping);
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
        const n = try posix.write(fd, bytes);
        if (n != bytes.len) {
            return Error.InvalidSendLength;
        }

        const answer = b: while (true) {
            var answer_buf = [_]u8{0};
            const answer_n_read = try posix.read(fd, &answer_buf);
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

    if (try posix.write(fd, &.{X_EOF}) != 1) {
        return Error.InvalidSendLength;
    }

    var answer_buf = [_]u8{0};
    if (try posix.read(fd, &answer_buf) != 1) {
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
    fd: posix.fd_t,
) ![]u8 {
    const epoll_fd = try posix.epoll_create1(linux_headers.EPOLL_CLOEXEC);
    defer posix.close(epoll_fd);

    var read_ready_event = os.linux.epoll_event{
        .data = .{ .fd = fd },
        .events = os.linux.EPOLL.IN | os.linux.EPOLL.ONESHOT,
    };
    try posix.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, fd, &read_ready_event);

    var started = false;

    var data_buf = std.ArrayList(u8).init(allocator);
    defer data_buf.deinit();

    var ms_without_bytes: u32 = 0;

    while (true) {
        if (try posix.write(fd, &.{'C'}) != 1) {
            return Error.InvalidSendLength;
        }

        var events: [1]os.linux.epoll_event = undefined;
        const n_events = posix.epoll_wait(epoll_fd, &events, 5 * std.time.ms_per_s);
        if (n_events == 0) {
            if (ms_without_bytes / std.time.ms_per_s > 25) {
                return Error.Timeout;
            }
            ms_without_bytes += 5 * std.time.ms_per_s;
        } else {
            ms_without_bytes = 0;
            break;
        }
    }

    var block_index: u8 = 1;
    var num_errors: u8 = 0;

    var chunk_buf: [@sizeOf(XmodemChunk)]u8 = undefined;
    var chunk_buf_index: usize = 0;

    while (num_errors < 10) {
        var chunk: XmodemChunk = .{};

        const chunk_n_read = try posix.read(fd, chunk_buf[chunk_buf_index..]);
        if (chunk_n_read == 0) {
            if (ms_without_bytes / std.time.ms_per_s > 25) {
                return Error.Timeout;
            }
            // VMIN is equal to 5 seconds
            ms_without_bytes += 5 * std.time.ms_per_s;
            continue;
        } else {
            ms_without_bytes = 0;
        }

        if (chunk_buf_index + chunk_n_read == @sizeOf(XmodemChunk)) {
            @memcpy(std.mem.asBytes(&chunk), &chunk_buf);
            chunk_buf_index = 0;

            if (!started and chunk.start != X_STX) {
                num_errors += 1;
                try nak(fd);
                continue;
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

            try data_buf.appendSlice(&chunk.payload);
            try ack(fd);
        } else {
            chunk_buf_index += chunk_n_read;
        }

        if (chunk_buf[0] == X_EOF) {
            try ack(fd);
            return try data_buf.toOwnedSlice();
        }
    }

    return Error.TooManyNaks;
}

fn ack(fd: posix.fd_t) !void {
    if (try posix.write(fd, &.{X_ACK}) != 1) {
        return Error.InvalidSendLength;
    }
}

fn nak(fd: posix.fd_t) !void {
    if (try posix.write(fd, &.{X_NAK}) != 1) {
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

    var serial = try std.fs.cwd().openFile(
        args.next() orelse usage(prog_name),
        .{ .mode = .read_write, .lock = .exclusive },
    );
    defer serial.close();

    const filepath = args.next() orelse usage(prog_name);

    if (std.mem.eql(u8, action, "send")) {
        try system.setupTty(serial.handle, .file_transfer_send);

        try xmodem_send(serial.handle, filepath);
    } else if (std.mem.eql(u8, action, "recv")) {
        try system.setupTty(serial.handle, .file_transfer_recv);

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
