const std = @import("std");
const posix = std.posix;
const MS = std.os.linux.MS;

const BootLoader = @import("./bootloader.zig");
const Device = @import("../device.zig");
const Filesystem = @import("../disk/filesystem.zig");
const Gpt = @import("../disk/gpt.zig");
const Mbr = @import("../disk/mbr.zig");
const TmpDir = @import("../tmpdir.zig");

const DiskBootLoader = @This();

pub const autoboot = true;

arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
tmpdir: ?TmpDir = null,
loader_timeout: u8 = 0,

pub fn match(device: *const Device) ?u8 {
    if (device.subsystem != .block) {
        return null;
    }

    var sysfs_disk_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sysfs_disk_path = device.nodeSysfsPath(&sysfs_disk_path_buf) catch return null;

    var sysfs_dir = std.fs.cwd().openDir(sysfs_disk_path, .{}) catch return null;
    defer sysfs_dir.close();

    // Disk block devices have a "removable" file in their sysfs directory,
    // partitions do not.
    var removable_file = sysfs_dir.openFile("removable", .{}) catch return null;
    defer removable_file.close();

    var buf: [1]u8 = undefined;
    if ((removable_file.read(&buf) catch return null) != 1) {
        return null;
    }

    // Prioritize removable devices over non-removable. This allows for
    // plugging in a USB-stick and having it "just work".
    if (std.mem.eql(u8, &buf, "1")) {
        return 50;
    } else {
        return 55;
    }
}

pub fn init() DiskBootLoader {
    return .{};
}

pub fn name() []const u8 {
    return "disk";
}

pub fn timeout(self: *DiskBootLoader) u8 {
    return self.loader_timeout;
}

pub fn deinit(self: *DiskBootLoader) void {
    defer self.arena.deinit();

    self.unmount() catch |err| {
        std.log.err("failed to unmount: {}", .{err});
    };
}

pub fn probe(
    self: *DiskBootLoader,
    entries: *std.ArrayList(BootLoader.Entry),
    disk_device: Device,
) !void {
    var disk_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const disk_path = try disk_device.nodePath(&disk_path_buf);

    var sysfs_disk_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sysfs_disk_path = try disk_device.nodeSysfsPath(&sysfs_disk_path_buf);

    var sysfs_disk_dir = try std.fs.cwd().openDir(sysfs_disk_path, .{});
    defer sysfs_disk_dir.close();

    var disk = try std.fs.cwd().openFile(disk_path, .{});
    defer disk.close();

    var disk_source = std.io.StreamSource{ .file = disk };
    // All GPTs also have an MBR, so we can invalidate the disk
    // entirely if it does not have an MBR.
    var mbr = Mbr.init(&disk_source) catch |err| {
        std.log.warn("no MBR found on disk {s}: {}", .{ disk_device, err });
        return;
    };

    const boot_partn = b: {
        for (mbr.partitions(), 1..) |part, mbr_partn| {
            const part_type = Mbr.PartitionType.fromValue(part.partType()) orelse continue;

            if ((part.isBootable() and
                // BootLoaderSpec uses this partition type for MBR, see
                // https://uapi-group.org/specifications/specs/boot_loader_specification/#the-partitionsl.
                (part_type == .LinuxExtendedBoot or
                // QEMU uses this partition type when using a FAT
                // emulated drive with `-drive file=fat:rw:some/directory`.
                part_type == .Fat16)) or
                // Many ISOs have this MBR table setup where the partition type
                // is ESP and it is marked as non-bootable.
                part_type == .EfiSystemPartition)
            {
                break :b mbr_partn;
            }

            // disk has a GPT
            if (!part.isBootable() and part_type == .ProtectedMbr) {
                var gpt = Gpt.init(&disk_source) catch |err| switch (err) {
                    Gpt.Error.MissingMagicNumber => {
                        std.log.debug("disk {s} does not contain a GUID partition table", .{disk_device});
                        continue;
                    },
                    Gpt.Error.HeaderCrcFail => {
                        std.log.err("disk {s} CRC integrity check failed", .{disk_device});
                        continue;
                    },
                    else => {
                        std.log.err("failed to read disk {s}: {}", .{ disk_device, err });
                        continue;
                    },
                };

                const partitions = try gpt.partitions(self.arena.allocator());
                for (partitions, 1..) |partition, gpt_partn| {
                    if (partition.partType() orelse continue == .EfiSystem) {
                        break :b gpt_partn;
                    }
                }
            }
        }

        return;
    };

    const disk_major, const disk_minor = disk_device.type.node;

    // Construct a new Device for the partition, which will have the same major
    // number and a minor number equalling the minor number of the disk plus
    // the number of the partition in the disk.
    const boot_partition = Device{
        .subsystem = disk_device.subsystem,
        .type = .{
            .node = .{
                disk_major, disk_minor + @as(u32, @intCast(boot_partn)),
            },
        },
    };

    std.log.info("found boot partition on disk {s} partition {d}", .{ disk_device, boot_partition });

    var partition_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const partition_path = try boot_partition.nodePath(&partition_path_buf);

    var partition = try std.fs.cwd().openFile(partition_path, .{});
    defer partition.close();

    var esp_file_source = std.io.StreamSource{ .file = partition };
    const fstype = try Filesystem.Type.detect(&esp_file_source) orelse {
        std.log.err("could not detect filesystem on boot partition {}", .{boot_partition});
        return;
    };

    try self.mount(fstype, partition_path);

    try self.searchForEntries(disk_device, entries);
}

