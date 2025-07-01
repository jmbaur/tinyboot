// Implemented from documentation found at https://devicetree-specification.readthedocs.io/en/stable/flattened-format.html#flattened-devicetree-dtb-format

const std = @import("std");

const Fdt = @This();

const magic = 0xd00dfeed;
const compatible_version = 17;
const node_prop_name_max_chars = 31;

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

const LinkedList = std.DoublyLinkedList(union(Token) {
    BeginNode: []const u8,
    EndNode,
    Prop: struct {
        inner: Prop,
        value: []const u8,
    },
    Nop,
    End,
});

allocator: std.mem.Allocator,
stream: *std.io.StreamSource,
header: Header,
strings: std.ArrayList(u8),
list: LinkedList,

pub fn init(stream: *std.io.StreamSource, allocator: std.mem.Allocator) !@This() {
    const header = try stream.reader().readStructEndian(Header, .big);

    if (header.magic != magic) {
        return error.InvalidMagic;
    }

    if (header.version < compatible_version) {
        return error.IncompatibleVersion;
    }

    const strings = try parseStringTable(allocator, header, stream);
    errdefer strings.deinit();

    const list = try createLinkedList(allocator, header, stream);
    errdefer deinitList(list);

    return .{
        .allocator = allocator,
        .stream = stream,
        .header = header,
        .strings = strings,
        .list = list,
    };
}

fn deinitList(allocator: std.mem.Allocator, list: LinkedList) void {
    var node = list.first orelse return;

    while (node.next) |next| {
        switch (node.data) {
            .BeginNode => |name| {
                allocator.free(name);
            },
            .Prop => |prop| {
                allocator.free(prop.value);
            },
            else => {},
        }

        allocator.destroy(node);
        node = next;
    }

    allocator.destroy(node);
}

pub fn deinit(self: *@This()) void {
    self.strings.deinit();

    deinitList(self.allocator, self.list);
}

fn parseStringTable(
    allocator: std.mem.Allocator,
    header: Header,
    stream: *std.io.StreamSource,
) !std.ArrayList(u8) {
    try stream.seekTo(header.off_dt_strings);

    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    stream.reader().readAllArrayList(&list, header.size_dt_strings) catch |err| switch (err) {
        error.StreamTooLong => {},
        else => return err,
    };

    return list;
}

fn alignStream(stream: *std.io.StreamSource) !void {
    try stream.reader().skipBytes(fdtPad(@intCast(try stream.getPos())), .{});
}

fn fdtPad(val: u32) u32 {
    return std.mem.alignForward(u32, val, @sizeOf(u32)) - val;
}

fn createLinkedList(
    allocator: std.mem.Allocator,
    header: Header,
    stream: *std.io.StreamSource,
) !LinkedList {
    try stream.seekTo(header.off_dt_struct);

    var list = LinkedList{};
    errdefer deinitList(allocator, list);

    var current_node: ?*LinkedList.Node = null;

    while (true) {
        const new_node = try allocator.create(LinkedList.Node);
        errdefer allocator.destroy(new_node);

        switch (try nextToken(stream)) {
            .BeginNode => {
                var node_name_buf = [_]u8{0} ** node_prop_name_max_chars;
                var node_name_stream = std.io.fixedBufferStream(&node_name_buf);
                try stream.reader().streamUntilDelimiter(node_name_stream.writer(), 0, null);
                const node_name = node_name_stream.getWritten();

                try alignStream(stream);

                new_node.* = LinkedList.Node{ .data = .{ .BeginNode = try allocator.dupe(u8, node_name) } };

                // We are at the root node
                if (std.mem.eql(u8, node_name, "")) {
                    if (list.first != null) {
                        return error.InvalidFdt;
                    }

                    list.prepend(new_node);
                } else {
                    list.insertAfter(current_node.?, new_node);
                }

                current_node = new_node;
            },
            .Prop => {
                const prop = try stream.reader().readStructEndian(Prop, .big);

                const value = try allocator.alloc(u8, prop.len);
                _ = try stream.reader().readAll(value);
                try alignStream(stream);

                new_node.* = LinkedList.Node{ .data = .{ .Prop = .{ .inner = prop, .value = value } } };

                list.insertAfter(current_node.?, new_node);
                current_node = new_node;
            },
            .EndNode => {
                new_node.* = LinkedList.Node{ .data = .EndNode };
                list.insertAfter(current_node.?, new_node);
                current_node = new_node;
            },
            .End => {
                new_node.* = LinkedList.Node{ .data = .End };
                list.insertAfter(current_node.?, new_node);
                current_node = new_node;
                break;
            },
            .Nop => {
                new_node.* = LinkedList.Node{ .data = .Nop };
                list.insertAfter(current_node.?, new_node);
                current_node = new_node;
            },
        }
    }

    return list;
}

