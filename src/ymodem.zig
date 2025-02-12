// An implementation of YMODEM-1K
// See https://en.wikipedia.org/wiki/YMODEM#1k and http://wiki.synchro.net/ref:ymodem#figure_4ymodem_batch_transmission_session-1k_blocks

const std = @import("std");
const posix = std.posix;
const Crc16Xmodem = std.hash.crc.Crc16Xmodem;
const Progress = std.Progress;

const system = @import("./system.zig");

const clap = @import("clap");

const SOH = 0x01;
const STX = 0x02;
const EOF = 0x04;
const ACK = 0x06;
const NAK = 0x15;
const PAD = 0x1a;
const CRC = 0x43;

fn Chunk(comptime size: usize) type {
    return struct {
        start: u8 = 0,
        block: u8 = 0,
        block_neg: u8 = 0,
        payload: [size]u8 = undefined,
        crc: u16 align(1) = 0,
    };
}

const Chunk128 = Chunk(128);
const Chunk1K = Chunk(1024);

fn finalizeAndWriteChunk(comptime chunk_type: type, chunk: *chunk_type, tty: *system.Tty) !void {
    chunk.crc = std.mem.nativeToBig(u16, Crc16Xmodem.hash(&chunk.payload));
    chunk.block_neg = 0xff - chunk.block;

    var naks: u8 = 0;
    while (naks < 10) : (naks += 1) {
        try tty.writer().writeAll(std.mem.asBytes(chunk));

        switch (try tty.reader().readByte()) {
            NAK => continue,
            ACK => return,
            else => return error.IllegalByte,
        }
    }

    return error.TooManyNaks;
}

pub fn send(
    parent_node: *Progress.Node,
    tty: *system.Tty,
    opts: ?struct {
        filename: []const u8,
        file: std.fs.File,
    },
) !void {
    var reader = tty.reader();

    std.log.debug("waiting for receiver ping", .{});

    while (true) {
        if (try reader.readByte() == CRC) {
            break;
        } else {
            return error.IllegalByte;
        }
    }

    if (opts == null) {
        var chunk: Chunk128 = .{
            .block = 0,
            .start = SOH,
            .payload = [_]u8{0x0} ** 128,
        };

        try finalizeAndWriteChunk(Chunk128, &chunk, tty);

        return;
    }

    std.debug.assert(opts != null);
    const file = opts.?.file;
    const filename = opts.?.filename;

    const stat = try file.stat();

    var file_node = parent_node.start(filename, stat.size / 1024);
    defer file_node.end();

    var buf: []align(std.heap.page_size_min) u8 = if (stat.size > 0)
        try posix.mmap(
            null,
            stat.size,
            posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        )
    else
        &.{};

    defer {
        if (stat.size > 0) {
            defer posix.munmap(buf);
        }
    }

    {
        var payload = [_]u8{PAD} ** 128;
        _ = try std.fmt.bufPrint(
            &payload,
            "{s}{c}{d}{c}",
            .{ filename, 0x0, stat.size, 0x20 },
        );
        var chunk: Chunk128 = .{
            .block = 0,
            .start = SOH,
            .payload = payload,
        };

        try finalizeAndWriteChunk(Chunk128, &chunk, tty);

        if (try reader.readByte() != CRC) {
            return error.IllegalByte;
        }
    }

    var unsent_bytes = stat.size;
    var buf_index: usize = 0;

    var chunk = Chunk1K{ .start = STX };

    while (unsent_bytes > 0) {
        var chunk_len: usize = 0;

        chunk_len = std.mem.min(usize, &.{ unsent_bytes, chunk.payload.len });
        std.mem.copyForwards(u8, &chunk.payload, buf[buf_index .. buf_index + chunk_len]);
        @memset(chunk.payload[chunk_len..], PAD);

        chunk.block +%= 1;

        try finalizeAndWriteChunk(Chunk1K, &chunk, tty);

        unsent_bytes -= chunk_len;
        buf_index += chunk_len;

        file_node.completeOne();
    }

    try tty.writer().writeByte(EOF);

    if (try reader.readByte() != ACK) {
        return error.IllegalByte;
    }
}

const RecvState = enum { filename, data };

