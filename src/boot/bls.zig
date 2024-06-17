const std = @import("std");
const posix = std.posix;
const system = std.posix.system;

const linux_headers = @import("linux_headers");

const BootDevice = @import("../boot.zig").BootDevice;
const BootEntry = @import("../boot.zig").BootEntry;
const FsType = @import("../disk/filesystem.zig").FsType;
const Gpt = @import("../disk/partition_table.zig").Gpt;
const GptPartitionType = @import("../disk/partition_table.zig").GptPartitionType;
const Mbr = @import("../disk/partition_table.zig").Mbr;
const MbrPartitionType = @import("../disk/partition_table.zig").MbrPartitionType;
const device = @import("../device.zig");

const Mount = struct {
    dir: *std.fs.Dir,
    disk_name: []const u8,
};

fn diskIsRemovable(allocator: std.mem.Allocator, devname: []const u8) bool {
    const removable_path = std.fs.path.join(allocator, &.{
        std.fs.path.sep_str,
        "sys",
        "class",
        "block",
        devname,
        "removable",
    }) catch return false;
    defer allocator.free(removable_path);

    const removable_file = std.fs.openFileAbsolute(removable_path, .{}) catch return false;
    defer removable_file.close();

    var buf: [1]u8 = undefined;
    if ((removable_file.read(&buf) catch return false) != 1) {
        return false;
    }

    return std.mem.eql(u8, &buf, "1");
}

/// Caller is responsible for the returned value.
fn diskName(allocator: std.mem.Allocator, devname: []const u8) ![]const u8 {
    var name = std.ArrayList(u8).init(allocator);

    const vendor = b: {
        const path = std.fs.path.join(allocator, &.{
            std.fs.path.sep_str,
            "sys",
            "class",
            "block",
            devname,
            "device",
            "vendor",
        }) catch break :b null;
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch break :b null;
        defer file.close();

        var buf: [1024]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch break :b null;
        break :b std.mem.trim(u8, buf[0..bytes_read], "\n ");
    };

    const model = b: {
        const path = std.fs.path.join(allocator, &.{
            std.fs.path.sep_str,
            "sys",
            "class",
            "block",
            devname,
            "device",
            "model",
        }) catch break :b null;
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch break :b null;
        defer file.close();

        var buf: [1024]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch break :b null;
        break :b std.mem.trim(u8, buf[0..bytes_read], "\n ");
    };

    if (vendor) |_vendor| {
        try name.appendSlice(_vendor);
    }

    if (model) |_model| {
        if (vendor != null) {
            try name.append(' ');
        }
        try name.appendSlice(_model);
    }

    return name.toOwnedSlice();
}