fn nextToken(stream: *std.io.StreamSource) !Token {
    const token_value = try stream.reader().readVarInt(u32, .big, @sizeOf(u32));

    return try Token.parse(token_value);
}

/// Returns a tuple representing if the full path was found, the remaining path
/// members not found (non-empty if the full path was not found), and the last
/// node that was used (this will be an EndNode token node if the full path was
/// not found).
fn findProperty(
    self: *@This(),
    node: ?*LinkedList.Node,
    path: []const u8,
) !std.meta.Tuple(&.{ bool, *LinkedList.Node }) {
    var split = std.mem.splitScalar(u8, path, '/');

    return self._findProperty(node orelse return error.PropertyNotFound, &split);
}

fn skipToFdtEndNode(start: *LinkedList.Node) !*LinkedList.Node {
    std.debug.assert(start.data == .BeginNode);

    var depth: usize = 0;

    var node = start;

    while (node.next) |next| {
        switch (next.data) {
            .EndNode => {
                if (depth == 0) {
                    return next;
                }

                depth -= 1;
            },
            .BeginNode => depth += 1,
            .End => break,
            else => {},
        }

        node = next;
    }

    return error.InvalidFdt;
}

fn _findProperty(
    self: *@This(),
    root: *LinkedList.Node,
    path: *std.mem.SplitIterator(u8, .scalar),
) !std.meta.Tuple(&.{ bool, *LinkedList.Node }) {
    var node = root;

    while (true) {
        switch (node.data) {
            .BeginNode => |node_name| {
                if (std.mem.eql(u8, node_name, path.peek() orelse return .{ false, node })) {
                    _ = path.next() orelse unreachable;
                } else {
                    node = try skipToFdtEndNode(node);
                }
            },
            .Prop => |prop| {
                const prop_name = try self.getString(prop.inner.name_offset);

                if (std.mem.eql(u8, path.peek() orelse return .{ false, node }, prop_name)) {
                    _ = path.next() orelse unreachable;
                    return .{ true, node };
                }
            },
            .EndNode => {
                // Since we skip to the end of nodes if we don't match the node
                // name, we would only get to this point when we failed to
                // match any of the property names.
                return .{ false, node };
            },
            .Nop => {},
            .End => {
                if (node.next != null) {
                    return error.InvalidFdt;
                }

                return .{ false, node };
            },
        }

        node = node.next orelse return error.InvalidFdt;
    }
}

pub fn getString(self: *@This(), offset: u32) ![]const u8 {
    const start = self.strings.items[offset..];
    for (start, 0..) |char, i| {
        if (char == 0) {
            return self.strings.items[offset .. offset + i];
        }
    }

    return error.InvalidString;
}

pub fn getStringProperty(
    self: *@This(),
    path: []const u8,
) ![]const u8 {
    const found, const node = try self.findProperty(self.list.first, path);

    if (!found) {
        return error.PropertyNotFound;
    }

    switch (node.data) {
        .Prop => |prop| return prop.value[0 .. prop.value.len - 1], // omit null terminator
        else => unreachable,
    }
}

// TODO(jared): Make this nicer.
/// Returns the path that the phandle points to.
pub fn getPhandleProperty(
    self: *@This(),
    path: []const u8,
) ![]const u8 {
    return self.getStringProperty(path);
}

pub fn getStringListProperty(
    self: *@This(),
    path: []const u8,
) !std.mem.SplitIterator(u8, .scalar) {
    const found, const node = try self.findProperty(self.list.first, path);

    if (!found) {
        return error.PropertyNotFound;
    }

    std.debug.assert(node.data == .Prop);
    return std.mem.splitScalar(u8, switch (node.data) {
        .Prop => |prop| prop.value[0 .. prop.value.len - 1], // omit the last null terminator
        else => unreachable,
    }, 0);
}