fn processBlock(comptime chunk_type: type, chunk: *const chunk_type, block_index: *u8) !void {
    if (block_index.* != chunk.block) {
        return error.InvalidBlockIndex;
    } else {
        block_index.* +%= 1;
    }
}

fn crcPasses(comptime chunk_type: type, chunk: *const chunk_type) bool {
    const crc_got = std.mem.nativeToBig(
        u16,
        Crc16Xmodem.hash(&chunk.payload),
    );

    return crc_got == chunk.crc;
}

pub fn recv(tty: *system.Tty, dir: std.fs.Dir) !void {
    var tty_buffered_reader = std.io.bufferedReader(tty.reader());
    var reader = tty_buffered_reader.reader();

    var state: RecvState = .filename;

    var filesize: usize = 0;
    var bytes_written: usize = 0;

    var out_file: ?std.fs.File = null;
    defer {
        if (out_file) |file| {
            file.close();
        }
    }

    std.log.debug("starting transfer", .{});

    var started = false;
    var block_index: u8 = 0;
    var num_errors: u8 = 0;
    var num_timeouts: u8 = 0;

    while (num_errors < 10) {
        if (!started) {
            try tty.writer().writeByte(CRC);
        }

        const start = reader.readByte() catch |err| {
            if (err == error.Timeout and !started) {
                std.log.debug("start transfer timeout, initiating transfer again", .{});
                num_timeouts += 1;
                if (num_timeouts >= 5) {
                    return err;
                }
                continue;
            } else {
                return err;
            }
        };

        started = true;

        switch (start) {
            SOH => {
                const chunk: Chunk128 = b: {
                    var chunk = Chunk128{};
                    var chunk_buf: [@sizeOf(Chunk128)]u8 = undefined;
                    chunk_buf[0] = start;
                    const n_read = try reader.readAll(chunk_buf[1..]);
                    std.debug.assert(n_read + 1 == @sizeOf(Chunk128));
                    @memcpy(std.mem.asBytes(&chunk), &chunk_buf);
                    break :b chunk;
                };

                if (state == .filename and chunk.block > 0) {
                    return error.InvalidState;
                }

                if (state == .data and chunk.block == 0) {
                    return error.InvalidState;
                }

                processBlock(Chunk128, &chunk, &block_index) catch {
                    num_errors += 1;
                    try nak(tty.writer());
                    continue;
                };

                if (!crcPasses(Chunk128, &chunk)) {
                    std.log.err("invalid crc", .{});
                    num_errors += 1;
                    try nak(tty.writer());
                    continue;
                }

                switch (state) {
                    .filename => {
                        if (chunk.payload[0] == 0x0) {
                            // If there is no filename, then we are done.
                            try ack(tty.writer());
                            return;
                        }

                        var filename_buf: [std.fs.MAX_NAME_BYTES]u8 = undefined;

                        var payload_index: usize = 0;
                        for (chunk.payload[payload_index..], 0..) |byte, i| {
                            payload_index += 1;

                            if (byte == 0x0) {
                                break;
                            }

                            filename_buf[i] = byte;
                        }

                        const filename = filename_buf[0 .. payload_index - 1];

                        // Number of digits in base-10 needed for maximum file
                        // size of 4GiB, which is likely much larger than
                        // any file that would be transferred over the ymodem
                        // protocol.
                        const max_digits = comptime @ceil(
                            @log10(@as(f32, 4 * 1024 * 1024 * 1024)),
                        );

                        var filesize_buf: [max_digits]u8 = undefined;
                        for (chunk.payload[payload_index..], 0..) |byte, i| {
                            payload_index += 1;

                            if (byte == ' ') {
                                break;
                            }

                            filesize_buf[i] = byte;
                        }

                        const filesize_str = filesize_buf[0 .. payload_index - filename.len - 2];

                        try ack(tty.writer());
                        try tty.writer().writeByte(CRC);

                        state = .data;

                        filesize = try std.fmt.parseInt(usize, filesize_str, 10);

                        out_file = try dir.createFile(std.fs.path.basename(filename), .{});
                        std.log.info("fetching {} to '{s}'", .{ std.fmt.fmtIntSizeBin(filesize), filename });
                    },
                    .data => {
                        std.debug.assert(filesize > bytes_written);
                        const bytes_to_write = @min(filesize - bytes_written, chunk.payload.len);
                        var file = out_file orelse return error.MissingFile;
                        try file.writer().writeAll(chunk.payload[0..bytes_to_write]);
                        bytes_written += bytes_to_write;
                        try ack(tty.writer());
                    },
                }
            },
            STX => {
                if (state != .data) {
                    return error.InvalidState;
                }

                const chunk: Chunk1K = b: {
                    var chunk = Chunk1K{};
                    var chunk_buf: [@sizeOf(Chunk1K)]u8 = undefined;
                    chunk_buf[0] = start;
                    const n_read = try reader.readAll(chunk_buf[1..]);
                    std.debug.assert(n_read + 1 == @sizeOf(Chunk1K));
                    @memcpy(std.mem.asBytes(&chunk), &chunk_buf);
                    break :b chunk;
                };

                processBlock(Chunk1K, &chunk, &block_index) catch {
                    num_errors += 1;
                    try nak(tty.writer());
                    continue;
                };

                if (!crcPasses(Chunk1K, &chunk)) {
                    std.log.err("invalid crc", .{});
                    num_errors += 1;
                    try nak(tty.writer());
                    continue;
                }

                std.debug.assert(filesize > bytes_written);
                const bytes_to_write = @min(filesize - bytes_written, chunk.payload.len);
                var file = out_file orelse return error.MissingFile;
                try file.writer().writeAll(chunk.payload[0..bytes_to_write]);
                bytes_written += bytes_to_write;
                try ack(tty.writer());
            },
            EOF => {
                if (bytes_written != filesize) {
                    return error.InvalidFilesize;
                }

                try ack(tty.writer());

                return recv(tty, dir);
            },
            else => {
                std.log.err("unknown header start: 0x{x}", .{start});
                return error.IllegalByte;
            },
        }
    }

    return error.TooManyNaks;
}

