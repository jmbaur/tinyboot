const std = @import("std");
const base64 = std.base64.standard;

const clap = @import("clap");

const VPD_TYPE_TERMINATOR = 0x00;
const VPD_TYPE_STRING = 0x01;
const VPD_TYPE_INFO = 0xFE;
const VPD_TYPE_IMPLICIT_TERMINATOR = 0xFF;

const GOOGLE_VPD_2_0_OFFSET = 0x600;
const GOOGLE_VPD_2_0_UUID = "0a7c23d3-8a27-4252-99bf-7868a2e26b61";
const GOOGLE_VPD_2_0_VENDOR = "Google";
const GOOGLE_VPD_2_0_DESCRIPTION = "Google VPD 2.0";
const GOOGLE_VPD_2_0_VARIANT = "";

const ENTRY_MAGIC = "_SM_";
const INFO_MAGIC: [12]u8 = .{
    0xfe, // type: VPD header
    0x09, // key length 9 = 1 + 8
    0x01, // info version, 1
    'g',
    'V',
    'p',
    'd',
    'I',
    'n',
    'f',
    'o',
    0x04, // value length
};

/// Google specific VPD info
const GoogleVpdInfo = extern struct {
    header: extern union {
        tlv: extern struct {
            type: u8,
            key_len: u8,
            info_ver: u8,
            signature: [8]u8,
            value_len: u8,
        },
        magic: [12]u8,
    },
    size: u32,
};

const VpdList = std.ArrayList(struct { []const u8, []const u8 });

fn writeVpd(vpd_list: VpdList, file: std.fs.File) !void {
    const stat = try file.stat();

    try file.seekTo(GOOGLE_VPD_2_0_OFFSET + @sizeOf(GoogleVpdInfo));

    var writer = file.writer();

    for (vpd_list.items) |vpd_item| {
        const key, const value = vpd_item;

        std.log.debug("writing {s}({})={s}({})", .{ key, key.len, value, value.len });

        try writer.writeByte(VPD_TYPE_STRING);
        var vpd_len_buf = [_]u8{0} ** 64;
        const key_len_bytes = vpdValueLength(key.len, &vpd_len_buf);
        try writer.writeAll(key_len_bytes);
        try writer.writeAll(key);
        const value_len_bytes = vpdValueLength(value.len, &vpd_len_buf);
        try writer.writeAll(value_len_bytes);
        try writer.writeAll(value);
    }

    try writer.writeByte(VPD_TYPE_TERMINATOR);

    const pos = try file.getPos();
    try writer.writeByteNTimes(0xff, stat.size - pos);

    try file.seekTo(GOOGLE_VPD_2_0_OFFSET);
    const vpd_info: GoogleVpdInfo = .{
        .header = .{ .magic = INFO_MAGIC },
        .size = std.mem.nativeToLittle(
            u32,
            @intCast(pos - GOOGLE_VPD_2_0_OFFSET - @sizeOf(GoogleVpdInfo)),
        ),
    };
    try writer.writeAll(std.mem.asBytes(&vpd_info));
}

fn vpdValueLength(size: usize, buf: []u8) []u8 {
    var working_size = std.mem.nativeToLittle(@TypeOf(size), size);

    var index: usize = 0;

    while (true) : (index +|= 1) {
        const bottom: u8 = @intCast(working_size & 0x7f);

        buf[index] = bottom;

        working_size = working_size >> 7;

        if (working_size <= 0) {
            break;
        }
    }

    std.mem.reverse(u8, buf[0 .. index + 1]);

    for (buf, 0..) |*item, i| {
        if (i == index) {
            break;
        }

        // set the more bit
        item.* = item.* | 0x80;
    }

    return buf[0 .. index + 1];
}

test "calculate vpd value length" {
    var buf = [_]u8{0} ** 64;

    try std.testing.expectEqualSlices(u8, &.{0b0000001}, vpdValueLength(1, &buf));

    try std.testing.expectEqualSlices(u8, &.{0b1111111}, vpdValueLength(127, &buf));

    try std.testing.expectEqualSlices(u8, &.{
        0b10000001,
        0b00000000,
    }, vpdValueLength(128, &buf));

    // Example from https://chromium.googlesource.com/chromiumos/platform/vpd
    try std.testing.expectEqualSlices(u8, &.{
        0b10000100,
        0b10000010,
        0b00000001,
    }, vpdValueLength(65793, &buf));
}