pub fn entryLoaded(self: *DiskBootLoader, ctx: *anyopaque) void {
    self._entryLoaded(ctx) catch |err| {
        std.log.err(
            "failed to finalize BLS boot counter for chosen entry: {}",
            .{err},
        );
    };
}

fn _entryLoaded(self: *@This(), ctx: *anyopaque) !void {
    var bls_entry_file: *BlsEntryFile = @ptrCast(@alignCast(ctx));

    var tmpdir = self.tmpdir orelse return;

    const allocator = self.arena.allocator();

    const original_name = try bls_entry_file.toFilename(allocator);
    defer allocator.free(original_name);

    if (bls_entry_file.tries_done) |*done| done.* +|= 1;
    if (bls_entry_file.tries_left) |*left| left.* -|= 1;

    if (bls_entry_file.tries_left) |tries_left| {
        std.log.info(
            "{} {s} remaining for entry \"{s}\"",
            .{
                tries_left,
                if (tries_left == 1) "try" else "tries",
                bls_entry_file.name,
            },
        );
    }

    const new_name = try bls_entry_file.toFilename(allocator);
    defer allocator.free(new_name);

    if (!std.mem.eql(u8, original_name, new_name)) {
        var mount_dir = try tmpdir.dir.openDir(mountpath, .{});
        defer mount_dir.close();

        var entries_dir = try mount_dir.openDir("loader/entries", .{});
        defer entries_dir.close();

        try entries_dir.rename(original_name, new_name);
        posix.sync();

        std.log.debug("entry renamed to {s}", .{new_name});
    }
}

const mountpath = "mount";

fn mount(self: *DiskBootLoader, fstype: Filesystem.Type, path: []const u8) !void {
    // make sure there are no current mountpoints
    try self.unmount();

    const tmpdir = try TmpDir.create(.{});

    try tmpdir.dir.makePath(mountpath);

    var where_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_where = try tmpdir.dir.realpath(mountpath, &where_buf);
    const where = try self.arena.allocator().dupeZ(u8, tmp_where);
    defer self.arena.allocator().free(where);

    var what_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_what = try std.fs.cwd().realpath(path, &what_buf);
    const what = try self.arena.allocator().dupeZ(u8, tmp_what);
    defer self.arena.allocator().free(what);

    switch (posix.errno(std.os.linux.mount(
        what,
        where,
        switch (fstype) {
            .Vfat => "vfat",
        },
        MS.NOSUID | MS.NODEV | MS.NOEXEC,
        0,
    ))) {
        .SUCCESS => {},
        else => |err| {
            return posix.unexpectedErrno(err);
        },
    }

    self.tmpdir = tmpdir;
}

fn unmount(self: *DiskBootLoader) !void {
    if (self.tmpdir) |*tmpdir| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const mountpoint = try tmpdir.dir.realpathZ(mountpath, &buf);

        _ = std.os.linux.umount2(@ptrCast(mountpoint.ptr), std.os.linux.MNT.DETACH);

        std.log.info("unmounted disk from {s}", .{mountpoint});

        tmpdir.cleanup();
        self.tmpdir = null;
    }
}

fn versionInId(id: []const u8) ?std.SemanticVersion {
    for (id, 0..) |char, idx| {
        if ('0' <= char and char <= '9') {
            return std.SemanticVersion.parse(id[idx..]) catch break;
        }
    }

    return null;
}