pub fn getBoolProperty(
    self: *@This(),
    path: []const u8,
) bool {
    const found, const node = self.findProperty(self.list.first, path) catch return false;

    _ = node;

    return found;
}

pub fn getU32Property(self: *@This(), path: []const u8) !u32 {
    const found, const node = try self.findProperty(self.list.first, path);

    if (!found) {
        return error.PropertyNotFound;
    }

    var value = [_]u8{0} ** @sizeOf(u32);
    @memcpy(&value, b: switch (node.data) {
        .Prop => |prop| {
            if (prop.inner.len != @sizeOf(u32)) {
                return error.InvalidPropertyValue;
            }
            break :b prop.value;
        },
        else => unreachable,
    });

    return std.mem.readInt(u32, &value, .big);
}

pub fn getU64Property(self: *@This(), path: []const u8) !u64 {
    const found, const node = try self.findProperty(self.list.first, path);

    if (!found) {
        return error.PropertyNotFound;
    }

    const value = b: switch (node.data) {
        .Prop => |prop| {
            if (prop.inner.len != @sizeOf(u64)) {
                return error.InvalidPropertyValue;
            }
            break :b prop.value;
        },
        else => unreachable,
    };

    var left = [_]u8{0} ** @sizeOf(u32);
    var right = [_]u8{0} ** @sizeOf(u32);
    @memcpy(&left, value[0..4]);
    @memcpy(&right, value[4..]);

    return (@as(u64, std.mem.readInt(u32, &left, .big)) << 32) | @as(u64, std.mem.readInt(u32, &right, .big));
}

fn addString(self: *@This(), value: []const u8) !std.meta.Tuple(&.{ bool, u32 }) {
    if (std.mem.indexOf(u8, self.strings.items, value)) |offset| {
        return .{ true, @intCast(offset) };
    }

    const offset = self.strings.items.len;

    try self.strings.appendSlice(value);
    try self.strings.append(0); // null terminator

    return .{ false, @intCast(offset) };
}

pub fn upsertStringProperty(self: *@This(), path: []const u8, value: []const u8) !void {
    if (std.mem.containsAtLeast(u8, value, 1, &.{0})) {
        return error.InvalidString;
    }

    // TODO: use dupeZ()
    const dest = try self.allocator.alloc(u8, value.len + 1);
    errdefer self.allocator.free(dest);
    dest[value.len] = 0; // null terminator
    std.mem.copyForwards(u8, dest, value);

    try self.upsertProperty(path, dest);
}

pub fn upsertU32Property(self: *@This(), path: []const u8, value: u32) !void {
    var value_bytes = [_]u8{0} ** @sizeOf(u32);
    std.mem.writeInt(u32, &value_bytes, value, .big);

    const dest = try self.allocator.alloc(u8, @sizeOf(u32));
    errdefer self.allocator.free(dest);

    @memcpy(dest, &value_bytes);

    try self.upsertProperty(path, dest);
}

pub fn upsertU64Property(self: *@This(), path: []const u8, value: u64) !void {
    var left = [_]u8{0} ** @sizeOf(u32);
    std.mem.writeInt(u32, &left, @intCast(value >> 32), .big);

    var right = [_]u8{0} ** @sizeOf(u32);
    std.mem.writeInt(u32, &right, @intCast(value & std.math.maxInt(u32)), .big);

    const dest = try self.allocator.alloc(u8, @sizeOf(u64));
    errdefer self.allocator.free(dest);

    @memcpy(dest[0..4], &left);
    @memcpy(dest[4..], &right);

    try self.upsertProperty(path, dest);
}

pub fn upsertBoolProperty(self: *@This(), path: []const u8, value: bool) !void {
    return if (value) self.upsertProperty(path, &.{}) else self.removeProperty(path);
}

fn removeString(self: *@This(), name_offset: u32) !usize {
    // First visit all properties first to ensure no other properties are
    // referencing this string.
    var node = self.list.first orelse return 0;

    var references: usize = 0;

    while (true) {
        switch (node.data) {
            .Prop => |prop| {
                if (prop.inner.name_offset == name_offset) {
                    references += 1;
                }
            },
            else => {},
        }

        node = node.next orelse break;
    }

    if (references > 1) {
        return 0;
    }

    const null_index = std.mem.indexOfScalarPos(u8, self.strings.items, name_offset, 0) orelse return 0;
    try self.strings.replaceRange(name_offset, null_index + 1 - name_offset, &.{});
    return null_index + 1 - name_offset;
}