pub const BootLoaderSpec = struct {
    const EntryContext = struct {
        full_path: []const u8,
    };

    arena: std.heap.ArenaAllocator,

    /// Mounts to block devices that are non-removable (i.e. "internal" to the
    /// system).
    internal_mounts: []Mount,

    /// Mounts to block devices that are removable (i.e. "external" to the
    /// system). This includes USB mass-storage devices, SD cards, etc.
    external_mounts: []Mount,

    pub fn init() @This() {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .internal_mounts = &.{},
            .external_mounts = &.{},
        };
    }

    pub fn setup(self: *@This()) !void {
        std.log.debug("BLS setup", .{});

        const allocator = self.arena.allocator();

        var internal_mounts = std.ArrayList(Mount).init(allocator);
        var external_mounts = std.ArrayList(Mount).init(allocator);

        var dev_disk_alias = try std.fs.cwd().openDir(
            "/dev/disk",
            .{},
        );
        defer dev_disk_alias.close();

        var mountpoint_dir = try std.fs.cwd().openDir(
            "/mnt",
            .{},
        );
        defer mountpoint_dir.close();

        var sysfs_block = try std.fs.cwd().openDir(
            "/sys/class/block",
            .{ .iterate = true },
        );
        defer sysfs_block.close();
        var it = sysfs_block.iterate();

        while (try it.next()) |entry| {
            if (entry.kind != .sym_link) {
                continue;
            }

            const uevent_path = try std.fs.path.join(allocator, &.{ entry.name, "uevent" });
            var uevent_file = try sysfs_block.openFile(uevent_path, .{});
            defer uevent_file.close();

            const max_bytes = 10 * 1024 * 1024;
            const uevent_contents = try uevent_file.readToEndAlloc(allocator, max_bytes);

            var uevent = try device.parseUeventFileContents(allocator, uevent_contents);

            const devtype = uevent.get("DEVTYPE") orelse continue;

            std.log.debug(
                "inspecting block device {s} ({s})",
                .{ entry.name, devtype },
            );

            if (!std.mem.eql(u8, devtype, "disk")) {
                continue;
            }

            const diskseq = uevent.get("DISKSEQ") orelse continue;
            const devname = uevent.get("DEVNAME") orelse continue;

            const disk_handle = dev_disk_alias.openFile(
                try std.fmt.allocPrint(allocator, "disk{s}", .{diskseq}),
                .{},
            ) catch |err| {
                std.log.err(
                    "failed to open disk alias for {s}: {}",
                    .{ entry.name, err },
                );
                continue;
            };

            var disk_source = std.io.StreamSource{ .file = disk_handle };

            // All GPTs also have an MBR, so we can invalidate the disk
            // entirely if it does not have an MBR.
            var mbr = Mbr.init(&disk_source) catch |err| {
                std.log.err("no MBR found on disk {s}: {}", .{ devname, err });
                continue;
            };

            const boot_partn = b: {
                for (mbr.partitions(), 1..) |part, mbr_partn| {
                    const part_type = MbrPartitionType.fromValue(part.partType()) orelse continue;

                    if (part.isBootable() and
                        // BootLoaderSpec uses this partition type for MBR, see
                        // https://uapi-group.org/specifications/specs/boot_loader_specification/#the-partitionsl.
                        (part_type == .LinuxExtendedBoot or
                        // QEMU uses this partition type when using a FAT
                        // emulated drive with `-drive file=fat:rw:some/directory`.
                        part_type == .Fat16))
                    {
                        break :b mbr_partn;
                    }

                    // disk is GPT partitioned
                    if (!part.isBootable() and part_type == .ProtectedMbr) {
                        var gpt = Gpt.init(&disk_source) catch |err| switch (err) {
                            Gpt.Error.MissingMagicNumber => {
                                std.log.debug("disk {s} does not contain a GUID partition table", .{devname});
                                continue;
                            },
                            Gpt.Error.HeaderCrcFail => {
                                std.log.err("disk {s} CRC integrity check failed", .{devname});
                                continue;
                            },
                            else => {
                                std.log.err("failed to read disk {s}: {}", .{ devname, err });
                                continue;
                            },
                        };

                        const partitions = try gpt.partitions(allocator);
                        for (partitions, 1..) |partition, gpt_partn| {
                            if (partition.partType() orelse continue == .EfiSystem) {
                                break :b gpt_partn;
                            }
                        }
                    }
                }

                continue;
            };

            const partition_filename = try std.fmt.allocPrint(
                allocator,
                "disk{s}_part{d}",
                .{ diskseq, boot_partn },
            );

            std.log.info("found boot partition on disk {s} partition {d}", .{ devname, boot_partn });

            var esp_handle = try dev_disk_alias.openFile(partition_filename, .{});
            defer esp_handle.close();

            var esp_file_source = std.io.StreamSource{ .file = esp_handle };
            const fstype = try FsType.detect(&esp_file_source) orelse {
                std.log.err("could not detect filesystem on EFI system partition", .{});
                continue;
            };

            mountpoint_dir.makePath(partition_filename) catch |err| {
                std.log.err("failed to create mountpoint: {}", .{err});
                continue;
            };

            const mountpoint = try mountpoint_dir.realpathAlloc(allocator, partition_filename);

            switch (posix.errno(system.mount(
                try allocator.dupeZ(u8, try dev_disk_alias.realpathAlloc(allocator, partition_filename)),
                try allocator.dupeZ(u8, mountpoint),
                switch (fstype) {
                    .Vfat => "vfat",
                },
                system.MS.NOSUID | system.MS.NODEV | system.MS.NOEXEC,
                0,
            ))) {
                .SUCCESS => {},
                else => |err| {
                    std.log.err("failed to mount disk {s} partition {d}: {}", .{ devname, boot_partn, err });
                    continue;
                },
            }

            std.log.info("mounted disk \"{s}\"", .{devname});

            const dir = try allocator.create(std.fs.Dir);
            dir.* = try mountpoint_dir.openDir(partition_filename, .{});

            const mount = Mount{
                .disk_name = try diskName(allocator, devname),
                .dir = dir,
            };

            if (diskIsRemovable(allocator, devname)) {
                try external_mounts.append(mount);
            } else {
                try internal_mounts.append(mount);
            }
        }

        self.internal_mounts = try internal_mounts.toOwnedSlice();
        self.external_mounts = try external_mounts.toOwnedSlice();
    }

    fn searchForEntries(
        self: *@This(),
        mount: Mount,
        tmp_allocator: std.mem.Allocator,
        final_allocator: std.mem.Allocator,
    ) !BootDevice {
        _ = self;

        var entries = std.ArrayList(BootEntry).init(final_allocator);
        errdefer entries.deinit();

        const loader_conf: LoaderConf = b: {
            var file = mount.dir.openFile("loader/loader.conf", .{}) catch {
                std.log.debug("no loader.conf found on {s}, using defaults", .{mount.disk_name});
                break :b .{};
            };
            defer file.close();
            std.log.debug("found loader.conf on \"{s}\"", .{mount.disk_name});
            const contents = try file.readToEndAlloc(tmp_allocator, 4096);
            break :b LoaderConf.parse(contents);
        };

        var entries_dir = try mount.dir.openDir(
            "loader/entries",
            .{ .iterate = true },
        );
        defer entries_dir.close();

        var it = entries_dir.iterate();
        while (try it.next()) |dir_entry| {
            if (dir_entry.kind != .file) {
                continue;
            }

            var entry_filename = EntryFilename.parse(tmp_allocator, dir_entry.name) catch |err| {
                std.log.err("invalid entry filename for {s}: {}", .{ dir_entry.name, err });
                continue;
            };
            defer entry_filename.deinit();

            if (entry_filename.tries_left) |tries_left| {
                if (tries_left == 0) {
                    std.log.warn(
                        "skipping entry {s} because all tries have been exhausted",
                        .{dir_entry.name},
                    );
                    continue;
                }
            }

            var entry_file = entries_dir.openFile(dir_entry.name, .{}) catch continue;

            std.log.debug("inspecting BLS entry {s} on \"{s}\"", .{ dir_entry.name, mount.disk_name });

            // We should definitely not get any boot entry files larger than this.
            const entry_contents = try entry_file.readToEndAlloc(tmp_allocator, 1 << 16);
            var type1_entry = Type1Entry.parse(tmp_allocator, entry_contents) catch |err| {
                std.log.err("failed to parse {s} as BLS type 1 entry: {}", .{ dir_entry.name, err });
                continue;
            };
            defer type1_entry.deinit();

            const linux = try mount.dir.realpathAlloc(final_allocator, type1_entry.linux orelse {
                std.log.err("missing linux kernel in {s}", .{dir_entry.name});
                continue;
            });
            errdefer final_allocator.free(linux);

            // NOTE: Multiple initrds won't work if we have IMA appraisal
            // of signed initrds, so we can only load one.
            //
            // TODO(jared): If IMA appraisal is disabled, we can
            // concatenate all the initrds together.
            var initrd: ?[]const u8 = null;
            if (type1_entry.initrd) |_initrd| {
                if (_initrd.len > 0) {
                    initrd = try mount.dir.realpathAlloc(final_allocator, _initrd[0]);
                }

                if (_initrd.len > 1) {
                    std.log.warn("cannot verify more than 1 initrd, using first initrd", .{});
                }
            }
            errdefer {
                if (initrd) |_initrd| {
                    final_allocator.free(_initrd);
                }
            }

            var options_with_bls_entry: [linux_headers.COMMAND_LINE_SIZE]u8 = undefined;
            const options = b: {
                if (type1_entry.options) |opts| {
                    const orig = try std.mem.join(tmp_allocator, " ", opts);
                    break :b try std.fmt.bufPrint(&options_with_bls_entry, "{s} tboot.bls-entry={s}", .{ orig, entry_filename.name });
                } else {
                    break :b try std.fmt.bufPrint(&options_with_bls_entry, "tboot.bls-entry={s}", .{entry_filename.name});
                }
            };

            const final_options = try final_allocator.dupe(u8, options);
            errdefer final_allocator.free(options);

            const context = try final_allocator.create(EntryContext);
            errdefer final_allocator.destroy(context);
            context.* = .{
                .full_path = try entries_dir.realpathAlloc(final_allocator, dir_entry.name),
            };

            try entries.append(
                .{
                    .context = context,
                    .cmdline = final_options,
                    .initrd = initrd,
                    .linux = linux,
                },
            );
        }

        return .{
            .name = try final_allocator.dupe(u8, mount.disk_name),
            .timeout = loader_conf.timeout,
            .entries = try entries.toOwnedSlice(),
        };
    }

    /// Caller is responsible for the returned slice.
    pub fn probe(self: *@This(), allocator: std.mem.Allocator) ![]const BootDevice {
        // A temporary allocator for stuff not saved after the probe and not
        // included in the return value.
        var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer tmp_arena.deinit();

        std.log.debug("BLS probe start", .{});
        var devices = std.ArrayList(BootDevice).init(allocator);

        // Mounts of external devices are ordered before external mounts so
        // they are prioritized in the boot process.
        std.log.debug("BLS probe found {} external device(s)", .{self.external_mounts.len});
        for (self.external_mounts) |mount| {
            try devices.append(self.searchForEntries(
                mount,
                tmp_arena.allocator(),
                allocator,
            ) catch |err| {
                std.log.err(
                    "failed to search for entries on \"{s}\": {}",
                    .{ mount.disk_name, err },
                );
                continue;
            });
        }

        std.log.debug("BLS probe found {} internal device(s)", .{self.internal_mounts.len});
        for (self.internal_mounts) |mount| {
            try devices.append(self.searchForEntries(
                mount,
                tmp_arena.allocator(),
                allocator,
            ) catch |err| {
                std.log.err(
                    "failed to search for entries on \"{s}\": {}",
                    .{ mount.disk_name, err },
                );
                continue;
            });
        }

        std.log.debug(
            "BLS probe found {} device(s) with BLS entries",
            .{devices.items.len},
        );
        return try devices.toOwnedSlice();
    }

    pub fn entryLoaded(self: *@This(), ctx: *anyopaque) void {
        self._entryLoaded(ctx) catch |err| {
            std.log.err(
                "failed to finalize BLS boot counter for chosen entry: {}",
                .{err},
            );
        };
    }

    fn _entryLoaded(self: *@This(), ctx: *anyopaque) !void {
        const context: *EntryContext = @ptrCast(@alignCast(ctx));

        const dirname = std.fs.path.dirname(context.full_path) orelse return;
        const original_name = std.fs.path.basename(context.full_path);
        var entry = try EntryFilename.parse(self.arena.allocator(), original_name);

        if (entry.tries_done) |*done| done.* +|= 1;
        if (entry.tries_left) |*left| left.* -|= 1;

        if (entry.tries_left) |tries_left| {
            std.log.info(
                "{} {s} remaining for entry \"{s}\"",
                .{
                    tries_left,
                    if (tries_left == 1) "try" else "tries",
                    entry.name,
                },
            );
        }

        const new_name = try entry.toFilename(self.arena.allocator());

        if (!std.mem.eql(u8, original_name, new_name)) {
            var dir = try std.fs.cwd().openDir(dirname, .{});
            defer dir.close();

            try dir.rename(original_name, new_name);
            posix.sync();

            std.log.debug("entry renamed to {s}", .{new_name});
        }
    }

    pub fn teardown(self: *@This()) !void {
        std.log.debug("BLS teardown", .{});

        defer self.arena.deinit();

        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

        for (self.external_mounts) |mount| {
            std.log.info("unmounted disk \"{s}\"", .{mount.disk_name});
            _ = system.umount2(
                try self.arena.allocator().dupeZ(u8, try mount.dir.realpath(".", &buf)),
                system.MNT.DETACH,
            );
            mount.dir.close();
        }

        for (self.internal_mounts) |mount| {
            std.log.info("unmounted disk \"{s}\"", .{mount.disk_name});
            _ = system.umount2(
                try self.arena.allocator().dupeZ(u8, try mount.dir.realpath(".", &buf)),
                system.MNT.DETACH,
            );
            mount.dir.close();
        }
    }
};