// Example implementation in systemd-boot https://github.com/systemd/systemd/blob/de732ade0909c2d44a214fb1eaea5f5b1721e9f1/src/boot/efi/boot.c#L1670
/// Follows logic outlined by Boot Loader Specification sorting (described at https://uapi-group.org/specifications/specs/boot_loader_specification/#sorting).
///
/// Version comparisons are done by parsing version fields using semantic versioning.
fn blsEntryLessThan(default_entry: ?[]const u8, a: BlsEntry, b: BlsEntry) bool {
    if (default_entry) |default_title| {
        if (std.mem.eql(u8, a.id, default_title)) {
            return true;
        }
    }

    // Order entries that have no tries left to the end of the list.
    if (a.tries_left != null and b.tries_left != null) {
        const a_tries_left = a.tries_left.?;
        const b_tries_left = b.tries_left.?;

        if (a_tries_left == 0) {
            return a_tries_left > b_tries_left;
        }
    }

    // One has a sort key and the other does not, prefer the one with the sort
    // key.
    if ((a.sort_key == null) != (b.sort_key == null)) {
        return a.sort_key != null;
    }

    if (a.sort_key != null and b.sort_key != null) {
        // Both have a sort key, do new-style ordering.
        const a_sort_key = a.sort_key.?;
        const b_sort_key = b.sort_key.?;

        switch (std.mem.order(u8, a_sort_key, b_sort_key)) {
            .eq => {},
            .gt => return false,
            .lt => return true,
        }

        switch (std.mem.order(u8, a.machine_id orelse "", b.machine_id orelse "")) {
            .eq => {},
            .gt => return false,
            .lt => return true,
        }

        {
            const a_version = std.SemanticVersion.parse(a.version orelse "0.0.0") catch b: {
                std.log.debug("invalid version in {s}: {?s}", .{ a.id, a.version });
                break :b std.SemanticVersion{
                    .major = 0,
                    .minor = 0,
                    .patch = 0,
                };
            };
            const b_version = std.SemanticVersion.parse(b.version orelse "0.0.0") catch b: {
                std.log.debug("invalid version in {s}: {?s}", .{ b.id, b.version });
                break :b std.SemanticVersion{
                    .major = 0,
                    .minor = 0,
                    .patch = 0,
                };
            };

            switch (std.SemanticVersion.order(a_version, b_version)) {
                .eq => {},
                .gt => return true,
                .lt => return false,
            }
        }
    }

    {
        const a_id_version = versionInId(a.id);
        const b_id_version = versionInId(b.id);
        if (a_id_version != null and b_id_version != null) {
            switch (std.SemanticVersion.order(a_id_version.?, b_id_version.?)) {
                .eq => {},
                .gt => return true,
                .lt => return false,
            }
        }
    }

    if (a.tries_left == null or b.tries_left == null) {
        return false;
    }

    const a_tries_left = a.tries_left.?;
    const b_tries_left = b.tries_left.?;
    if (a_tries_left != b_tries_left) {
        return a_tries_left > b_tries_left;
    }

    // If both have the same number of tries left, choose the one with less
    // tries done.
    return a.tries_done orelse 0 < b.tries_done orelse 0;
}

test "boot entry sorting" {
    // default entry set
    try std.testing.expect(blsEntryLessThan(
        "zzz",
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "zzz",
        },
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "aaa",
        },
    ));

    // no tries left is always ordered less than some tries left
    try std.testing.expect(blsEntryLessThan(
        null,
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "foo",
            .tries_left = 1,
        },
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "bar",
            .tries_left = 0,
        },
    ));

    // entries with sort keys are ordered before entries without sort keys
    try std.testing.expect(blsEntryLessThan(
        null,
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "foo",
            .sort_key = "asdf",
        },
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "bar",
            .sort_key = null,
        },
    ));

    // entries with different sort keys are sorted based on the sort key
    try std.testing.expect(blsEntryLessThan(
        null,
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "foo",
            .sort_key = "abcd",
        },
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "bar",
            .sort_key = "bcde",
        },
    ));

    // entries with the same sort key and different machine IDs are sorted
    // based on the machine ID
    try std.testing.expect(blsEntryLessThan(
        null,
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "foo",
            .sort_key = "yo",
            .machine_id = "abc",
        },
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "bar",
            .sort_key = "yo",
            .machine_id = "xyz",
        },
    ));

    // entries with the same sort key and same machine IDs are sorted
    // based on the version
    try std.testing.expect(blsEntryLessThan(
        null,
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "foo",
            .sort_key = "yo",
            .machine_id = "abc",
            .version = "0.0.2",
        },
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "bar",
            .sort_key = "yo",
            .machine_id = "abc",
            .version = "0.0.1",
        },
    ));

    // entries without sort keys are sorted based on the version potentially
    // embedded in the filename
    try std.testing.expect(blsEntryLessThan(
        null,
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "foo-0.0.2",
        },
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "foo-0.0.1",
        },
    ));

    // entries without sort keys, no versions encoded in the filenames, and the
    // same number of tries left are sorted based on which entry has less tries
    // done
    try std.testing.expect(blsEntryLessThan(
        null,
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "foo",
            .tries_left = 1,
            .tries_done = 0,
        },
        BlsEntry{
            .allocator = std.testing.allocator,
            .id = "bar",
            .tries_left = 1,
            .tries_done = 1,
        },
    ));
}

