const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const linux_headers = @import("linux_headers");

const KEXEC_LOADED = "/sys/kernel/kexec_loaded";

pub const MemoryType = enum(u8) {
    Ram = 0,
    Reserved = 1,
    Acpi = 2,
    AcpiNvs = 3,
    Uncached = 4,
    Pmem = 6,
    Pram = 11,
};

pub const MemoryRange = struct {
    start: usize,
    end: usize,
    type: MemoryType,
};

/// Wait for up to 10 seconds for kernel to report for kexec to be loaded.
fn waitForKexecKernelLoaded() !void {
    const sleep_interval = 100 * std.time.ns_per_ms;

    var time_slept: u64 = 0;
    var f = try std.fs.cwd().openFile(KEXEC_LOADED, .{});
    defer f.close();

    while (time_slept < 10 * std.time.ns_per_s) {
        if (try f.reader().readByte() == '1') {
            return;
        }

        try f.seekTo(0);

        std.time.sleep(sleep_interval);
        time_slept += sleep_interval;
    }

    return error.Timeout;
}

fn kexecLoad(
    allocator: std.mem.Allocator,
    linux: std.fs.File,
    initrd: ?std.fs.File,
    cmdline: ?[]const u8,
) !void {
    _ = allocator;
    _ = linux;
    _ = initrd;
    _ = cmdline;

    return error.NotImplemented;
}

fn kexecFileLoad(
    allocator: std.mem.Allocator,
    linux: std.fs.File,
    initrd: ?std.fs.File,
    cmdline: ?[]const u8,
) !void {
    var flags: usize = 0;
    if (initrd == null) {
        flags |= linux_headers.KEXEC_FILE_NO_INITRAMFS;
    }

    // dupeZ() returns a null-terminated slice, however the null-terminator
    // is not included in the length of the slice, so we must add 1.
    const cmdline_z = try allocator.dupeZ(u8, cmdline orelse "");
    defer allocator.free(cmdline_z);
    const cmdline_len = cmdline_z.len + 1;

    const rc = std.os.linux.syscall5(
        .kexec_file_load,
        @as(usize, @bitCast(@as(isize, linux.handle))),
        @as(usize, @bitCast(@as(
            isize,
            if (initrd) |initrd_| initrd_.handle else 0,
        ))),
        cmdline_len,
        @intFromPtr(cmdline_z.ptr),
        flags,
    );

    switch (posix.errno(rc)) {
        .SUCCESS => {},
        // IMA appraisal failed
        .ACCES => return error.PermissionDenied,
        // Invalid kernel image (CONFIG_RELOCATABLE not enabled?)
        .NOEXEC => return error.InvalidExe,
        // Another image is already loaded
        .BUSY => return error.FilesAlreadyRegistered,
        .NOMEM => return error.SystemResources,
        .BADF => return error.InvalidFileDescriptor,
        else => |err| {
            std.log.err("kexec load failed for unknown reason: {}", .{err});
            return posix.unexpectedErrno(err);
        },
    }
}

pub const kexec_file_load_available = switch(builtin.cpu.arch) {
        // TODO(jared): confirm there aren't any more.
        .aarch64, .riscv64, .x86_64 => true,
        else => false,
};

pub fn kexec(
    allocator: std.mem.Allocator,
    linux_filepath: []const u8,
    initrd_filepath: ?[]const u8,
    cmdline: ?[]const u8,
) !void {
    std.log.info("preparing kexec", .{});
    std.log.info("loading linux {s}", .{linux_filepath});
    std.log.info("loading initrd {s}", .{initrd_filepath orelse "<none>"});
    std.log.info("loading params {s}", .{cmdline orelse "<none>"});

    // Use a constant path for the kernel and initrd so that the IMA events
    // don't have differing random temporary paths each boot.
    std.fs.cwd().makeDir("/tinyboot") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var boot_dir = try std.fs.cwd().openDir("/tinyboot", .{});
    defer {
        boot_dir.close();
        std.fs.cwd().deleteTree("/tinyboot") catch {};
    }

    try std.fs.cwd().copyFile(linux_filepath, std.fs.cwd(), "/tinyboot/kernel", .{});
    if (initrd_filepath) |initrd| {
        try std.fs.cwd().copyFile(initrd, std.fs.cwd(), "/tinyboot/initrd", .{});
    }

    const linux = try std.fs.cwd().openFile("/tinyboot/kernel", .{});
    defer linux.close();

    const initrd: ?std.fs.File = if (initrd_filepath != null) try std.fs.cwd().openFile("/tinyboot/initrd", .{}) else null;
    defer {
        if (initrd) |initrd_| {
            initrd_.close();
        }
    }

    if (kexec_file_load_available) {
        try kexecFileLoad(allocator, linux, initrd, cmdline);
    } else {
        try kexecLoad(allocator, linux, initrd, cmdline);
    }

    try waitForKexecKernelLoaded();

    std.log.info("kexec loaded", .{});
}