fn ack(writer: system.Tty.Writer) !void {
    try writer.writeByte(ACK);
}

fn nak(writer: system.Tty.Writer) !void {
    try writer.writeByte(NAK);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\-t, --tty       <FILE>     TTY to send/receive on.
        \\-d, --directory <DIR>      Directory to send/receive files from/to.
        \\<ACTION>                   Action to take ("send" or "recv").
        \\
    );

    const Action = enum {
        send,
        recv,
    };

    const parsers = comptime .{
        .FILE = clap.parsers.string,
        .DIR = clap.parsers.string,
        .ACTION = clap.parsers.enumeration(Action),
    };

    const stderr = std.io.getStdErr().writer();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, &parsers, .{
        .diagnostic = &diag,
        .allocator = arena.allocator(),
    }) catch |err| {
        try diag.report(stderr, err);
        try clap.usage(stderr, clap.Help, &params);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }

    if (res.positionals[0] == null or res.args.directory == null or res.args.tty == null) {
        try diag.report(stderr, error.InvalidArgument);
        try clap.usage(std.io.getStdErr().writer(), clap.Help, &params);
        return;
    }

    var tty_file = try std.fs.cwd().openFile(
        res.args.tty.?,
        .{ .mode = .read_write, .lock = .none },
    );
    defer tty_file.close();

    var tty = try system.setupTty(tty_file.handle, .file_transfer);
    defer tty.reset();

    var dir = try std.fs.cwd().openDir(res.args.directory.?, .{});
    defer dir.close();

    const action = res.positionals[0].?;

    switch (action) {
        .send => {
            var progress = Progress.start(.{ .root_name = "ymodem" });
            defer progress.end();

            const files_to_send = [_][]const u8{ "linux", "initrd", "params" };
            for (files_to_send) |filename| {
                var file = dir.openFile(filename, .{}) catch |err| {
                    if (err == error.FileNotFound and std.mem.eql(u8, filename, "initrd")) {
                        continue;
                    } else {
                        return err;
                    }
                };
                defer file.close();

                std.log.debug("sending file '{s}'", .{filename});

                try send(
                    &progress,
                    &tty,
                    .{
                        .filename = filename,
                        .file = file,
                    },
                );
            }

            try send(&progress, &tty, null);
        },
        .recv => {
            try recv(&tty, dir);
        },
    }
}