fn searchForEntries(
    self: *DiskBootLoader,
    disk_device: Device,
    entries: *std.ArrayList(BootLoader.Entry),
) !void {
    const allocator = self.arena.allocator();

    var tmpdir = self.tmpdir.?;
    var mount_dir = try tmpdir.dir.openDir(mountpath, .{});
    defer mount_dir.close();

    var entries_dir = try mount_dir.openDir(
        "loader/entries",
        .{ .iterate = true },
    );
    defer entries_dir.close();

    var bls_entries = std.ArrayList(BlsEntry).init(allocator);
    defer bls_entries.deinit();

    const loader_conf: LoaderConf = b: {
        var file = mount_dir.openFile("loader/loader.conf", .{}) catch {
            std.log.debug("no loader.conf found on {s}, using defaults", .{disk_device});
            break :b .{};
        };
        defer file.close();

        std.log.debug("found loader.conf on {s}", .{disk_device});

        const contents = try file.readToEndAlloc(allocator, 4096);

        break :b LoaderConf.parse(contents);
    };

    self.loader_timeout = loader_conf.timeout;

    var it = entries_dir.iterate();
    while (try it.next()) |dir_entry| {
        if (dir_entry.kind != .file) {
            continue;
        }

        const bls_entry_file = BlsEntryFile.parse(dir_entry.name) catch |err| {
            std.log.err("invalid entry filename for {s}: {}", .{ dir_entry.name, err });
            continue;
        };

        if (bls_entry_file.tries_left) |tries_left| {
            if (tries_left == 0) {
                std.log.warn(
                    "skipping entry {s} because all tries have been exhausted",
                    .{dir_entry.name},
                );
                continue;
            }
        }

        var entry_file = entries_dir.openFile(dir_entry.name, .{}) catch continue;
        defer entry_file.close();

        std.log.debug("inspecting BLS entry {s} on {s}", .{ dir_entry.name, disk_device });

        // We should definitely not get any boot entry files larger than this.
        const entry_contents = try entry_file.readToEndAlloc(allocator, 1 << 16);
        var type1_entry = BlsEntry.parse(allocator, bls_entry_file, entry_contents) catch |err| {
            std.log.err("failed to parse {s} as BLS type 1 entry: {}", .{ dir_entry.name, err });
            continue;
        };
        errdefer type1_entry.deinit();

        try bls_entries.append(type1_entry);
    }

    std.log.debug("sorting BLS entries", .{});
    std.mem.sort(BlsEntry, bls_entries.items, loader_conf.default_entry, blsEntryLessThan);

    for (bls_entries.items) |entry| {
        const linux = mount_dir.realpathAlloc(allocator, entry.linux orelse {
            std.log.err("missing linux kernel in entry {s}", .{entry.id});
            continue;
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                std.log.err("linux kernel \"{?s}\" not found on {s}", .{ entry.linux, disk_device });
                continue;
            },
        };
        errdefer allocator.free(linux);

        // NOTE: Multiple initrds won't work if we have IMA appraisal
        // of signed initrds, so we can only load one.
        //
        // TODO(jared): If IMA appraisal is disabled, we can
        // concatenate all the initrds together.
        var initrd: ?[]const u8 = null;
        if (entry.initrd) |initrd_| {
            if (initrd_.len > 0) {
                initrd = mount_dir.realpathAlloc(allocator, initrd_[0]) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        std.log.err("initrd \"{s}\" not found on {s}", .{ initrd_[0], disk_device });
                        continue;
                    },
                };
            }

            if (initrd_.len > 1) {
                std.log.warn("cannot verify more than 1 initrd, using first initrd", .{});
            }
        }
        errdefer {
            if (initrd) |initrd_| {
                allocator.free(initrd_);
            }
        }

        const cmdline = b: {
            var final_cmdline = std.ArrayList(u8).init(allocator);

            if (entry.options) |opts| {
                for (opts) |opt| {
                    try final_cmdline.appendSlice(opt);
                    try final_cmdline.append(' ');
                }
            }

            try final_cmdline.writer().print("tboot.bls-entry={s}", .{entry.id});

            break :b try final_cmdline.toOwnedSlice();
        };

        errdefer allocator.free(cmdline);

        const context = try allocator.create(BlsEntryFile);
        errdefer allocator.destroy(context);

        context.* = BlsEntryFile.init(entry.id, .{
            .tries_left = entry.tries_left,
            .tries_done = entry.tries_done,
        });

        try entries.append(
            .{
                .context = context,
                .cmdline = cmdline,
                .initrd = initrd,
                .linux = linux,
            },
        );
    }
}

