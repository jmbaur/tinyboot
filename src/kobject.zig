const std = @import("std");
const posix = std.posix;

const Device = @import("./device.zig");
const DeviceWatcher = @import("./watch.zig");
const utils = @import("./utils.zig");

pub fn parseUeventFileContents(
    subsystem: Device.Subsystem,
    contents: []const u8,
) ?Device {
    var iter = std.mem.splitSequence(u8, contents, "\n");

    var major: ?u32 = null;
    var minor: ?u32 = null;
    var ifindex: ?u32 = null;

    while (iter.next()) |line| {
        var split = std.mem.splitSequence(u8, line, "=");
        const key = split.next() orelse continue;
        const value = split.next() orelse continue;

        if (std.mem.eql(u8, key, "IFINDEX")) {
            ifindex = std.fmt.parseInt(u32, value, 10) catch return null;
        } else if (std.mem.eql(u8, key, "MAJOR")) {
            major = std.fmt.parseInt(u32, value, 10) catch return null;
        } else if (std.mem.eql(u8, key, "MINOR")) {
            minor = std.fmt.parseInt(u32, value, 10) catch return null;
        }
    }

    return .{
        .subsystem = subsystem,
        .type = if (ifindex) |ifidx|
            .{ .ifindex = ifidx }
        else
            .{ .node = .{
                major orelse return null,
                minor orelse return null,
            } },
    };
}

pub fn parseUeventKobjectContents(contents: []const u8) ?DeviceWatcher.Event {
    var iter = std.mem.splitSequence(u8, contents, &.{0});

    const first_line = iter.next().?;
    var first_line_split = std.mem.splitSequence(u8, first_line, "@");
    const action = Action.fromStr(first_line_split.next().?) catch return null;

    var subsystem: ?Device.Subsystem = null;
    var major: ?u32 = null;
    var minor: ?u32 = null;
    var ifindex: ?u32 = null;

    while (iter.next()) |line| {
        var split = std.mem.splitSequence(u8, line, "=");
        const key = split.next() orelse continue;
        const value = split.next() orelse continue;

        // TODO(jared): The net subsystem (possibly) doesn't set DEVNAME, but
        // rather INTERFACE.
        if (std.mem.eql(u8, key, "SUBSYSTEM")) {
            subsystem = Device.Subsystem.fromStr(value) catch return null;
        } else if (std.mem.eql(u8, key, "IFINDEX")) {
            ifindex = std.fmt.parseInt(u32, value, 10) catch return null;
        } else if (std.mem.eql(u8, key, "MAJOR")) {
            major = std.fmt.parseInt(u32, value, 10) catch return null;
        } else if (std.mem.eql(u8, key, "MINOR")) {
            minor = std.fmt.parseInt(u32, value, 10) catch return null;
        }
    }

    return .{
        .action = action,
        .device = .{
            .subsystem = subsystem orelse return null,
            .type = if (ifindex) |ifidx|
                .{ .ifindex = ifidx }
            else
                .{ .node = .{
                    major orelse return null,
                    minor orelse return null,
                } },
        },
    };
}

// test "uevent file content parsing" {
//     const test_partition =
//         \\MAJOR=259
//         \\MINOR=1
//         \\DEVNAME=nvme0n1p1
//         \\DEVTYPE=partition
//         \\DISKSEQ=1
//         \\PARTN=1
//     ;
//
//     var partition_uevent = try parseUeventFileContents(std.testing.allocator, test_partition);
//     defer partition_uevent.deinit();
//
//     try std.testing.expectEqualStrings("259", partition_uevent.get("MAJOR").?);
//     try std.testing.expectEqualStrings("partition", partition_uevent.get("DEVTYPE").?);
//     try std.testing.expectEqualStrings("1", partition_uevent.get("DISKSEQ").?);
//     try std.testing.expectEqualStrings("1", partition_uevent.get("PARTN").?);
//
//     const test_disk =
//         \\MAJOR=259
//         \\MINOR=0
//         \\DEVNAME=nvme0n1
//         \\DEVTYPE=disk
//         \\DISKSEQ=1
//     ;
//
//     var disk_uevent = try parseUeventFileContents(std.testing.allocator, test_disk);
//     defer disk_uevent.deinit();
//
//     try std.testing.expectEqualStrings("259", disk_uevent.get("MAJOR").?);
//     try std.testing.expectEqualStrings("disk", disk_uevent.get("DEVTYPE").?);
//     try std.testing.expectEqualStrings("1", disk_uevent.get("DISKSEQ").?);
//
//     const test_tpm =
//         \\MAJOR=10
//         \\MINOR=224
//         \\DEVNAME=tpm0
//     ;
//
//     var tpm_uevent = try parseUeventFileContents(std.testing.allocator, test_tpm);
//     defer tpm_uevent.deinit();
//
//     try std.testing.expectEqualStrings("10", tpm_uevent.get("MAJOR").?);
//     try std.testing.expectEqualStrings("224", tpm_uevent.get("MINOR").?);
//     try std.testing.expectEqualStrings("tpm0", tpm_uevent.get("DEVNAME").?);
// }

// test "uevent kobject add chardev parsing" {
//     const content = try std.mem.join(std.testing.allocator, &.{0}, &.{
//         "add@/devices/platform/serial8250/tty/ttyS6",
//         "ACTION=add",
//         "DEVPATH=/devices/platform/serial8250/tty/ttyS6",
//         "SUBSYSTEM=tty",
//         "SYNTH_UUID=0",
//         "MAJOR=4",
//         "MINOR=70",
//         "DEVNAME=ttyS6",
//         "SEQNUM=3469",
//     });
//     defer std.testing.allocator.free(content);
//
//     var kobject = try parseUeventKobjectContents(std.testing.allocator, content) orelse unreachable;
//     defer kobject.deinit();
//
//     try std.testing.expectEqual(Action.add, kobject.action);
//     try std.testing.expectEqualStrings("/devices/platform/serial8250/tty/ttyS6", kobject.device_path);
//     try std.testing.expectEqualStrings("0", kobject.uevent.get("SYNTH_UUID").?);
// }

// test "uevent kobject remove chardev parsing" {
//     const content = try std.mem.join(std.testing.allocator, &.{0}, &.{
//         "remove@/devices/platform/serial8250/tty/ttyS6",
//         "ACTION=remove",
//         "DEVPATH=/devices/platform/serial8250/tty/ttyS6",
//         "SUBSYSTEM=tty",
//         "SYNTH_UUID=0",
//         "MAJOR=4",
//         "MINOR=70",
//         "DEVNAME=ttyS6",
//         "SEQNUM=3471",
//     });
//     defer std.testing.allocator.free(content);
//
//     var kobject = try parseUeventKobjectContents(std.testing.allocator, content) orelse unreachable;
//     defer kobject.deinit();
//
//     try std.testing.expectEqual(Action.remove, kobject.action);
//     try std.testing.expectEqualStrings("/devices/platform/serial8250/tty/ttyS6", kobject.device_path);
//     try std.testing.expectEqualStrings("3471", kobject.uevent.get("SEQNUM").?);
// }

// https://github.com/torvalds/linux/blob/afcd48134c58d6af45fb3fdb648f1260b20f2326/lib/kobject_uevent.c#L50
pub const Action = union(enum) {
    add,
    remove,

    fn fromStr(value: []const u8) !@This() {
        return utils.enumFromStr(@This(), value);
    }
};
