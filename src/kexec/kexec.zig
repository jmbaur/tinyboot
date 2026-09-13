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
pub const KexecSegment = extern struct {
    buf: *anyopaque,
    buf_size: usize,
    mem: *anyopaque,
    mem_size: usize,
};

/// Wait for up to 10 seconds for kernel to report for kexec to be loaded.
fn waitForKexecKernelLoaded(io: std.Io) !void {
    var f = try std.Io.Dir.cwd().openFile(io, KEXEC_LOADED, .{});
    defer f.close(io);

    var buffer: [1]u8 = undefined;
    var reader = f.reader(io, &buffer);

    var time_slept: usize = 0;
    while (time_slept < 10 * std.time.ns_per_s) : (time_slept += std.time.ns_per_s) {
        std.log.debug("waiting for kexec load to finish", .{});
        try reader.seekTo(0);

        if (try reader.interface.takeByte() == '1') {
            return;
        }

        try std.Io.sleep(io, .fromSeconds(1), .boot);
    }

    return error.Timeout;
}

const kexecLoad = switch (builtin.cpu.arch) {
    .arm => @import("./arm.zig").kexecLoad,
    else => @compileError("kexec_load not implemented for target architecture"),
};

fn kexecFileLoad(
    allocator: std.mem.Allocator,
    linux: std.Io.File,
    initrd: ?std.Io.File,
    cmdline: ?[]const u8,
) !void {
    var flags: usize = if (builtin.mode == .debug) linux_headers.KEXEC_FILE_DEBUG else 0;

    if (initrd == null) {
        flags |= linux_headers.KEXEC_FILE_NO_INITRAMFS;
    }

    // dupeSentinel() returns a null-terminated slice, however the null-terminator
    // is not included in the length of the slice, so we must add 1.
    const cmdline_z = try allocator.dupeSentinel(u8, cmdline orelse "", 0);
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

    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        // This architecture has kexec_file_load(), but the running kernel was
        // built without it.
        .NOSYS => {
            std.log.err("kernel is missing CONFIG_KEXEC_FILE", .{});
            return error.KexecFileLoadUnavailable;
        },
        // No CAP_SYS_BOOT, kexec turned off with the kernel.kexec_load_disabled
        // sysctl, or the kernel.kexec_load_limit_reboot budget is used up.
        .PERM => {
            std.log.err("not permitted to kexec", .{});
            return error.PermissionDenied;
        },
        // IMA appraisal failed
        .ACCES => {
            std.log.err("kernel or initrd rejected by IMA appraisal, is it signed by a trusted key?", .{});
            return error.ImaAppraisalFailed;
        },
        // CONFIG_KEXEC_SIG verification failed, or this architecture's image
        // loader can't check signatures at all.
        .KEYREJECTED => {
            std.log.err("kernel image signature rejected by the kernel", .{});
            return error.SignatureRejected;
        },
        // Invalid kernel image (CONFIG_RELOCATABLE not enabled?)
        .NOEXEC => {
            std.log.err("no kexec loader recognized the kernel image", .{});
            return error.InvalidExe;
        },
        // The kernel or initrd is bigger than KEXEC_FILE_SIZE_MAX.
        .FBIG => {
            std.log.err("kernel or initrd too large to load", .{});
            return error.FileTooBig;
        },
        // Bad flags, or a command line the kernel won't take. Ours to fix.
        .INVAL => {
            std.log.err("kernel rejected our kexec_file_load() arguments", .{});
            return error.InvalidParameter;
        },
        // Another image is already loaded
        .BUSY => {
            std.log.err("another kernel image is already loaded", .{});
            return error.FilesAlreadyRegistered;
        },
        .NOMEM => {
            std.log.err("not enough memory to load the kernel image", .{});
            return error.SystemResources;
        },
        .BADF => {
            std.log.err("kernel or initrd file descriptor is invalid", .{});
            return error.InvalidFileDescriptor;
        },
        else => |err| {
            std.log.err("kexec load failed for unknown reason: {t}", .{err});
            return posix.unexpectedErrno(err);
        },
    }
}