pub const BlsEntryFile = struct {
    name: []const u8,
    tries_left: ?u8 = null,
    tries_done: ?u8 = null,

    const Error = error{
        MissingSuffix,
        InvalidTriesSyntax,
    };

    pub fn toFilename(self: *const @This(), allocator: std.mem.Allocator) ![]const u8 {
        var filename = std.ArrayList(u8).init(allocator);

        try filename.appendSlice(self.name);

        if (self.tries_left) |tries_left| {
            try filename.append('+');
            try filename.append(
                std.fmt.digitToChar(tries_left, std.fmt.Case.lower),
            );
        }

        if (self.tries_done) |tries_done| {
            try filename.append('-');
            try filename.append(
                std.fmt.digitToChar(tries_done, std.fmt.Case.lower),
            );
        }

        try filename.appendSlice(".conf");

        return filename.toOwnedSlice();
    }

    pub fn init(entry_name: []const u8, opts: struct {
        tries_left: ?u8 = null,
        tries_done: ?u8 = null,
    }) @This() {
        return .{
            .name = entry_name,
            .tries_left = opts.tries_left,
            .tries_done = opts.tries_done,
        };
    }

    pub fn parse(filename: []const u8) !@This() {
        if (!std.mem.eql(u8, std.fs.path.extension(filename), ".conf")) {
            return Error.MissingSuffix;
        }

        const stem = std.fs.path.stem(filename);

        var plus_split = std.mem.splitSequence(u8, stem, "+");

        const entry_name = plus_split.next().?;

        if (plus_split.next()) |counter_info| {
            var minus_split = std.mem.splitSequence(u8, counter_info, "-");

            const plus_info = minus_split.next().?;
            const tries_left = std.fmt.parseInt(u8, plus_info, 10) catch {
                return Error.InvalidTriesSyntax;
            };

            if (minus_split.next()) |minus_info| {
                const tries_done = std.fmt.parseInt(u8, minus_info, 10) catch {
                    return Error.InvalidTriesSyntax;
                };
                return @This().init(entry_name, .{
                    .tries_left = tries_left,
                    .tries_done = tries_done,
                });
            } else {
                return @This().init(entry_name, .{
                    .tries_left = tries_left,
                });
            }
        } else {
            return @This().init(entry_name, .{});
        }
    }
};

test "entry filename parsing" {
    try std.testing.expectError(
        BlsEntryFile.Error.MissingSuffix,
        BlsEntryFile.parse("my-entry"),
    );

    try std.testing.expectError(
        BlsEntryFile.Error.InvalidTriesSyntax,
        BlsEntryFile.parse("my-entry+foo.conf"),
    );

    try std.testing.expectError(
        BlsEntryFile.Error.InvalidTriesSyntax,
        BlsEntryFile.parse("my-entry+foo-bar.conf"),
    );

    try std.testing.expectEqualDeep(
        BlsEntryFile.init("my-entry", .{}),
        BlsEntryFile.parse("my-entry.conf"),
    );

    try std.testing.expectEqualDeep(
        BlsEntryFile.init("my-entry-1", .{}),
        BlsEntryFile.parse("my-entry-1.conf"),
    );

    try std.testing.expectEqualDeep(
        BlsEntryFile.init("my-entry", .{ .tries_left = 1 }),
        BlsEntryFile.parse("my-entry+1.conf"),
    );

    try std.testing.expectEqualDeep(
        BlsEntryFile.init("my-entry", .{ .tries_left = 0 }),
        BlsEntryFile.parse("my-entry+0.conf"),
    );

    try std.testing.expectEqualDeep(
        BlsEntryFile.init("my-entry", .{ .tries_left = 0, .tries_done = 3 }),
        BlsEntryFile.parse("my-entry+0-3.conf"),
    );

    try std.testing.expectEqualDeep(
        BlsEntryFile.init("my-entry-1", .{ .tries_left = 5, .tries_done = 0 }),
        BlsEntryFile.parse("my-entry-1+5-0.conf"),
    );

    try std.testing.expectEqualDeep(
        BlsEntryFile.init("my-entry-2", .{ .tries_left = 3, .tries_done = 1 }),
        BlsEntryFile.parse("my-entry-2+3-1.conf"),
    );

    try std.testing.expectEqualDeep(
        BlsEntryFile.init("my-entry-3", .{ .tries_left = 2 }),
        BlsEntryFile.parse("my-entry-3+2.conf"),
    );
}

test "entry filename marshalling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    {
        var entry = BlsEntryFile.init("foo", .{
            .tries_left = null,
            .tries_done = null,
        });
        try std.testing.expectEqualStrings(
            entry.toFilename(arena.allocator()) catch unreachable,
            "foo.conf",
        );
    }

    {
        var entry = BlsEntryFile.init("foo", .{
            .tries_left = 1,
            .tries_done = null,
        });
        try std.testing.expectEqualStrings(
            entry.toFilename(arena.allocator()) catch unreachable,
            "foo+1.conf",
        );
    }

    {
        var entry = BlsEntryFile.init("foo", .{
            .tries_left = 1,
            .tries_done = 2,
        });
        try std.testing.expectEqualStrings(
            entry.toFilename(arena.allocator()) catch unreachable,
            "foo+1-2.conf",
        );
    }
}

