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

/// This structure is used to hold the arguments that
/// are used when loading  kernel binaries.
/// https://github.com/torvalds/linux/blob/0d8d44db295ccad20052d6301ef49ff01fb8ae2d/include/uapi/linux/kexec.h#L59
pub const KexecSegment = struct {
    buf: *anyopaque,
    buf_size: usize,
    mem: *anyopaque,
    mem_size: usize,
};

/// Wait for up to 10 seconds for kernel to report for kexec to be loaded.
fn waitForKexecKernelLoaded() !void {
    var f = try std.fs.cwd().openFile(KEXEC_LOADED, .{});
    defer f.close();

    var time_slept: usize = 0;
    while (time_slept < 10 * std.time.ns_per_s) : (time_slept += std.time.ns_per_s) {
        std.log.debug("waiting for kexec load to finish", .{});
        try f.seekTo(0);

        if (try f.reader().readByte() == '1') {
            return;
        }

        std.time.sleep(std.time.ns_per_s);
    }

    return error.Timeout;
}

const kexecLoad = switch (builtin.cpu.arch) {
    .arm => @import("./arm.zig").kexecLoad,
    else => @compileError("kexec_load not implemented for target architecture"),
};

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

    switch (std.os.linux.E.init(rc)) {
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

pub const kexec_file_load_available = switch (builtin.cpu.arch) {
    // TODO(jared): confirm there aren't any more.
    .aarch64, .riscv64, .x86_64 => true,
    else => false,
};

pub fn kexecUnload() !void {
    const rc = if (kexec_file_load_available) std.os.linux.syscall5(
        .kexec_file_load,
        null,
        null,
        null,
        0,
        linux_headers.KEXEC_FILE_NO_INITRAMFS,
    ) else std.os.linux.syscall4(
        .kexec_load,
        null,
        0,
        null,
        0,
    );

    return switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    };
}

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
        boot_dir.deleteTree(".") catch {};
        boot_dir.close();
    }

    const kernel_file = try std.fs.cwd().openFile(linux_filepath, .{});
    defer kernel_file.close();

    if (initrd_filepath) |initrd| {
        try std.fs.cwd().copyFile(initrd, std.fs.cwd(), "/tinyboot/initrd", .{});
    }

    const linux = try std.fs.cwd().createFile("/tinyboot/kernel", .{});
    defer linux.close();

    if (detectCompression(kernel_file)) |compression| {
        switch (compression) {
            .gzip => try std.compress.gzip.decompress(kernel_file.reader(), linux.writer()),
        }
    } else {
        // Would be nice if we had something like std.io.copy that just copied
        // all of a reader to a writer.
        var buf = std.mem.zeroes([4096]u8);

        while (true) {
            const bytes_read = try kernel_file.reader().readAll(&buf);

            try linux.writer().writeAll(buf[0..bytes_read]);

            if (bytes_read == 0) {
                break;
            }
        }
    }

    const initrd: ?std.fs.File = if (initrd_filepath != null)
        try std.fs.cwd().openFile("/tinyboot/initrd", .{})
    else
        null;

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

const gzip_magic = [_]u8{ 0x1f, 0x8b };
const Compression = enum { gzip };

fn detectCompression(file: std.fs.File) ?Compression {
    defer file.seekTo(0) catch {};

    file.seekTo(0) catch return null;

    var magic: [2]u8 = undefined;
    const bytes_read = file.reader().readAll(&magic) catch return null;
    if (bytes_read != magic.len) {
        return null;
    }

    if (std.mem.eql(u8, &magic, &gzip_magic)) {
        return .gzip;
    }

    return null;
}
