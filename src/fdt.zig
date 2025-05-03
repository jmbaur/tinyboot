// Implemented from documentation found at https://devicetree-specification.readthedocs.io/en/stable/flattened-format.html#flattened-devicetree-dtb-format

const std = @import("std");

const Fdt = @This();

const magic = 0xd00dfeed;
const compatible_version = 17;

const Header = extern struct {
    magic: u32,
    total_size: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

stream: *std.io.StreamSource,
header: Header,

fn init(stream: *std.io.StreamSource) !@This() {
    const header = try stream.reader().readStructEndian(Header, .big);

    if (header.magic != magic) {
        return error.InvalidMagic;
    }

    if (header.version < compatible_version) {
        return error.IncompatibleVersion;
    }

    return .{ .stream = stream, .header = header };
}

fn nextToken(self: *@This()) !Token {
    const token_value = try self.stream.reader().readVarInt(u32, .big, @sizeOf(u32));

    return try Token.parse(token_value);
}

fn findProperty(self: *@This(), path: []const []const u8) !Prop {
    try self.stream.seekTo(self.header.off_dt_struct);

    for (path, 0..) |path_entry, i| {
        while (true) {
            switch (try self.nextToken()) {
                .Nop => {},
                .BeginNode => {
                    var node_name_buf = [_]u8{0} ** node_prop_name_max_chars;
                    var node_name_stream = std.io.fixedBufferStream(&node_name_buf);
                    try self.stream.reader().streamUntilDelimiter(node_name_stream.writer(), 0, null);
                    const node_name = node_name_stream.getWritten();

                    try self.alignStream();

                    if (std.mem.eql(u8, node_name, path_entry)) {
                        return self.findProperty(path[i + 1 ..]);
                    }
                },
                .Prop => {
                    const at_end_of_path = path.len - 1 == i;
                    if (!at_end_of_path) {
                        continue;
                    }

                    const prop = try self.stream.reader().readStructEndian(Prop, .big);
                    var buf = [_]u8{0} ** node_prop_name_max_chars;
                    const prop_name = try self.getPropertyName(prop.name_offset, &buf);

                    if (std.mem.eql(u8, path_entry, prop_name)) {
                        return prop;
                    } else {
                        try self.stream.reader().skipBytes(prop.len, .{});
                        try self.alignStream();
                    }
                },
                .EndNode => {},
                .End => return error.PropertyNotFound,
            }
        }
    }

    return error.PropertyNotFound;
}

fn alignStream(self: *@This()) !void {
    const pos = try self.stream.getPos();
    const off_alignment = pos % 4;
    if (off_alignment != 0) {
        try self.stream.reader().skipBytes(4 - off_alignment, .{});
    }
}

fn getPropertyName(self: *@This(), offset: u32, buf: []u8) ![]const u8 {
    const orig_pos = try self.stream.getPos();
    defer {
        self.stream.seekTo(orig_pos) catch {
            // this is unfortunate
        };
    }
    try self.stream.seekTo(self.header.off_dt_strings + offset);
    var buf_stream = std.io.fixedBufferStream(buf);
    try self.stream.reader().streamUntilDelimiter(buf_stream.writer(), 0, null);
    return buf_stream.getWritten();
}

// TODO(jared): Make this nicer.
/// Returns the path that the phandle points to.
pub fn getPhandleProperty(
    self: *@This(),
    path: []const []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    return self.getStringProperty(path, allocator);
}

pub fn getStringProperty(
    self: *@This(),
    path: []const []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const prop = try self.findProperty(path);

    if (prop.len == 0) {
        return error.InvalidPropertyType;
    }

    const len_without_null_byte = prop.len - 1;
    const buf = try allocator.alloc(u8, len_without_null_byte);
    errdefer allocator.free(buf);

    const bytes_read = try self.stream.reader().readAtLeast(buf, len_without_null_byte);
    if (bytes_read != len_without_null_byte) {
        return error.IncompleteRead;
    }

    return buf;
}

// TODO(jared): It would be nice if we were able to "flatten" all the methods
// of SplitIterator into our StringList type.
const StringList = struct {
    split: std.mem.SplitIterator(u8, .scalar),
    allocator: std.mem.Allocator,

    fn deinit(self: *@This()) void {
        self.allocator.free(self.split.buffer);
    }

    fn first(self: *@This()) []const u8 {
        return self.split.first();
    }

    fn next(self: *@This()) ?[]const u8 {
        return self.split.next();
    }

    fn peek(self: *@This()) ?[]const u8 {
        return self.split.peek();
    }

    fn rest(self: *@This()) []const u8 {
        return self.split.rest();
    }

    fn reset(self: *@This()) void {
        self.split.reset();
    }
};

pub fn getStringListProperty(
    self: *@This(),
    path: []const []const u8,
    allocator: std.mem.Allocator,
) !StringList {
    const prop = try self.findProperty(path);

    if (prop.len == 0) {
        return error.InvalidPropertyType;
    }

    const len_without_null_byte = prop.len - 1;
    const buf = try allocator.alloc(u8, len_without_null_byte);
    errdefer allocator.free(buf);

    const bytes_read = try self.stream.reader().readAtLeast(buf, len_without_null_byte);
    if (bytes_read != len_without_null_byte) {
        return error.IncompleteRead;
    }

    return .{
        .allocator = allocator,
        .split = std.mem.splitScalar(u8, buf, 0),
    };
}

pub fn getBoolProperty(
    self: *@This(),
    path: []const []const u8,
) bool {
    const prop = self.findProperty(path) catch return false;

    return prop.len == 0;
}

pub fn getU32Property(self: *@This(), path: []const []const u8) !u32 {
    const prop = try self.findProperty(path);

    if (prop.len != @sizeOf(u32)) {
        return error.InvalidPropertyType;
    }

    return try self.stream.reader().readInt(u32, .big);
}

pub fn getU64Property(self: *@This(), path: []const []const u8) !u64 {
    const prop = try self.findProperty(path);

    if (prop.len != @sizeOf(u64)) {
        return error.InvalidPropertyType;
    }

    const left = try self.stream.reader().readInt(u32, .big);
    const right = try self.stream.reader().readInt(u32, .big);

    return (@as(u64, left) << 32) | @as(u64, right);
}

const node_prop_name_max_chars = 31;

const Prop = extern struct {
    len: u32,
    name_offset: u32,
};

const Token = enum(u32) {
    BeginNode = 0x1,
    EndNode = 0x2,
    Prop = 0x3,
    Nop = 0x4,
    End = 0x9,

    fn parse(value: u32) !@This() {
        switch (value) {
            0x1 => return .BeginNode,
            0x2 => return .EndNode,
            0x3 => return .Prop,
            0x4 => return .Nop,
            0x9 => return .End,
            else => return error.InvalidToken,
        }
    }
};

// /dts-v1/;
//
// / {
//   testlabel: chosen {
//     this_is_a_bool;
//     this_is_a_u32 = <0x11223344>;
//     this_is_a_u64 = <0x11223344 0x55667788>;
//     this_is_a_phandle = &testlabel;
//     this_is_a_string = "foo bar baz";
//     this_is_a_stringlist = "foo", "bar", "baz";
//   };
// };
const test_fdt = [_]u8{
    0xd0, 0x0d, 0xfe, 0xed, 0x00, 0x00, 0x01, 0x2f, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00, 0xcc,
    0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x63, 0x00, 0x00, 0x00, 0x94, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x63, 0x68, 0x6f, 0x73, 0x65, 0x6e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04,
    0x00, 0x00, 0x00, 0x0f, 0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x08,
    0x00, 0x00, 0x00, 0x1d, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x00, 0x00, 0x00, 0x03,
    0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x2b, 0x2f, 0x63, 0x68, 0x6f, 0x73, 0x65, 0x6e, 0x00,
    0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x3d, 0x66, 0x6f, 0x6f, 0x20,
    0x62, 0x61, 0x72, 0x20, 0x62, 0x61, 0x7a, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x0c,
    0x00, 0x00, 0x00, 0x4e, 0x66, 0x6f, 0x6f, 0x00, 0x62, 0x61, 0x72, 0x00, 0x62, 0x61, 0x7a, 0x00,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x09, 0x74, 0x68, 0x69, 0x73,
    0x5f, 0x69, 0x73, 0x5f, 0x61, 0x5f, 0x62, 0x6f, 0x6f, 0x6c, 0x00, 0x74, 0x68, 0x69, 0x73, 0x5f,
    0x69, 0x73, 0x5f, 0x61, 0x5f, 0x75, 0x33, 0x32, 0x00, 0x74, 0x68, 0x69, 0x73, 0x5f, 0x69, 0x73,
    0x5f, 0x61, 0x5f, 0x75, 0x36, 0x34, 0x00, 0x74, 0x68, 0x69, 0x73, 0x5f, 0x69, 0x73, 0x5f, 0x61,
    0x5f, 0x70, 0x68, 0x61, 0x6e, 0x64, 0x6c, 0x65, 0x00, 0x74, 0x68, 0x69, 0x73, 0x5f, 0x69, 0x73,
    0x5f, 0x61, 0x5f, 0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x00, 0x74, 0x68, 0x69, 0x73, 0x5f, 0x69,
    0x73, 0x5f, 0x61, 0x5f, 0x73, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x6c, 0x69, 0x73, 0x74, 0x00,
};

test "fdt parse" {
    var stream = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(&test_fdt) };

    var fdt = try Fdt.init(&stream);

    try std.testing.expectError(error.PropertyNotFound, fdt.getStringProperty(
        &.{ "chosen", "not_present" },
        std.testing.allocator,
    ));

    const this_is_a_phandle = try fdt.getPhandleProperty(
        &.{ "chosen", "this_is_a_phandle" },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(this_is_a_phandle);
    try std.testing.expectEqualStrings("/chosen", this_is_a_phandle);

    const this_is_a_string = try fdt.getStringProperty(
        &.{ "chosen", "this_is_a_string" },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(this_is_a_string);
    try std.testing.expectEqualStrings("foo bar baz", this_is_a_string);

    var this_is_a_stringlist = try fdt.getStringListProperty(
        &.{ "chosen", "this_is_a_stringlist" },
        std.testing.allocator,
    );
    defer this_is_a_stringlist.deinit();
    try std.testing.expectEqualStrings("foo", this_is_a_stringlist.next() orelse unreachable);
    try std.testing.expectEqualStrings("bar", this_is_a_stringlist.next() orelse unreachable);
    try std.testing.expectEqualStrings("baz", this_is_a_stringlist.next() orelse unreachable);
    try std.testing.expectEqual(null, this_is_a_stringlist.next());

    const this_is_a_bool = fdt.getBoolProperty(&.{ "chosen", "this_is_a_bool" });
    try std.testing.expect(this_is_a_bool);

    const this_is_not_a_bool = fdt.getBoolProperty(&.{ "chosen", "this_is_not_a_bool" });
    try std.testing.expect(!this_is_not_a_bool);

    const this_is_a_u32 = try fdt.getU32Property(&.{ "chosen", "this_is_a_u32" });
    try std.testing.expectEqual(0x11223344, this_is_a_u32);

    const this_is_a_u64 = try fdt.getU64Property(&.{ "chosen", "this_is_a_u64" });
    try std.testing.expectEqual(0x1122334455667788, this_is_a_u64);
}