const ConsoleMode = enum {
    Zero,
    One,
    Two,
    Auto,
    Max,
    Keep,

    fn parse(contents: []const u8) ?@This() {
        if (std.mem.eql(u8, contents, "0")) {
            return .Zero;
        } else if (std.mem.eql(u8, contents, "1")) {
            return .One;
        } else if (std.mem.eql(u8, contents, "2")) {
            return .Two;
        } else if (std.mem.eql(u8, contents, "auto")) {
            return .Auto;
        } else if (std.mem.eql(u8, contents, "max")) {
            return .Max;
        } else if (std.mem.eql(u8, contents, "keep")) {
            return .Keep;
        }
        return null;
    }
};

const SecureBootEnroll = enum {
    Off,
    Manual,
    IfSafe,
    Force,

    fn parse(contents: []const u8) ?@This() {
        if (std.mem.eql(u8, contents, "off")) {
            return .Off;
        } else if (std.mem.eql(u8, contents, "manual")) {
            return .Manual;
        } else if (std.mem.eql(u8, contents, "if-safe")) {
            return .IfSafe;
        } else if (std.mem.eql(u8, contents, "force")) {
            return .Force;
        }
        return null;
    }
};

/// Configuration of the BootLoaderSpec, as found in `loader.conf`. See
/// https://www.freedesktop.org/software/systemd/man/latest/loader.conf.html.
const LoaderConf = struct {
    /// Glob pattern used to find the default boot entry.
    default_entry: ?[]const u8 = null,

    /// Seconds to wait before selecting the default entry.
    timeout: u8 = 0,

    console_mode: ?ConsoleMode = null,

    /// Enable or disable editing boot entries.
    editor: bool = true,

    auto_entries: bool = true,

    auto_firmware: bool = true,

    beep: bool = false,

    secure_boot_enroll: ?SecureBootEnroll = null,

    reboot_for_bitlocker: bool = false,

    //  Boolean arguments may be written as:
    //  "yes"/"y"/"true"/"t"/"on"/"1" or "no"/"n"/"false"/"f"/"off"/"0"
    fn parseBool(contents: []const u8) ?bool {
        if (std.mem.eql(u8, contents, "yes")) {
            return true;
        } else if (std.mem.eql(u8, contents, "y")) {
            return true;
        } else if (std.mem.eql(u8, contents, "true")) {
            return true;
        } else if (std.mem.eql(u8, contents, "t")) {
            return true;
        } else if (std.mem.eql(u8, contents, "on")) {
            return true;
        } else if (std.mem.eql(u8, contents, "1")) {
            return true;
        } else if (std.mem.eql(u8, contents, "no")) {
            return false;
        } else if (std.mem.eql(u8, contents, "n")) {
            return false;
        } else if (std.mem.eql(u8, contents, "false")) {
            return false;
        } else if (std.mem.eql(u8, contents, "f")) {
            return false;
        } else if (std.mem.eql(u8, contents, "off")) {
            return false;
        } else if (std.mem.eql(u8, contents, "0")) {
            return false;
        }
        return null;
    }

    fn parse(contents: []const u8) @This() {
        var self = @This(){};

        var all_split = std.mem.splitSequence(u8, contents, "\n");

        while (all_split.next()) |line| {
            if (std.mem.eql(u8, line, "")) {
                continue;
            }

            var line_split = std.mem.splitSequence(u8, line, " ");

            var maybe_key: ?[]const u8 = null;
            var maybe_value: ?[]const u8 = null;

            while (line_split.next()) |section| {
                if (std.mem.eql(u8, section, "")) {
                    continue;
                }

                if (maybe_key == null) {
                    maybe_key = section;
                } else if (maybe_value == null) {
                    maybe_value = section;
                    break;
                }
            }

            if (maybe_key == null or maybe_value == null) {
                continue;
            }

            const key = maybe_key.?;
            const value = maybe_value.?;

            if (std.mem.eql(u8, key, "default")) {
                self.default_entry = value;
            } else if (std.mem.eql(u8, key, "timeout")) {
                self.timeout = std.fmt.parseInt(u8, value, 10) catch {
                    std.log.err("invalid timeout value \"{s}\"", .{value});
                    continue;
                };
            } else if (std.mem.eql(u8, key, "console-mode")) {
                if (ConsoleMode.parse(value)) |final_value| {
                    self.console_mode = final_value;
                }
            } else if (std.mem.eql(u8, key, "editor")) {
                if (@This().parseBool(value)) |final_value| {
                    self.editor = final_value;
                }
            } else if (std.mem.eql(u8, key, "auto-entries")) {
                if (@This().parseBool(value)) |final_value| {
                    self.auto_entries = final_value;
                }
            } else if (std.mem.eql(u8, key, "auto-firmware")) {
                if (@This().parseBool(value)) |final_value| {
                    self.auto_firmware = final_value;
                }
            } else if (std.mem.eql(u8, key, "beep")) {
                if (@This().parseBool(value)) |final_value| {
                    self.beep = final_value;
                }
            } else if (std.mem.eql(u8, key, "secure-boot-enroll")) {
                if (SecureBootEnroll.parse(value)) |final_value| {
                    self.secure_boot_enroll = final_value;
                }
            } else if (std.mem.eql(u8, key, "reboot-for-bitlocker")) {
                if (@This().parseBool(value)) |final_value| {
                    self.reboot_for_bitlocker = final_value;
                }
            }
        }

        return self;
    }
};