/// Linux only wires up the kexec_file_load() syscall on architectures that
/// define ARCH_SUPPORTS_KEXEC_FILE, since CONFIG_KEXEC_FILE depends on it. As
/// of linux 7.2, that is exactly the set below. Note that a kernel for one of
/// these architectures still needs CONFIG_KEXEC_FILE turned on, so the syscall
/// can fail with ENOSYS at runtime even when this is true.
pub const kexec_file_load_available = switch (builtin.cpu.arch) {
    // arch/arm64/Kconfig: def_bool y
    .aarch64, .aarch64_be => true,
    // arch/loongarch/Kconfig: def_bool 64BIT
    .loongarch64 => true,
    // arch/parisc/Kconfig: def_bool y
    .hppa, .hppa64 => true,
    // arch/powerpc/Kconfig: def_bool PPC64
    .powerpc64, .powerpc64le => true,
    // arch/riscv/Kconfig: def_bool 64BIT
    .riscv64 => true,
    // arch/s390/Kconfig: def_bool y
    .s390x => true,
    // arch/x86/Kconfig: def_bool X86_64
    .x86_64 => true,
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

    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    };
}

pub fn kexec(
    io: std.Io,
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
    std.Io.Dir.cwd().createDirPath(io, "/tinyboot") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var boot_dir = try std.Io.Dir.cwd().openDir(io, "/tinyboot", .{});
    defer {
        boot_dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, "/tinyboot") catch {};
    }

    const kernel_file = try std.Io.Dir.cwd().openFile(io, linux_filepath, .{});
    defer kernel_file.close(io);

    if (initrd_filepath) |initrd| {
        try std.Io.Dir.cwd().copyFile(initrd, std.Io.Dir.cwd(), "/tinyboot/initrd", io, .{});
    }

    var linux: ?std.Io.File = null;
    defer {
        if (linux) |l| {
            l.close(io);
        }
    }

    if (detectCompression(io, kernel_file)) |compression| {
        linux = try std.Io.Dir.cwd().createFile(io, "/tinyboot/kernel", .{});

        var reader_buffer: [1024]u8 = undefined;
        var writer_buffer: [1024]u8 = undefined;
        var reader = kernel_file.reader(io, &reader_buffer);
        var writer = linux.?.writer(io, &writer_buffer);
        switch (compression) {
            .gzip => {
                var decomp_buffer: [1024]u8 = undefined;
                var decomp: std.compress.flate.Decompress = .init(&reader.interface, .gzip, &decomp_buffer);
                var bytes_streamed: usize = 0;
                while (decomp.reader.stream(&writer.interface, .unlimited)) |n| {
                    bytes_streamed += n;
                } else |err| switch (err) {
                    error.EndOfStream => {},
                    else => return err,
                }
                std.log.debug("decompressed {Bi:.02}", .{bytes_streamed});
            },
        }
    } else {
        try std.Io.Dir.cwd().copyFile(linux_filepath, std.Io.Dir.cwd(), "/tinyboot/kernel", io, .{});
        linux = try std.Io.Dir.cwd().openFile(io, "/tinyboot/kernel", .{});
    }

    const initrd: ?std.Io.File = if (initrd_filepath != null)
        try std.Io.Dir.cwd().openFile(io, "/tinyboot/initrd", .{})
    else
        null;

    defer {
        if (initrd) |initrd_| {
            initrd_.close(io);
        }
    }

    if (kexec_file_load_available) {
        try kexecFileLoad(allocator, linux.?, initrd, cmdline);
    } else {
        try kexecLoad(io, allocator, linux.?, initrd, cmdline);
    }

    try waitForKexecKernelLoaded(io);

    std.log.info("kexec loaded", .{});
}

const gzip_magic = [_]u8{ 0x1f, 0x8b };
const Compression = enum { gzip };

fn detectCompression(io: std.Io, file: std.Io.File) ?Compression {
    var file_reader = file.reader(io, &.{});
    defer file_reader.seekTo(0) catch {};

    file_reader.seekTo(0) catch return null;

    var magic: [2]u8 = undefined;
    const bytes_read = file_reader.interface.readSliceShort(&magic) catch return null;
    if (bytes_read != magic.len) {
        return null;
    }

    if (std.mem.eql(u8, &magic, &gzip_magic)) {
        return .gzip;
    }

    return null;
}
