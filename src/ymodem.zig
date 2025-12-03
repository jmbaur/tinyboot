// An implementation of YMODEM-1K
// See https://en.wikipedia.org/wiki/YMODEM#1k and http://wiki.synchro.net/ref:ymodem#figure_4ymodem_batch_transmission_session-1k_blocks

const std = @import("std");
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

fn finalizeAndWriteChunk(comptime chunk_type: type, chunk: *chunk_type, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    chunk.crc = std.mem.nativeToBig(u16, Crc16Xmodem.hash(&chunk.payload));
    chunk.block_neg = 0xff - chunk.block;

    var naks: u8 = 0;
    while (naks < 10) : (naks += 1) {
        try writer.writeAll(std.mem.asBytes(chunk));
        try writer.flush();

        switch (try reader.takeByte()) {
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
        name: []const u8,
        file: std.fs.File,
    },
) !void {
    var reader_buffer: [1024]u8 = undefined;
    var writer_buffer: [1024]u8 = undefined;
    var file_reader = tty.file.reader(&reader_buffer);
    var file_writer = tty.file.writer(&writer_buffer);
    var reader = &file_reader.interface;
    var writer = &file_writer.interface;

    std.log.debug("waiting for receiver ping", .{});

    while (try reader.takeByte() != CRC) {
        // The receiver might send invalid bytes, but this could just be
        // something as innocuous as keyboard input during setup of the ymodem
        // client. We should be forgiving to this input, and continue with
        // sending the file once we receive a valid receiver ping.
        std.log.debug("got invalid receiver ping", .{});
    }

    if (opts == null) {
        var chunk: Chunk128 = .{
            .block = 0,
            .start = SOH,
            .payload = [_]u8{0x0} ** 128,
        };

        try finalizeAndWriteChunk(Chunk128, &chunk, reader, writer);

        return;
    }

    std.debug.assert(opts != null);
    const file = opts.?.file;
    const name = opts.?.name;

    try file.seekTo(0);

    const stat = try file.stat();
    const size: usize = @intCast(stat.size);

    var file_node = parent_node.start(name, size / 1024);
    defer file_node.end();

    {
        var payload = [_]u8{PAD} ** 128;
        _ = try std.fmt.bufPrint(
            &payload,
            "{s}{c}{d}{c}",
            .{ name, 0x0, size, 0x20 },
        );
        var chunk: Chunk128 = .{
            .block = 0,
            .start = SOH,
            .payload = payload,
        };

        try finalizeAndWriteChunk(Chunk128, &chunk, reader, writer);

        if (try reader.takeByte() != CRC) {
            return error.IllegalByte;
        }
    }

    var chunk = Chunk1K{ .start = STX };

    var chunk_buf = [_]u8{0} ** 1024;

    while (true) {
        const bytes_read = try file.readAll(&chunk_buf);
        @memset(chunk_buf[bytes_read..], PAD);
        @memcpy(&chunk.payload, &chunk_buf);

        chunk.block +%= 1;

        try finalizeAndWriteChunk(Chunk1K, &chunk, reader, writer);

        file_node.completeOne();

        // reached end of file
        if (bytes_read < chunk_buf.len) {
            break;
        }
    }

    try writer.writeByte(EOF);
    try writer.flush();

    if (try reader.takeByte() != ACK) {
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
    var reader_buffer: [1024]u8 = undefined;
    var writer_buffer: [1024]u8 = undefined;
    var file_reader = tty.file.reader(&reader_buffer);
    var file_writer = tty.file.writer(&writer_buffer);
    var reader = &file_reader.interface;
    var writer = &file_writer.interface;

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
            try writer.writeByte(CRC);
            try writer.flush();
        }

        const start = reader.takeByte() catch |err| {
            if (err == error.EndOfStream and !started) {
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
                    try reader.readSliceAll(chunk_buf[1..]);
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
                    try nak(writer);
                    continue;
                };

                if (!crcPasses(Chunk128, &chunk)) {
                    std.log.err("invalid crc", .{});
                    num_errors += 1;
                    try nak(writer);
                    continue;
                }

                switch (state) {
                    .filename => {
                        if (chunk.payload[0] == 0x0) {
                            // If there is no filename, then we are done.
                            try ack(writer);
                            return;
                        }

                        var filename_buf: [std.fs.max_name_bytes]u8 = undefined;

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

                        try ack(writer);
                        try writer.writeByte(CRC);
                        try writer.flush();

                        state = .data;

                        filesize = try std.fmt.parseInt(usize, filesize_str, 10);

                        out_file = try dir.createFile(std.fs.path.basename(filename), .{});

                        std.log.info("fetching {Bi:.02} to '{s}'", .{ filesize, filename });
                    },
                    .data => {
                        std.debug.assert(filesize >= bytes_written);
                        const bytes_to_write = @min(filesize - bytes_written, chunk.payload.len);
                        var file = out_file orelse return error.MissingFile;
                        try file.writeAll(chunk.payload[0..bytes_to_write]);
                        bytes_written += bytes_to_write;
                        try ack(writer);
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
                    try reader.readSliceAll(chunk_buf[1..]);
                    @memcpy(std.mem.asBytes(&chunk), &chunk_buf);
                    break :b chunk;
                };

                processBlock(Chunk1K, &chunk, &block_index) catch {
                    num_errors += 1;
                    try nak(writer);
                    continue;
                };

                if (!crcPasses(Chunk1K, &chunk)) {
                    std.log.err("invalid crc", .{});
                    num_errors += 1;
                    try nak(writer);
                    continue;
                }

                std.debug.assert(filesize >= bytes_written);
                const bytes_to_write = @min(filesize - bytes_written, chunk.payload.len);
                var file = out_file orelse return error.MissingFile;
                try file.writeAll(chunk.payload[0..bytes_to_write]);
                bytes_written += bytes_to_write;
                try ack(writer);
            },
            EOF => {
                if (bytes_written != filesize) {
                    return error.InvalidFilesize;
                }

                try ack(writer);

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

inline fn ack(writer: *std.Io.Writer) !void {
    try writer.writeByte(ACK);
    try writer.flush();
}

inline fn nak(writer: *std.Io.Writer) !void {
    try writer.writeByte(NAK);
    try writer.flush();
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

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, &parsers, .{
        .diagnostic = &diag,
        .allocator = arena.allocator(),
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        try clap.usageToFile(.stderr(), clap.Help, &params);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});
    }

    if (res.positionals[0] == null or res.args.directory == null or res.args.tty == null) {
        try diag.reportToFile(.stderr(), error.InvalidArgument);
        try clap.usageToFile(.stderr(), clap.Help, &params);
        return;
    }

    var tty_file = try std.fs.cwd().openFile(
        res.args.tty.?,
        .{ .mode = .read_write, .lock = .none },
    );
    defer tty_file.close();

    var tty: system.Tty = .init(tty_file);
    defer tty.deinit();

    try tty.setMode(.file_transfer);

    var dir = try std.fs.cwd().openDir(
        res.args.directory.?,
        .{ .iterate = true },
    );
    defer dir.close();

    const action = res.positionals[0].?;

    switch (action) {
        .send => {
            var progress = Progress.start(.{ .root_name = "ymodem" });
            defer progress.end();

            var iter = dir.iterate();

            while (try iter.next()) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) {
                    continue;
                }

                const file = try dir.openFile(entry.name, .{});
                defer file.close();

                std.log.debug("sending file '{s}'", .{entry.name});

                try send(&progress, &tty, .{
                    .name = entry.name,
                    .file = file,
                });
            }

            try send(&progress, &tty, null);
        },
        .recv => {
            try recv(&tty, dir);
        },
    }
}