test "loader.conf parsing" {
    const simple =
        \\timeout 0
        \\default 01234567890abcdef1234567890abdf0-*
        \\editor no
    ;

    try std.testing.expectEqualDeep(LoaderConf{
        .timeout = 0,
        .default_entry = "01234567890abcdef1234567890abdf0-*",
        .editor = false,
    }, LoaderConf.parse(simple));

    const deformed =
        \\timeout
        \\
        \\default
        \\editor
    ;

    // Ensures that even with bad output, we just get back a LoaderConf with
    // the default values.
    try std.testing.expectEqualDeep(LoaderConf{}, LoaderConf.parse(deformed));
}

const Architecture = enum {
    ia32,
    x64,
    arm,
    aa64,
    riscv32,
    riscv64,
    loongarch32,
    loongarch64,

    const Error = error{InvalidArchitecture};

    pub fn parse(arch: []const u8) Error!@This() {
        return if (std.mem.eql(u8, arch, "ia32"))
            .ia32
        else if (std.mem.eql(u8, arch, "x64"))
            .x64
        else if (std.mem.eql(u8, arch, "arm"))
            .arm
        else if (std.mem.eql(u8, arch, "aa64"))
            .aa64
        else if (std.mem.eql(u8, arch, "riscv32"))
            .riscv32
        else if (std.mem.eql(u8, arch, "riscv64"))
            .riscv64
        else if (std.mem.eql(u8, arch, "loongarch32"))
            .loongarch32
        else if (std.mem.eql(u8, arch, "loongarch64"))
            .loongarch64
        else
            Error.InvalidArchitecture;
    }
};

