const std = @import("std");
const os = std.os;

const BootDevice = @import("../boot.zig").BootDevice;
const BootEntry = @import("../boot.zig").BootEntry;
const FsType = @import("../disk/filesystem.zig").FsType;
const Gpt = @import("../disk/partition_table.zig").Gpt;
const GptPartitionType = @import("../disk/partition_table.zig").GptPartitionType;
const Mbr = @import("../disk/partition_table.zig").Mbr;
const MbrPartitionType = @import("../disk/partition_table.zig").MbrPartitionType;
const device = @import("../device.zig");

const Mount = struct {
    mountpoint: [:0]const u8,
    disk_name: []const u8,
};

fn disk_is_removable(allocator: std.mem.Allocator, devname: []const u8) bool {
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

const fallback_vendor = "unknown vendor";
const fallback_model = "unknown model";

/// Caller is responsible for the returned value.
fn disk_name(allocator: std.mem.Allocator, devname: []const u8) ![]const u8 {
    const vendor = b: {
        const path = std.fs.path.join(allocator, &.{
            std.fs.path.sep_str,
            "sys",
            "class",
            "block",
            devname,
            "device",
            "vendor",
        }) catch break :b fallback_vendor;
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch break :b fallback_vendor;
        defer file.close();

        var buf: [1024]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch break :b fallback_vendor;
        break :b std.mem.trim(u8, buf[0..bytes_read], "\n");
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
        }) catch break :b fallback_model;
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch break :b fallback_model;
        defer file.close();

        var buf: [1024]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch break :b fallback_model;
        break :b std.mem.trim(u8, buf[0..bytes_read], "\n");
    };

    return std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ devname, vendor, model });
}