fn collectVpd(allocator: std.mem.Allocator, file: std.fs.File) !VpdList {
    var vpd_list = VpdList.init(allocator);
    errdefer vpd_list.deinit();

    try file.seekTo(GOOGLE_VPD_2_0_OFFSET);

    var reader = file.reader();

    const total_size = b: {
        var vpd_info_buf: [@sizeOf(GoogleVpdInfo)]u8 = undefined;
        if (try reader.readAll(&vpd_info_buf) != @sizeOf(GoogleVpdInfo)) {
            return error.InvalidHeaderSize;
        }

        const aligned_buf = @as([]align(@alignOf(GoogleVpdInfo)) u8, @alignCast(&vpd_info_buf));
        const header: *GoogleVpdInfo = @ptrCast(aligned_buf);
        if (!std.mem.eql(u8, header.header.magic[0..INFO_MAGIC.len], INFO_MAGIC[0..])) {
            return error.InvalidMagic;
        }

        break :b std.mem.littleToNative(@TypeOf(header.size), header.size);
    };

    _ = total_size;

    while (true) {
        const @"type" = try reader.readByte();
        if (@"type" == VPD_TYPE_TERMINATOR or @"type" == VPD_TYPE_IMPLICIT_TERMINATOR) {
            break;
        }

        const key_length = try readLength(reader);

        var key = try allocator.alloc(u8, key_length);
        errdefer allocator.free(key);
        if (try reader.readAll(key[0..]) != key.len) {
            return error.InvalidReadLength;
        }

        const value_length = try readLength(reader);

        var value = try allocator.alloc(u8, value_length);
        errdefer allocator.free(value);
        if (try reader.readAll(value[0..]) != value.len) {
            return error.InvalidReadLength;
        }

        try vpd_list.append(.{ key, value });
    }

    return vpd_list;
}

fn readLength(reader: std.fs.File.Reader) !u64 {
    var total: u64 = 0;

    while (true) {
        const byte = try reader.readByte();

        const more = byte & 0x80 == 0x80;
        const val = byte & 0x7f;

        total = total << 7;
        total +|= val;

        if (!more) {
            break;
        }
    }

    return std.mem.littleToNative(@TypeOf(total), total);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                     Display this help and exit.
        \\-f, --file <FILE>              File to operate on.
        \\-k, --key <str>                Key to get, set, or delete.
        \\-v, --value <str>              Value to set.
        \\-V, --value-from-file <str>    Value to set from file (written value will be base64-encoded).
        \\<ACTION>                       list, get, set, or delete
        \\
    );

    const Action = enum {
        list,
        get,
        set,
        delete,
    };

    const parsers = comptime .{
        .str = clap.parsers.string,
        .FILE = clap.parsers.string,
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

    if (res.positionals.len != 1 or res.args.file == null) {
        try diag.report(stderr, error.InvalidArgument);
        try clap.usage(std.io.getStdErr().writer(), clap.Help, &params);
        return;
    }

    const action = res.positionals[0];
    switch (action) {
        .get, .set, .delete => {
            if (res.args.key == null or (action == .set and res.args.value == null and res.args.@"value-from-file" == null)) {
                try diag.report(stderr, error.InvalidArgument);
                try clap.usage(std.io.getStdErr().writer(), clap.Help, &params);
                return;
            }
        },
        else => {},
    }

    var file = try std.fs.cwd().openFile(res.args.file.?, .{
        .mode = switch (action) {
            .list, .get => .read_only,
            .set, .delete => .read_write,
        },
    });
    defer file.close();

    var vpd_list = try collectVpd(arena.allocator(), file);
    defer vpd_list.deinit();

    switch (action) {
        .list => {
            for (vpd_list.items) |vpd_item| {
                const key, const value = vpd_item;
                std.debug.print("{s}={s}\n", .{ key, value });
            }
        },
        .get => {
            for (vpd_list.items) |vpd_item| {
                const key, const value = vpd_item;

                if (std.mem.eql(u8, key, res.args.key.?)) {
                    std.debug.print("{s}={s}\n", .{ key, value });
                    break;
                }
            }
        },
        .set => {
            const value = if (res.args.value) |value| try arena.allocator().dupe(u8, value) else b: {
                const value_file = res.args.@"value-from-file".?;
                const file_contents = try std.fs.cwd().readFileAlloc(arena.allocator(), value_file, 8192);
                const encoded_size = base64.Encoder.calcSize(file_contents.len);
                var dest = try arena.allocator().alloc(u8, encoded_size);
                break :b base64.Encoder.encode(dest[0..], file_contents);
            };

            o: {
                for (vpd_list.items) |*vpd_item| {
                    const key, _ = vpd_item.*;

                    // Update existing key if there is one
                    if (std.mem.eql(u8, key, res.args.key.?)) {
                        vpd_item.* = .{
                            key,
                            value,
                        };
                        break :o;
                    }
                }

                // Otherwise, we add a new key/value
                try vpd_list.append(.{ res.args.key.?, value });
            }

            try writeVpd(vpd_list, file);
        },
        .delete => {
            const found = b: {
                for (vpd_list.items, 0..) |vpd_item, index| {
                    const key, _ = vpd_item;

                    if (std.mem.eql(u8, key, res.args.key.?)) {
                        _ = vpd_list.orderedRemove(index);
                        break :b true;
                    }
                }

                break :b false;
            };

            if (found) {
                try writeVpd(vpd_list, file);
            } else {
                std.debug.print("key '{s}' not found\n", .{res.args.key.?});
            }
        },
    }
}