/// Configuration of the type #1 boot entry as defined in
/// https://uapi-group.org/specifications/specs/boot_loader_specification/#type-1-boot-loader-specification-entries.
const BlsEntry = struct {
    allocator: std.mem.Allocator,

    /// `id` is derived from the filename
    id: []const u8,
    /// `tries_left` is derived from the filename
    tries_left: ?u8 = null,
    /// `tries_done` is derived from the filename
    tries_done: ?u8 = null,

    title: ?[]const u8 = null,
    version: ?[]const u8 = null,
    machine_id: ?[]const u8 = null,
    sort_key: ?[]const u8 = null,
    linux: ?[]const u8 = null,
    initrd: ?[]const []const u8 = null,
    efi: ?[]const u8 = null,
    options: ?[]const []const u8 = null,
    devicetree: ?[]const u8 = null,
    devicetree_overlay: ?[]const []const u8 = null,
    architecture: ?Architecture = null,

    // Ensures all path options have their leading forward-slash trimmed so
    // that the paths can be used directly with the ESP mountpoint's std.fs.Dir
    // instance.
    pub fn parse(allocator: std.mem.Allocator, file: BlsEntryFile, contents: []const u8) !@This() {
        const id = try allocator.dupe(u8, file.name);
        errdefer allocator.free(id);

        var self = @This(){
            .allocator = allocator,
            .id = id,
            .tries_left = file.tries_left,
            .tries_done = file.tries_done,
        };

        var all_split = std.mem.splitSequence(u8, contents, "\n");

        var initrd = std.ArrayList([]const u8).init(allocator);
        errdefer initrd.deinit();

        var options = std.ArrayList([]const u8).init(allocator);
        errdefer options.deinit();

        while (all_split.next()) |unprocessed_line| {
            if (std.mem.eql(u8, unprocessed_line, "")) {
                continue;
            }

            const line_without_tabs = try self.allocator.dupe(u8, unprocessed_line);
            defer self.allocator.free(line_without_tabs);
            const num_replacements = std.mem.replace(u8, unprocessed_line, "\t", " ", line_without_tabs);
            _ = num_replacements;
            const line = std.mem.collapseRepeats(u8, line_without_tabs, ' ');
            var line_split = std.mem.splitSequence(u8, std.mem.trim(u8, line, " "), " ");

            const key = line_split.next() orelse continue;

            if (std.mem.eql(u8, key, "title")) {
                self.title = try self.allocator.dupe(u8, line_split.rest());
            } else if (std.mem.eql(u8, key, "version")) {
                self.version = try self.allocator.dupe(u8, line_split.rest());
            } else if (std.mem.eql(u8, key, "machine-id")) {
                self.machine_id = try self.allocator.dupe(u8, line_split.rest());
            } else if (std.mem.eql(u8, key, "sort_key")) {
                self.sort_key = try self.allocator.dupe(u8, line_split.rest());
            } else if (std.mem.eql(u8, key, "linux")) {
                self.linux = try self.allocator.dupe(u8, std.mem.trimLeft(u8, line_split.rest(), "/"));
            } else if (std.mem.eql(u8, key, "initrd")) {
                try initrd.append(try self.allocator.dupe(u8, std.mem.trimLeft(u8, line_split.rest(), "/")));
            } else if (std.mem.eql(u8, key, "efi")) {
                self.efi = try self.allocator.dupe(u8, std.mem.trimLeft(u8, line_split.rest(), "/"));
            } else if (std.mem.eql(u8, key, "options")) {
                while (line_split.next()) |next| {
                    try options.append(try self.allocator.dupe(u8, next));
                }
            } else if (std.mem.eql(u8, key, "devicetree")) {
                self.devicetree = try self.allocator.dupe(u8, std.mem.trimLeft(u8, line_split.rest(), "/"));
            } else if (std.mem.eql(u8, key, "devicetree-overlay")) {
                var devicetree_overlay = std.ArrayList([]const u8).init(allocator);
                errdefer devicetree_overlay.deinit();
                while (line_split.next()) |next| {
                    try devicetree_overlay.append(try self.allocator.dupe(u8, std.mem.trimLeft(u8, next, "/")));
                }
                self.devicetree_overlay = try devicetree_overlay.toOwnedSlice();
            } else if (std.mem.eql(u8, key, "architecture")) {
                self.architecture = Architecture.parse(line_split.rest()) catch continue;
            }
        }

        if (initrd.items.len > 0) {
            self.initrd = try initrd.toOwnedSlice();
        }

        if (options.items.len > 0) {
            self.options = try options.toOwnedSlice();
        }

        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.id);

        if (self.initrd) |initrd| {
            defer self.allocator.free(initrd);
            for (initrd) |initrd_| {
                self.allocator.free(initrd_);
            }
        }

        if (self.options) |options| {
            defer self.allocator.free(options);
            for (options) |option| {
                self.allocator.free(option);
            }
        }

        if (self.devicetree_overlay) |dt_overlay| {
            defer self.allocator.free(dt_overlay);
            for (dt_overlay) |dt| {
                self.allocator.free(dt);
            }
        }

        if (self.linux) |linux| {
            self.allocator.free(linux);
        }

        if (self.title) |title| {
            self.allocator.free(title);
        }

        if (self.version) |version| {
            self.allocator.free(version);
        }

        if (self.machine_id) |machine_id| {
            self.allocator.free(machine_id);
        }

        if (self.sort_key) |sort_key| {
            self.allocator.free(sort_key);
        }

        if (self.efi) |efi| {
            self.allocator.free(efi);
        }
    }
};

test "type 1 boot entry parsing" {
    {
        const simple =
            \\title Foo
            \\linux /EFI/foo/Image
            \\options console=ttyAMA0 loglevel=7
            \\architecture aa64
        ;

        var type1_entry = try BlsEntry.parse(
            std.testing.allocator,
            .{ .name = "foo" },
            simple,
        );
        defer type1_entry.deinit();

        try std.testing.expectEqualStrings("EFI/foo/Image", type1_entry.linux.?);
        try std.testing.expect(type1_entry.options.?.len == 2);
        try std.testing.expectEqualStrings("console=ttyAMA0", type1_entry.options.?[0]);
        try std.testing.expectEqualStrings("loglevel=7", type1_entry.options.?[1]);
    }
    {
        const weird_formatting =
            \\title       Foo
            \\linux      /EFI/foo/Image
            \\options                   console=ttyAMA0 loglevel=7
            \\architecture  aa64
        ;

        var type1_entry = try BlsEntry.parse(
            std.testing.allocator,
            .{ .name = "foo" },
            weird_formatting,
        );
        defer type1_entry.deinit();

        try std.testing.expectEqualStrings("EFI/foo/Image", type1_entry.linux.?);
        try std.testing.expect(type1_entry.options.?.len == 2);
        try std.testing.expectEqualStrings("console=ttyAMA0", type1_entry.options.?[0]);
        try std.testing.expectEqualStrings("loglevel=7", type1_entry.options.?[1]);
    }
}