fn updateNameOffsets(self: *@This(), removed_name_offset: u32, bytes_removed: u32) void {
    var node = self.list.first orelse return;
    while (true) {
        switch (node.data) {
            .Prop => |*prop| {
                if (prop.inner.name_offset > removed_name_offset) {
                    prop.inner.name_offset -= bytes_removed;
                }
            },
            else => {},
        }

        node = node.next orelse break;
    }
}

fn removeProperty(self: *@This(), path: []const u8) !void {
    const found, const node = try self.findProperty(self.list.first, path);

    if (!found) {
        return;
    }

    std.debug.assert(node.data == .Prop);

    const prop = switch (node.data) {
        .Prop => |prop| prop,
        else => unreachable,
    };

    const strings_bytes_removed: u32 = @intCast(try self.removeString(prop.inner.name_offset));
    self.updateNameOffsets(prop.inner.name_offset, strings_bytes_removed);

    self.list.remove(node);
    self.allocator.destroy(node);
    self.allocator.free(prop.value);

    const struct_bytes_removed: u32 = @intCast(
        @sizeOf(u32) // prop tag
        + @sizeOf(Prop) // prop struct
        + prop.value.len + fdtPad(@intCast(prop.value.len)), // prop value plus padding
    );

    self.header.size_dt_struct -= struct_bytes_removed;
    self.header.off_dt_strings -= struct_bytes_removed;
    self.header.total_size -= (struct_bytes_removed + strings_bytes_removed);
    self.header.size_dt_strings -= strings_bytes_removed;
}

fn upsertProperty(self: *@This(), path: []const u8, value_bytes: []const u8) !void {
    var split = std.mem.splitScalar(u8, path, '/');
    const found, var node = try self._findProperty(self.list.first orelse return error.InvalidFdt, &split);

    if (!found) {
        var property_added = false;
        while (split.next()) |path_entry| {
            const at_end_of_path = split.peek() == null;

            if (at_end_of_path) {
                // add the property
                const new_node = try self.allocator.create(LinkedList.Node);
                errdefer self.allocator.destroy(new_node);

                const name_found, const name_offset = try self.addString(path_entry);

                new_node.* = .{
                    .data = .{
                        .Prop = .{
                            .inner = .{
                                .len = @intCast(value_bytes.len),
                                .name_offset = name_offset,
                            },
                            .value = value_bytes,
                        },
                    },
                };

                self.list.insertBefore(node, new_node);

                // adjust size/offset metadata
                {
                    const struct_bytes_added: u32 = @intCast(
                        @sizeOf(u32) // prop tag
                        + @sizeOf(Prop) // prop struct
                        + value_bytes.len + fdtPad(@intCast(value_bytes.len)), // prop value plus padding
                    );

                    self.header.size_dt_struct += struct_bytes_added;
                    self.header.off_dt_strings += struct_bytes_added;
                    self.header.total_size += struct_bytes_added;
                    if (!name_found) {
                        const strings_bytes_added = @as(u32, @intCast(path_entry.len)) + 1; // include null terminator
                        self.header.size_dt_strings += strings_bytes_added;
                        self.header.total_size += strings_bytes_added;
                    }
                }

                property_added = true;
            } else {
                // add a missing node
                const new_begin_node = try self.allocator.create(LinkedList.Node);
                errdefer self.allocator.destroy(new_begin_node);
                const node_name = try self.allocator.dupe(u8, path_entry);
                errdefer self.allocator.free(node_name);
                new_begin_node.* = .{ .data = .{ .BeginNode = node_name } };
                self.list.insertBefore(node, new_begin_node);

                const new_end_node = try self.allocator.create(LinkedList.Node);
                errdefer self.allocator.destroy(new_end_node);
                new_end_node.* = .{ .data = .EndNode };
                self.list.insertBefore(node, new_end_node);

                // adjust size/offset metadata
                {
                    const struct_bytes_added: u32 = @intCast(
                        @sizeOf(u32) // begin node tag
                        + node_name.len + 1 + fdtPad(@as(u32, @intCast(node_name.len)) + 1) // begin node value (node name) plus padding
                        + @sizeOf(u32), // end node tag
                    );

                    self.header.size_dt_struct += struct_bytes_added;
                    self.header.off_dt_strings += struct_bytes_added;
                    self.header.total_size += struct_bytes_added;
                }

                node = new_end_node;
            }
        }

        if (!property_added) {
            return error.PropertyNotAdded;
        }
    } else {
        std.debug.assert(node.data == .Prop);
        switch (node.data) {
            .Prop => |*prop| {
                self.allocator.free(prop.value); // free old value

                prop.value = value_bytes;

                const struct_bytes_diff: u32 = @intCast(
                    value_bytes.len + fdtPad(@intCast(value_bytes.len)) // new value plus padding
                    - (prop.value.len + fdtPad(@intCast(prop.value.len))), // old value plus padding
                );

                self.header.size_dt_struct += struct_bytes_diff;
                self.header.off_dt_strings += struct_bytes_diff;
                self.header.total_size += struct_bytes_diff;
            },
            else => unreachable,
        }
    }
}