pub const EntryFilename = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    tries_left: ?u8 = null,
    tries_done: ?u8 = null,

    const Error = error{
        MissingSuffix,
        InvalidTriesSyntax,
    };

    pub fn toFilename(self: *@This(), allocator: std.mem.Allocator) ![]const u8 {
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

    pub fn init(allocator: std.mem.Allocator, name: []const u8, opts: struct {
        tries_left: ?u8 = null,
        tries_done: ?u8 = null,
    }) !@This() {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .tries_left = opts.tries_left,
            .tries_done = opts.tries_done,
        };
    }

    pub fn parse(allocator: std.mem.Allocator, filename: []const u8) !@This() {
        if (!std.mem.eql(u8, std.fs.path.extension(filename), ".conf")) {
            return Error.MissingSuffix;
        }

        const stem = std.fs.path.stem(filename);

        var plus_split = std.mem.splitSequence(u8, stem, "+");

        const name = plus_split.next().?;

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
                return @This().init(allocator, name, .{
                    .tries_left = tries_left,
                    .tries_done = tries_done,
                });
            } else {
                return @This().init(allocator, name, .{
                    .tries_left = tries_left,
                });
            }
        } else {
            return @This().init(allocator, name, .{});
        }
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.name);
    }
};

test "entry filename parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(
        EntryFilename.Error.MissingSuffix,
        EntryFilename.parse(allocator, "my-entry"),
    );

    try std.testing.expectError(
        EntryFilename.Error.InvalidTriesSyntax,
        EntryFilename.parse(allocator, "my-entry+foo.conf"),
    );

    try std.testing.expectError(
        EntryFilename.Error.InvalidTriesSyntax,
        EntryFilename.parse(allocator, "my-entry+foo-bar.conf"),
    );

    try std.testing.expectEqualDeep(
        EntryFilename.init(allocator, "my-entry", .{}),
        EntryFilename.parse(allocator, "my-entry.conf"),
    );

    try std.testing.expectEqualDeep(
        EntryFilename.init(allocator, "my-entry-1", .{}),
        EntryFilename.parse(allocator, "my-entry-1.conf"),
    );

    try std.testing.expectEqualDeep(
        EntryFilename.init(allocator, "my-entry", .{ .tries_left = 1 }),
        EntryFilename.parse(allocator, "my-entry+1.conf"),
    );

    try std.testing.expectEqualDeep(
        EntryFilename.init(allocator, "my-entry", .{ .tries_left = 0 }),
        EntryFilename.parse(allocator, "my-entry+0.conf"),
    );

    try std.testing.expectEqualDeep(
        EntryFilename.init(allocator, "my-entry", .{ .tries_left = 0, .tries_done = 3 }),
        EntryFilename.parse(allocator, "my-entry+0-3.conf"),
    );

    try std.testing.expectEqualDeep(
        EntryFilename.init(allocator, "my-entry-1", .{ .tries_left = 5, .tries_done = 0 }),
        EntryFilename.parse(allocator, "my-entry-1+5-0.conf"),
    );

    try std.testing.expectEqualDeep(
        EntryFilename.init(allocator, "my-entry-2", .{ .tries_left = 3, .tries_done = 1 }),
        EntryFilename.parse(allocator, "my-entry-2+3-1.conf"),
    );

    try std.testing.expectEqualDeep(
        EntryFilename.init(allocator, "my-entry-3", .{ .tries_left = 2 }),
        EntryFilename.parse(allocator, "my-entry-3+2.conf"),
    );
}