pub const BootLoaderSpec = struct {
    arena: std.heap.ArenaAllocator,

    /// Mounts to block devices that are non-removable (i.e. "internal" to the
    /// system).
    internal_mounts: []Mount,

    /// Mounts to block devices that are removable (i.e. "external" to the
    /// system). This includes USB mass-storage devices, SD cards, etc.
    external_mounts: []Mount,

    pub fn init(backing_allocator: std.mem.Allocator) @This() {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .internal_mounts = &.{},
            .external_mounts = &.{},
        };
    }

    pub fn setup(self: *@This()) !void {
        std.log.debug("BLS setup", .{});

        const allocator = self.arena.allocator();

        var internal_mounts = std.ArrayList(Mount).init(allocator);
        var external_mounts = std.ArrayList(Mount).init(allocator);

        var sysfs_block = try std.fs.openIterableDirAbsolute(
            "/sys/class/block",
            .{},
        );
        defer sysfs_block.close();
        var it = sysfs_block.iterate();

        while (try it.next()) |entry| {
            if (entry.kind != .sym_link) {
                continue;
            }

            const full_path = try std.fs.path.join(allocator, &.{
                std.fs.path.sep_str,
                "sys",
                "class",
                "block",
                entry.name,
                "uevent",
            });
            var uevent_path = try std.fs.openFileAbsolute(full_path, .{});
            defer uevent_path.close();

            const max_bytes = 10 * 1024 * 1024;
            const uevent_contents = try uevent_path.readToEndAlloc(allocator, max_bytes);

            var uevent = try device.parseUeventFileContents(allocator, uevent_contents);

            const devtype = uevent.get("DEVTYPE") orelse continue;

            if (!std.mem.eql(u8, devtype, "disk")) {
                continue;
            }

            const diskseq = uevent.get("DISKSEQ") orelse continue;
            const devname = uevent.get("DEVNAME") orelse continue;

            const disk_alias_path = try std.fs.path.join(
                allocator,
                &.{
                    std.fs.path.sep_str,
                    "dev",
                    "disk",
                    try std.fmt.allocPrint(allocator, "disk{s}", .{diskseq}),
                },
            );

            const disk_handle = std.fs.openFileAbsolute(disk_alias_path, .{}) catch continue;
            var disk_source = std.io.StreamSource{ .file = disk_handle };

            // All GPTs also have an MBR, so we can invalidate the disk
            // entirely if it does not have an MBR.
            var mbr = Mbr.init(&disk_source) catch |err| {
                std.log.err("no MBR found on disk {s}: {}", .{ disk_alias_path, err });
                continue;
            };

            const boot_partn = b: {
                for (mbr.partitions(), 1..) |part, mbr_partn| {
                    const part_type = MbrPartitionType.from_value(part.part_type()) orelse continue;

                    if (part.is_bootable() and
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
                    if (!part.is_bootable() and part_type == .ProtectedMbr) {
                        var gpt = Gpt.init(&disk_source) catch |err| switch (err) {
                            Gpt.Error.MissingMagicNumber => {
                                std.log.debug("disk {s} does not contain a GUID partition table", .{disk_alias_path});
                                continue;
                            },
                            Gpt.Error.HeaderCrcFail => {
                                std.log.err("disk {s} CRC integrity check failed", .{disk_alias_path});
                                continue;
                            },
                            else => {
                                std.log.err("failed to read disk {s}: {}", .{ disk_alias_path, err });
                                continue;
                            },
                        };

                        const partitions = try gpt.partitions(allocator);
                        for (partitions, 1..) |partition, gpt_partn| {
                            if (partition.part_type() orelse continue == .EfiSystem) {
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
            const esp_alias_path = try std.fs.path.joinZ(
                allocator,
                &.{
                    std.fs.path.sep_str,
                    "dev",
                    "disk",
                    partition_filename,
                },
            );

            std.log.debug("found boot partition {s}", .{esp_alias_path});

            var esp_handle = try std.fs.openFileAbsoluteZ(esp_alias_path, .{});
            defer esp_handle.close();

            var esp_file_source = std.io.StreamSource{ .file = esp_handle };
            const fstype = try FsType.detect(&esp_file_source) orelse {
                std.log.err("could not detect filesystem on EFI system partition", .{});
                continue;
            };

            const mountpoint = try std.fs.path.joinZ(
                allocator,
                &.{ std.fs.path.sep_str, "mnt", partition_filename },
            );
            std.fs.makeDirAbsoluteZ(mountpoint) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    std.log.err("failed to create mountpoint: {}", .{err});
                    continue;
                },
            };

            const rc = os.linux.mount(
                esp_alias_path,
                mountpoint,
                switch (fstype) {
                    .Vfat => "vfat",
                },
                os.linux.MS.NOSUID | os.linux.MS.NODEV | os.linux.MS.NOEXEC,
                0,
            );
            switch (os.linux.getErrno(rc)) {
                .SUCCESS => {},
                else => |err| {
                    std.log.err("failed to mount {s}: {}", .{ esp_alias_path, err });
                    continue;
                },
            }

            const mount = Mount{
                .disk_name = try disk_name(allocator, devname),
                .mountpoint = mountpoint,
            };

            std.log.info("mounted disk '{s}'", .{mount.disk_name});

            if (disk_is_removable(allocator, devname)) {
                try external_mounts.append(mount);
            } else {
                try internal_mounts.append(mount);
            }
        }

        self.internal_mounts = try internal_mounts.toOwnedSlice();
        self.external_mounts = try external_mounts.toOwnedSlice();
    }

    /// Caller is responsible for the returned value.
    fn search_for_entries(self: *@This(), mount: Mount, allocator: std.mem.Allocator) !BootDevice {
        const internal_allocator = self.arena.allocator();

        var entries = std.ArrayList(BootEntry).init(allocator);
        errdefer entries.deinit();

        var mountpoint_dir = try std.fs.openDirAbsoluteZ(mount.mountpoint, .{});
        defer mountpoint_dir.close();

        const loader_conf: LoaderConf = b: {
            var file = mountpoint_dir.openFile("loader/loader.conf", .{}) catch break :b .{};
            defer file.close();
            const contents = try file.readToEndAlloc(internal_allocator, 4096);
            defer internal_allocator.free(contents);
            break :b LoaderConf.parse(contents);
        };

        var entries_dir = try mountpoint_dir.openIterableDir("loader/entries", .{});
        defer entries_dir.close();

        var it = entries_dir.iterate();
        while (try it.next()) |dir_entry| {
            if (dir_entry.kind != .file) {
                continue;
            }

            var entry_file = entries_dir.dir.openFile(dir_entry.name, .{}) catch continue;
            const entry_contents = try entry_file.readToEndAlloc(internal_allocator, 4096);
            defer internal_allocator.free(entry_contents);
            var type1_entry = Type1Entry.parse(internal_allocator, entry_contents) catch continue;
            defer type1_entry.deinit();

            const linux = type1_entry.linux orelse {
                std.log.err("missing linux kernel in {s}", .{dir_entry.name});
                continue;
            };

            // NOTE: Multiple initrds won't work if we have IMA appraisal
            // of signed initrds, so we can only load one.
            //
            // TODO(jared): If IMA appraisal is disabled, we can
            // concatenate all the initrds together.
            var initrd: ?[]const u8 = null;
            if (type1_entry.initrd) |_initrd| {
                if (_initrd.len > 0) {
                    initrd = _initrd[0];
                }
            }

            const options = if (type1_entry.options) |opts|
                try std.mem.join(internal_allocator, " ", opts)
            else
                null;

            try entries.append(try BootEntry.init(
                allocator,
                mount.mountpoint,
                linux,
                initrd,
                options,
            ));
        }

        return .{
            .name = mount.disk_name,
            .timeout = loader_conf.timeout,
            .entries = try entries.toOwnedSlice(),
        };
    }

    /// Caller is responsible for the returned slice.
    pub fn probe(self: *@This(), allocator: std.mem.Allocator) ![]const BootDevice {
        std.log.debug("BLS probe", .{});
        var devices = std.ArrayList(BootDevice).init(allocator);

        // Internal mounts are ordered before external mounts so they are
        // prioritized in the boot process.
        for (self.internal_mounts) |mount| {
            try devices.append(self.search_for_entries(mount, allocator) catch continue);
        }

        for (self.external_mounts) |mount| {
            try devices.append(self.search_for_entries(mount, allocator) catch continue);
        }

        std.log.debug("BLS probe found {} devices", .{devices.items.len});
        return try devices.toOwnedSlice();
    }

    pub fn teardown(self: *@This()) void {
        std.log.debug("BLS teardown", .{});

        for (self.external_mounts) |mount| {
            std.log.info("unmounted disk '{s}'", .{mount.disk_name});
            _ = os.linux.umount2(mount.mountpoint, os.linux.MNT.DETACH);
        }

        for (self.internal_mounts) |mount| {
            std.log.info("unmounted disk '{s}'", .{mount.disk_name});
            _ = os.linux.umount2(mount.mountpoint, os.linux.MNT.DETACH);
        }

        self.arena.deinit();
    }
};

pub const EntryFilename = struct {
    name: []const u8,
    tries_left: ?u8 = null,
    tries_done: ?u8 = null,

    const Error = error{
        MissingSuffix,
        InvalidTriesSyntax,
    };

    pub fn parse(contents: []const u8) @This().Error!@This() {
        const filename_wo_suffix = std.mem.trimRight(u8, contents, ".conf");
        if (contents.len == filename_wo_suffix.len) {
            return Error.MissingSuffix;
        }

        var plus_split = std.mem.splitSequence(u8, filename_wo_suffix, "+");

        // stdlib says it will always return at least `buffer`
        const name = plus_split.next().?;

        if (plus_split.next()) |counter_info| {
            var minus_split = std.mem.splitSequence(u8, counter_info, "-");

            const plus_info = minus_split.next().?;
            const tries_done = std.fmt.parseInt(u8, plus_info, 10) catch {
                return Error.InvalidTriesSyntax;
            };

            if (minus_split.next()) |minus_info| {
                const tries_left = std.fmt.parseInt(u8, minus_info, 10) catch {
                    return Error.InvalidTriesSyntax;
                };
                return .{ .name = name, .tries_done = tries_done, .tries_left = tries_left };
            } else {
                return .{ .name = name, .tries_done = tries_done };
            }
        } else {
            return .{ .name = name };
        }
    }
};

test "entry filename parsing" {
    try std.testing.expectError(
        EntryFilename.Error.MissingSuffix,
        EntryFilename.parse("my-entry"),
    );

    try std.testing.expectError(
        EntryFilename.Error.InvalidTriesSyntax,
        EntryFilename.parse("my-entry+foo.conf"),
    );

    try std.testing.expectError(
        EntryFilename.Error.InvalidTriesSyntax,
        EntryFilename.parse("my-entry+foo-bar.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry" },
        EntryFilename.parse("my-entry.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry-1" },
        EntryFilename.parse("my-entry-1.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry", .tries_done = 1 },
        EntryFilename.parse("my-entry+1.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry", .tries_done = 0 },
        EntryFilename.parse("my-entry+0.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry", .tries_done = 0, .tries_left = 3 },
        EntryFilename.parse("my-entry+0-3.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry-1", .tries_done = 5, .tries_left = 0 },
        EntryFilename.parse("my-entry-1+5-0.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry-2", .tries_done = 3, .tries_left = 1 },
        EntryFilename.parse("my-entry-2+3-1.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry-3", .tries_done = 2 },
        EntryFilename.parse("my-entry-3+2.conf"),
    );
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
                    std.log.err("invalid timeout value '{s}'", .{value});
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
                self.linux = line_split.rest();
            } else if (std.mem.eql(u8, key, "initrd")) {
                try initrd.append(line_split.rest());
            } else if (std.mem.eql(u8, key, "efi")) {
                self.efi = line_split.rest();
            } else if (std.mem.eql(u8, key, "options")) {
                while (line_split.next()) |next| {
                    try options.append(next);
                }
            } else if (std.mem.eql(u8, key, "devicetree")) {
                self.devicetree = line_split.rest();
            } else if (std.mem.eql(u8, key, "devicetree-overlay")) {
                var devicetree_overlay = std.ArrayList([]const u8).init(allocator);
                errdefer devicetree_overlay.deinit();
                while (line_split.next()) |next| {
                    try devicetree_overlay.append(next);
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

    try std.testing.expectEqualStrings("/EFI/foo/Image", type1_entry.linux.?);
    try std.testing.expect(type1_entry.options.?.len == 2);
    try std.testing.expectEqualStrings("console=ttyAMA0", type1_entry.options.?[0]);
    try std.testing.expectEqualStrings("loglevel=7", type1_entry.options.?[1]);
}