/// Returns the total size (in bytes) needed to serialize the devicetree to FDT
/// format. This is useful to call if the FDT is going to be written to a
/// heap-backed buffer, since the returned value can be used with alloc().
pub fn size(self: *@This()) usize {
    return self.header.total_size;
}

fn writeListNode(writer: anytype, node: *LinkedList.Node) !void {
    const tag_value = @intFromEnum(node.data);
    try writer.writeInt(u32, tag_value, .big);

    switch (node.data) {
        .BeginNode => |node_name| {
            try writer.writeAll(node_name);
            try writer.writeByte(0); // null terminator
            try writer.writeByteNTimes(0, fdtPad(@intCast(node_name.len + 1))); // padding
        },
        .Prop => |prop| {
            try writer.writeStructEndian(prop.inner, .big);
            try writer.writeAll(prop.value);
            try writer.writeByteNTimes(0, fdtPad(@intCast(prop.value.len))); // padding
        },
        .EndNode, .Nop, .End => {},
    }
}

pub fn save(self: *@This(), writer: anytype) !void {
    var node = self.list.first orelse return error.InvalidFdt;

    try writer.writeStructEndian(self.header, .big);

    try writer.writeByteNTimes(0, self.header.off_mem_rsvmap - @sizeOf(Header));

    try self.stream.seekTo(self.header.off_mem_rsvmap);

    // TODO(jared): probably don't need to alloc here
    {
        const mem_rsvmap_bytes = self.header.off_dt_struct - self.header.off_mem_rsvmap;
        const mem_rsvmap_buf = try self.allocator.alloc(u8, mem_rsvmap_bytes);
        defer self.allocator.free(mem_rsvmap_buf);
        _ = try self.stream.reader().readAll(mem_rsvmap_buf);
        try writer.writeAll(mem_rsvmap_buf);
    }

    while (true) {
        try writeListNode(writer, node);
        node = node.next orelse break;
    }

    try writer.writeByteNTimes(0, self.header.off_dt_strings - self.header.off_dt_struct - self.header.size_dt_struct);

    try writer.writeAll(self.strings.items);
}

pub fn printValue(writer: anytype, value: []const u8) !void {
    if (value.len == 0) {
        try writer.print("true", .{});
        return;
    }

    if (value[0] != 0 and value[value.len - 1] == 0) {
        var is_stringlike = true;

        var split = std.mem.splitScalar(u8, value[0 .. value.len - 1], 0);

        while (split.next()) |maybe_string| {
            for (maybe_string) |byte| {
                if (!std.ascii.isPrint(byte)) {
                    is_stringlike = false;
                    break;
                }
            }
        }

        if (is_stringlike) {
            split.reset();
            while (split.next()) |string| {
                try writer.print("{s} ", .{string});
            }
            return;
        }
    }

    if (@mod(value.len, 4) == 0) {
        var window = std.mem.window(u8, value, 4, 4);
        while (window.next()) |next| {
            var arr: [@sizeOf(u32)]u8 = undefined;
            @memcpy(&arr, next);
            try writer.print("0x{x:0>8} ", .{std.mem.readInt(u32, &arr, .big)});
        }
        return;
    }

    try writer.print("{x}", .{value});
}

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