test "entry filename marshalling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    {
        var entry = EntryFilename.init(arena.allocator(), "foo", .{
            .tries_left = null,
            .tries_done = null,
        }) catch unreachable;
        try std.testing.expectEqualStrings(
            entry.toFilename(arena.allocator()) catch unreachable,
            "foo.conf",
        );
    }

    {
        var entry = EntryFilename.init(arena.allocator(), "foo", .{
            .tries_left = 1,
            .tries_done = null,
        }) catch unreachable;
        try std.testing.expectEqualStrings(
            entry.toFilename(arena.allocator()) catch unreachable,
            "foo+1.conf",
        );
    }

    {
        var entry = EntryFilename.init(arena.allocator(), "foo", .{
            .tries_left = 1,
            .tries_done = 2,
        }) catch unreachable;
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
const Type1Entry = struct {
    allocator: std.mem.Allocator,

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
    pub fn parse(allocator: std.mem.Allocator, contents: []const u8) !@This() {
        var self = @This(){
            .allocator = allocator,
        };

        var all_split = std.mem.splitSequence(u8, contents, "\n");

        var initrd = std.ArrayList([]const u8).init(allocator);
        errdefer initrd.deinit();

        var options = std.ArrayList([]const u8).init(allocator);
        errdefer options.deinit();

        while (all_split.next()) |line| {
            if (std.mem.eql(u8, line, "")) {
                continue;
            }

            var line_split = std.mem.splitSequence(u8, line, " ");

            const key = line_split.next() orelse continue;

            if (std.mem.eql(u8, key, "title")) {
                self.title = line_split.rest();
            } else if (std.mem.eql(u8, key, "version")) {
                self.version = line_split.rest();
            } else if (std.mem.eql(u8, key, "machine-id")) {
                self.machine_id = line_split.rest();
            } else if (std.mem.eql(u8, key, "sort_key")) {
                self.sort_key = line_split.rest();
            } else if (std.mem.eql(u8, key, "linux")) {
                self.linux = std.mem.trimLeft(u8, line_split.rest(), "/");
            } else if (std.mem.eql(u8, key, "initrd")) {
                try initrd.append(std.mem.trimLeft(u8, line_split.rest(), "/"));
            } else if (std.mem.eql(u8, key, "efi")) {
                self.efi = std.mem.trimLeft(u8, line_split.rest(), "/");
            } else if (std.mem.eql(u8, key, "options")) {
                while (line_split.next()) |next| {
                    try options.append(next);
                }
            } else if (std.mem.eql(u8, key, "devicetree")) {
                self.devicetree = std.mem.trimLeft(u8, line_split.rest(), "/");
            } else if (std.mem.eql(u8, key, "devicetree-overlay")) {
                var devicetree_overlay = std.ArrayList([]const u8).init(allocator);
                errdefer devicetree_overlay.deinit();
                while (line_split.next()) |next| {
                    try devicetree_overlay.append(std.mem.trimLeft(u8, next, "/"));
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
        if (self.initrd) |initrd| {
            self.allocator.free(initrd);
        }
        if (self.options) |options| {
            self.allocator.free(options);
        }
        if (self.devicetree_overlay) |dt_overlay| {
            self.allocator.free(dt_overlay);
        }
    }
};

test "type 1 boot entry parsing" {
    const simple =
        \\title Foo
        \\linux /EFI/foo/Image
        \\options console=ttyAMA0 loglevel=7
        \\architecture aa64
    ;

    var type1_entry = try Type1Entry.parse(std.testing.allocator, simple);
    defer type1_entry.deinit();

    try std.testing.expectEqualStrings("EFI/foo/Image", type1_entry.linux.?);
    try std.testing.expect(type1_entry.options.?.len == 2);
    try std.testing.expectEqualStrings("console=ttyAMA0", type1_entry.options.?[0]);
    try std.testing.expectEqualStrings("loglevel=7", type1_entry.options.?[1]);
}
