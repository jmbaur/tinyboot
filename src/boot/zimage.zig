const std = @import("std");

const magic: usize = 0x016f2818;
const endianness: usize = 0x04030201;
const table_magic: usize = 0x45454545;

const Header = packed struct {
    magic: u32,
    start: u32,
    end: u32,
    endianness: u32,
    table_magic: u32,
    table_addr: u32,
};

pub fn main() !void {
    const zimage = try std.fs.cwd().openFile("/tmp/zImage", .{});
    defer zimage.close();

    try zimage.seekTo(0x24);
    const header = Header{
        .magic = try zimage.reader().readInt(u32, .little),
        .start = try zimage.reader().readInt(u32, .little),
        .end = try zimage.reader().readInt(u32, .little),
        .endianness = try zimage.reader().readInt(u32, .little),
        .table_magic = try zimage.reader().readInt(u32, .little),
        .table_addr = try zimage.reader().readInt(u32, .little),
    };

    if (header.magic != magic or
        header.endianness != endianness or
        header.table_magic != table_magic or
        header.end < header.start)
    {
        return error.InvalidImage;
    }

    std.log.debug("{}", .{header});
}