test "fdt read" {
    var stream = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(&test_fdt) };

    var fdt = try Fdt.init(&stream, std.testing.allocator);
    defer fdt.deinit();

    try std.testing.expectError(error.PropertyNotFound, fdt.getStringProperty("/chosen/not_present"));
    try std.testing.expectError(error.PropertyNotFound, fdt.getStringProperty("/this_is_a_phandle"));

    const this_is_a_phandle = try fdt.getPhandleProperty("/chosen/this_is_a_phandle");
    try std.testing.expectEqualStrings("/chosen", this_is_a_phandle);

    const this_is_a_string = try fdt.getStringProperty("/chosen/this_is_a_string");
    try std.testing.expectEqualStrings("foo bar baz", this_is_a_string);

    var this_is_a_stringlist = try fdt.getStringListProperty("/chosen/this_is_a_stringlist");
    try std.testing.expectEqualStrings("foo", this_is_a_stringlist.next() orelse unreachable);
    try std.testing.expectEqualStrings("bar", this_is_a_stringlist.next() orelse unreachable);
    try std.testing.expectEqualStrings("baz", this_is_a_stringlist.next() orelse unreachable);
    try std.testing.expectEqual(null, this_is_a_stringlist.next());

    const this_is_a_bool = fdt.getBoolProperty("/chosen/this_is_a_bool");
    try std.testing.expect(this_is_a_bool);

    const this_is_not_a_bool = fdt.getBoolProperty("/chosen/this_is_not_a_bool");
    try std.testing.expect(!this_is_not_a_bool);

    const this_is_a_u32 = try fdt.getU32Property("/chosen/this_is_a_u32");
    try std.testing.expectEqual(0x11223344, this_is_a_u32);

    const this_is_a_u64 = try fdt.getU64Property("/chosen/this_is_a_u64");
    try std.testing.expectEqual(0x1122334455667788, this_is_a_u64);
}

test "fdt write" {
    var stream = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(&test_fdt) };

    var fdt = try Fdt.init(&stream, std.testing.allocator);
    defer fdt.deinit();

    // ensure removing a property we started with works
    try fdt.removeProperty("/chosen/this_is_a_stringlist");

    // add new property to root node
    try fdt.upsertStringProperty("/foo", "bar");
    try std.testing.expectEqualStrings("bar", try fdt.getStringProperty("/foo"));

    // add new property to existing nested node
    try fdt.upsertStringProperty("/chosen/bootargs", "console=ttyAMA0,115200");
    try std.testing.expectEqualStrings("console=ttyAMA0,115200", try fdt.getStringProperty("/chosen/bootargs"));

    // add new property to a new node
    try fdt.upsertStringProperty("/cchosen/bootargs", "console=ttyAMA0,115200");
    try std.testing.expectEqualStrings("console=ttyAMA0,115200", try fdt.getStringProperty("/cchosen/bootargs"));

    // add new property to a new node nested under an existing node
    try fdt.upsertStringProperty("/chosen/foo/bootargs", "console=ttyAMA0,115200");
    try std.testing.expectEqualStrings("console=ttyAMA0,115200", try fdt.getStringProperty("/chosen/foo/bootargs"));

    // change an existing property
    try fdt.upsertStringProperty("/foo", "baz");
    try std.testing.expectEqualStrings("baz", try fdt.getStringProperty("/foo"));

    try fdt.upsertU32Property("/u32", 0x1);
    try std.testing.expectEqual(0x1, try fdt.getU32Property("/u32"));

    try fdt.upsertU64Property("/u64", 0x1122334455667788);
    try std.testing.expectEqual(0x1122334455667788, try fdt.getU64Property("/u64"));

    try fdt.upsertBoolProperty("/bool", true);
    try std.testing.expect(fdt.getBoolProperty("/bool"));

    // "add" boolean property set to false, which actually removes the property
    // ensure the "bool" property name is not present in the string table.
    try fdt.upsertBoolProperty("/bool", false);
    try std.testing.expect(!fdt.getBoolProperty("/bool"));

    // serialize back to FDT
    const buf = try std.testing.allocator.alloc(u8, fdt.size());
    defer std.testing.allocator.free(buf);
    var update_stream = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(buf) };
    try fdt.save(update_stream.writer());

    // ensure the unique strings we removed don't appear
    try std.testing.expectEqual(null, std.mem.indexOf(u8, buf, "bool"));
    try std.testing.expectEqual(null, std.mem.indexOf(u8, buf, "this_is_a_stringlist"));
}
