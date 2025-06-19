const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;

const linux_headers = @import("linux_headers");

const Fdt = @import("../fdt.zig");

const kexec = @import("./kexec.zig");
const MemoryType = kexec.MemoryType;
const MemoryRange = kexec.MemoryRange;
const KexecSegment = kexec.KexecSegment;

const ZIMAGE_MAGIC = std.mem.nativeToLittle(u32, 0x016f2818);
const ZIMAGE_MAGIC2 = std.mem.nativeToLittle(u32, 0x45454545);

const ZimageHeader = extern struct {
    instr: [9]u32,
    magic: u32,
    start: u32,
    end: u32,
    endian: u32,
    magic2: u32,
    extension_tag_offset: u32,
};

const ZimageTag = extern struct {
    const KRNL_SIZE = std.mem.nativeToLittle(u32, 0x5a534c4b);

    hdr: extern struct {
        size: u32,
        tag: u32,
    },
    u: extern union {
        krnl_size: extern struct {
            size_ptr: u32,
            bss_size: u32,
        },
    },
};

fn mmapFile(file: std.fs.File) ![]align(std.heap.page_size_min) u8 {
    const stat = try file.stat();

    return try posix.mmap(
        null,
        @intCast(stat.size),
        posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
}

// No need to pass a purgatory program since the current kernel handles
// invoking the next kernel with the correct r2 register value
// (https://github.com/torvalds/linux/blob/0e1329d4045ca3606f9c06a8c47f62e758a09105/arch/arm/kernel/machine_kexec.c#L51).
pub fn kexecLoad(
    allocator: std.mem.Allocator,
    linux: std.fs.File,
    initrd: ?std.fs.File,
    cmdline: ?[]const u8,
) !void {
    const page_size = std.heap.pageSize();

    var segments = std.ArrayList(KexecSegment).init(allocator);
    defer segments.deinit();

    const linux_stat = try linux.stat();

    // Kernel too small
    if (linux_stat.size < @sizeOf(ZimageHeader)) {
        return error.InvalidKernel;
    }

    const kernel_buf = try mmapFile(linux);
    defer posix.munmap(kernel_buf);

    const hdr: *ZimageHeader = @ptrCast(@alignCast(kernel_buf));

    if (hdr.magic != ZIMAGE_MAGIC or
        hdr.magic2 != ZIMAGE_MAGIC2)
    {
        return error.InvalidKernel;
    }

    var kernel_size = std.mem.littleToNative(u32, hdr.end) - std.mem.littleToNative(u32, hdr.start);

    std.log.debug("zImage header: 0x{x}, 0x{x}, 0x{x}", .{ hdr.magic, hdr.start, hdr.end });

    if (kernel_size > linux_stat.size) {
        std.log.err("zImage is truncated", .{});
        return error.InvalidKernel;
    }

    // Save the length of the compressed kernel image w/o the appended DTB.
    // This will be required later on when the kernel image contained in the
    // zImage will be loaded into a kernel memory segment.  And we want to load
    // ONLY the compressed kernel image from the zImage and discard the appended
    // DTB.
    const kernel_buf_size = kernel_size;

    // Always extend the zImage by four bytes to ensure that an appended DTB
    // image always sees an initialised value after _edata.
    const kernel_mem_size = kernel_size + 4;

    // Check for a kernel size extension, and set or validate the image size.
    // This is the total space needed to avoid the boot kernel BSS, so other
    // data (such as initrd) does not get overwritten.
    const tag = try findExtensionTag(
        hdr,
        kernel_buf,
        kernel_size,
        ZimageTag.KRNL_SIZE,
    );

    // The zImage length does not include its stack (4k) or its malloc space
    // (64k).  Include this.
    kernel_size +=
        (4 * 1024) // stack
        + (64 * 1024) // malloc
    ;

    std.log.debug("zImage requires 0x{x} bytes", .{kernel_size});

    const uncompressed_kernel_size: u32 = b: {
        if (tag) |tag_| {
            const bss_size = tag_.u.krnl_size.bss_size;

            const size_ptr = kernel_buf[tag_.u.krnl_size.size_ptr..];
            const edata_size = std.mem.readVarInt(u32, size_ptr[0..@sizeOf(u32)], .little);
            const total = bss_size + edata_size;

            std.log.debug("Decompressed kernel sizes: text+data 0x{x} bss 0x{x} total 0x{x}", .{
                edata_size,
                bss_size,
                total,
            });

            // While decompressing, the zImage is placed past _edata of the
            // decompressed kernel.  Ensure we account for that.
            break :b if (total < edata_size + kernel_size) edata_size + kernel_size else total;
        } else {
            // If the user didn't specify the size of the image, and we don't
            // have the extension tables, assume the maximum kernel compression
            // ratio is 4. Note that we must include space for the compressed
            // image here as well.
            break :b kernel_size * 5;
        }
    };

    std.log.debug("resulting kernel space: 0x{x}", .{uncompressed_kernel_size});

    const extra_size = 0x8000; // TEXT_OFFSET

    const proc_iomem = try std.fs.cwd().openFile("/proc/iomem", .{});
    defer proc_iomem.close();
    var proc_iomem_stream = std.io.StreamSource{ .file = proc_iomem };
    const memory_ranges = try getMemoryRanges(allocator, &proc_iomem_stream);
    defer allocator.free(memory_ranges);

    // Prevent the need to relocate prior to decompression.
    // https://github.com/torvalds/linux/blob/0e1329d4045ca3606f9c06a8c47f62e758a09105/Documentation/arch/arm/booting.rst#L176
    const min_kernel_addr = 32 * 1024 * 1024;

    const kernel_base = try locateHole(
        memory_ranges,
        kernel_size + extra_size,
        page_size,
        min_kernel_addr,
    ) + extra_size;

    // Calculate the minimum address of the initrd, which must be above the
    // memory used by the zImage while it runs.  This needs to be page-size
    // aligned.
    var initrd_base = kernel_base + std.mem.alignForward(u32, uncompressed_kernel_size, page_size);

    std.log.debug("kernel: address=0x{x} size=0x{x}", .{ kernel_base, uncompressed_kernel_size });

    // TODO(jared): we need to be able to inject the kernel parameters into /chosen/bootargs
    const sys_firmware_fdt = try std.fs.cwd().openFile("/sys/firmware/fdt", .{});
    defer sys_firmware_fdt.close();

    var sys_firmware_fdt_stream = std.io.StreamSource{ .file = sys_firmware_fdt };
    var fdt = try Fdt.init(&sys_firmware_fdt_stream, allocator);
    defer fdt.deinit();

    if (cmdline) |cmdline_| {
        try fdt.upsertStringProperty("/chosen/bootargs", cmdline_);
    }

    var initrd_buf: ?[]align(std.heap.page_size_min) u8 = null;
    defer {
        if (initrd_buf) |buf| {
            posix.munmap(buf);
        }
    }

    const initrd_size = b: {
        if (initrd) |initrd_file| {
            initrd_buf = try mmapFile(initrd_file);

            initrd_base = try locateHole(
                memory_ranges,
                initrd_buf.?.len,
                page_size,
                initrd_base,
            );

            std.log.debug("initrd: address=0x{x} size=0x{x}", .{ initrd_base, initrd_buf.?.len });

            const initrd_start = std.mem.nativeToBig(u32, initrd_base);
            const initrd_end = std.mem.nativeToBig(u32, initrd_base + initrd_buf.?.len);

            try fdt.upsertU32Property("/chosen/linux,initrd-start", initrd_start);
            try fdt.upsertU32Property("/chosen/linux,initrd-end", initrd_end);

            // Insert KASLR seed if a hardware RNG is available
            if (std.fs.cwd().openFile("/dev/char/10:183", .{})) |hwrng| {
                defer hwrng.close();

                const seed = try hwrng.reader().readInt(u64, builtin.cpu.arch.endian);
                try fdt.upsertU64Property("/chosen/kaslr-seed", seed);
            } else |err| {
                std.log.warn("unable to add KASLR seed: {}", .{err});
            }

            try addSegment(&segments, page_size, initrd_buf.?, initrd_buf.?.len, initrd_base, initrd_buf.?.len);
            break :b initrd_buf.?.len;
        } else break :b 0;
    };

    const dtb_buf = try allocator.alloc(u8, fdt.size());
    defer allocator.free(dtb_buf);

    var dtb_buf_stream = std.io.StreamSource{ .buffer = std.io.fixedBufferStream(dtb_buf) };
    try fdt.save(dtb_buf_stream.writer());

    const dtb_offset = b: {
        var offset = std.mem.alignBackward(
            u32,
            initrd_base + initrd_size + page_size,
            page_size,
        );
        offset = try locateHole(
            memory_ranges,
            dtb_buf.len,
            page_size,
            offset,
        );
        break :b offset;
    };

    std.log.debug("devicetree: address=0x{x} size=0x{x}", .{ dtb_offset, dtb_buf.len });
    try addSegment(&segments, page_size, dtb_buf, dtb_buf.len, dtb_offset, dtb_buf.len);

    try addSegment(&segments, page_size, kernel_buf, kernel_buf_size, kernel_base, kernel_mem_size);

    const rc = std.os.linux.syscall4(
        .kexec_load,
        kernel_base,
        segments.items.len,
        @intFromPtr(segments.items.ptr),
        linux_headers.KEXEC_ARCH_DEFAULT,
    );

    return switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {},
        else => |err| posix.unexpectedErrno(err),
    };
}

fn addSegment(
    segments: *std.ArrayList(KexecSegment),
    alignment: usize,
    buf: []u8,
    buf_size: usize,
    mem: usize,
    mem_size: usize,
) !void {
    // Forget empty segments
    if (mem_size == 0) {
        return;
    }

    // Verify base is pagesize aligned. Finding a way to cope with this problem
    // is important but for now error so at least we are not surprised by the
    // code doing the wrong thing.
    if (!std.mem.isAligned(mem, alignment)) {
        return error.UnalignedLoadAddress;
    }

    try segments.append(.{
        .buf = @ptrCast(buf.ptr),
        .buf_size = @min(buf_size, mem_size), // bufsz may not exceed the value of memsz, see kexec_load(2)
        .mem = @ptrFromInt(mem),
        .mem_size = std.mem.alignForward(usize, mem_size, alignment),
    });
}

fn locateHole(
    memory_ranges: []const MemoryRange,
    size: usize,
    alignment: usize,
    min: usize,
) !usize {
    const min_aligned = std.mem.alignForward(usize, min, alignment);

    for (memory_ranges) |range| {
        if (range.type != .Ram) {
            continue;
        }

        if (min_aligned > range.end) {
            continue;
        }

        var multiple: usize = 0;
        while (true) : (multiple += 1) {
            const test_addr = @max(min_aligned, range.start) + (alignment * multiple);

            if (test_addr > range.end) {
                break;
            }

            if (range.end - test_addr >= size) {
                return test_addr;
            }
        }
    }

    return error.MemoryRangeNotFound;
}

test "locate hole" {
    const memory_ranges = [_]MemoryRange{
        .{
            .start = 0,
            .end = 256 * 1024 * 1024, // 256MiB
            .type = .Ram,
        },
        .{
            .start = 512 * 1024 * 1024,
            .end = 1024 * 1024 * 1024, // 128MiB
            .type = .Ram,
        },
    };

    const alignment = 4096;

    // start of first region
    try std.testing.expectEqual(0, locateHole(
        &memory_ranges,
        64 * 1024 * 1024,
        alignment,
        0,
    ));

    // too large
    try std.testing.expectError(error.MemoryRangeNotFound, locateHole(
        &memory_ranges,
        1024 * 1024 * 1024,
        alignment,
        0,
    ));

    // full size of first region, still usable
    try std.testing.expectEqual(0, locateHole(
        &memory_ranges,
        256 * 1024 * 1024,
        alignment,
        0,
    ));

    // unaligned min addr succeeds, returns aligned addr
    try std.testing.expectEqual(alignment + 64 * 1024 * 1024, locateHole(
        &memory_ranges,
        64 * 1024 * 1024,
        alignment,
        4000 + 64 * 1024 * 1024,
    ));

    // fallback to next memory range
    try std.testing.expectEqual(512 * 1024 * 1024, locateHole(
        &memory_ranges,
        64 * 1024 * 1024,
        alignment,
        324 * 1024 * 1024,
    ));
}

// parses memory ranges from a /proc/iomem stream
fn getMemoryRanges(allocator: std.mem.Allocator, stream: *std.io.StreamSource) ![]MemoryRange {
    var memory_ranges = std.ArrayList(MemoryRange).init(allocator);
    errdefer memory_ranges.deinit();

    var buf = [_]u8{0} ** 255; // unlikely to encounter a line this large
    var buf_stream = std.io.fixedBufferStream(&buf);

    while (true) {
        stream.reader().streamUntilDelimiter(buf_stream.writer(), '\n', null) catch |err| {
            switch (err) {
                error.EndOfStream => break,
                else => return err,
            }
        };
        defer buf_stream.reset();

        const written = buf_stream.getWritten();
        const memory_range, const name = b: {
            var split = std.mem.splitScalar(u8, written, ':');
            const left = split.next() orelse continue;
            const right = split.next() orelse continue;
            break :b .{
                std.mem.trim(u8, left, &std.ascii.whitespace),
                std.mem.trim(u8, right, &std.ascii.whitespace),
            };
        };

        const memory_type: MemoryType = if (std.mem.eql(u8, name, "System RAM") or std.mem.eql(u8, name, "System RAM (boot alias)")) .Ram else if (std.mem.eql(u8, name, "reserved")) .Reserved else continue;

        const start, const end = b: {
            var split = std.mem.splitScalar(u8, memory_range, '-');
            const left = split.next() orelse continue;
            const right = split.next() orelse continue;
            break :b .{
                try std.fmt.parseInt(
                    usize,
                    std.mem.trim(u8, left, &std.ascii.whitespace),
                    16,
                ),
                try std.fmt.parseInt(
                    usize,
                    std.mem.trim(u8, right, &std.ascii.whitespace),
                    16,
                ),
            };
        };

        try memory_ranges.append(.{
            .start = start,
            .end = end,
            .type = memory_type,
        });
    }

    return memory_ranges.toOwnedSlice();
}

test "getMemoryRanges" {
    {
        const proc_iomem =
            \\00000000-3eb2bfff : System RAM
            \\  00008000-017fffff : Kernel code
            \\  01900000-01a75517 : Kernel data
            \\3eb2d000-3eb2dfff : System RAM
            \\3eb50000-3fbd9fff : System RAM
            \\3fbdb000-3ff77fff : System RAM
            \\3ff7a000-3fffffff : System RAM
            \\e0000000-e7ffffff : PCI MEM
            \\  e0000000-e01fffff : PCI Bus 0000:01
            \\    e0000000-e00fffff : 0000:01:00.0
            \\      e0000000-e00fffff : 0000:01:00.0
            \\    e0100000-e0103fff : 0000:01:00.0
            \\    e0104000-e0104fff : 0000:01:00.0
            \\f1010680-f10106cf : f1010680.spi spi@10680
            \\f1011000-f101101f : f1011000.i2c i2c@11000
            \\f1011100-f101111f : f1011100.i2c i2c@11100
            \\f1012000-f10120ff : serial
            \\f1012100-f10121ff : serial
            \\f1018000-f101801f : f1018000.pinctrl pinctrl@18000
            \\f1018100-f101813f : f1018100.gpio gpio
            \\f1018140-f101817f : f1018140.gpio gpio
            \\f10181c0-f10181c7 : f1018100.gpio pwm
            \\f10181c8-f10181cf : f1018140.gpio pwm
            \\f1018300-f10183ff : f1018300.phy comphy
            \\f1018454-f1018457 : f10d8000.sdhci conf-sdio3
            \\f1018460-f1018463 : f1018300.phy conf
            \\f10184a0-f10184ab : f10a3800.rtc rtc-soc
            \\f1020704-f1020707 : f1020300.watchdog watchdog@20300
            \\f1020800-f102080f : cpurst@20800
            \\f1020a00-f1020ccf : interrupt-controller@20a00
            \\f1021070-f10210c7 : interrupt-controller@20a00
            \\f1022000-f1022fff : pmsu@22000
            \\f1030000-f1033fff : f1030000.ethernet ethernet@30000
            \\f1034000-f1037fff : f1034000.ethernet ethernet@34000
            \\f1040000-f1041fff : pcie
            \\  f1040000-f1041fff : soc:pcie pcie@2,0
            \\f1044000-f1045fff : pcie
            \\  f1044000-f1045fff : soc:pcie pcie@3,0
            \\f1048000-f1049fff : pcie
            \\f1058000-f10584ff : f1058000.usb usb@58000
            \\f1070000-f1073fff : f1070000.ethernet ethernet@70000
            \\f1080000-f1081fff : pcie
            \\f1090000-f109ffff : f1090000.crypto regs
            \\f10a3800-f10a381f : f10a3800.rtc rtc
            \\f10a8000-f10a9fff : f10a8000.sata sata@a8000
            \\f10c8000-f10c80ab : f10c8000.bm bm@c8000
            \\f10d8000-f10d8fff : f10d8000.sdhci sdhci
            \\f10e0000-f10e1fff : f10e0000.sata sata@e0000
            \\f10e4078-f10e407b : f10e4078.thermal thermal@e8078
            \\f10f0000-f10f3fff : f10f0000.usb3 usb3@f0000
            \\f10f8000-f10fbfff : f10f8000.usb3 usb3@f8000
            \\f1100000-f11007ff : f1100000.sa-sram0 sa-sram0
            \\f1110000-f11107ff : f1110000.sa-sram1 sa-sram1
            \\f1200000-f12fffff : f1200000.bm-bppi bm-bppi
        ;

        var stream = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(proc_iomem[0..]) };
        const ranges = try getMemoryRanges(std.testing.allocator, &stream);
        defer std.testing.allocator.free(ranges);

        try std.testing.expectEqual(5, ranges.len);

        try std.testing.expectEqual(.Ram, ranges[0].type);
        try std.testing.expectEqual(0x0, ranges[0].start);
        try std.testing.expectEqual(0x3eb2bfff, ranges[0].end);

        try std.testing.expectEqual(.Ram, ranges[1].type);
        try std.testing.expectEqual(0x3eb2d000, ranges[1].start);
        try std.testing.expectEqual(0x3eb2dfff, ranges[1].end);

        try std.testing.expectEqual(.Ram, ranges[2].type);
        try std.testing.expectEqual(0x3eb50000, ranges[2].start);
        try std.testing.expectEqual(0x3fbd9fff, ranges[2].end);

        try std.testing.expectEqual(.Ram, ranges[3].type);
        try std.testing.expectEqual(0x3fbdb000, ranges[3].start);
        try std.testing.expectEqual(0x3ff77fff, ranges[3].end);

        try std.testing.expectEqual(.Ram, ranges[4].type);
        try std.testing.expectEqual(0x3ff7a000, ranges[4].start);
        try std.testing.expectEqual(0x3fffffff, ranges[4].end);
    }

    {
        const proc_iomem =
            \\00000000-03ffffff : 0.flash flash@0
            \\04000000-07ffffff : 0.flash flash@0
            \\09000000-09000fff : pl011@9000000
            \\  09000000-09000fff : 9000000.pl011 pl011@9000000
            \\09010000-09010fff : pl031@9010000
            \\  09010000-09010fff : rtc-pl031
            \\09030000-09030fff : pl061@9030000
            \\  09030000-09030fff : 9030000.pl061 pl061@9030000
            \\40000000-bfffffff : System RAM
            \\  40208000-426fffff : Kernel code
            \\  42900000-42c58797 : Kernel data
        ;

        var stream = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(proc_iomem[0..]) };
        const ranges = try getMemoryRanges(std.testing.allocator, &stream);
        defer std.testing.allocator.free(ranges);

        try std.testing.expectEqual(1, ranges.len);

        try std.testing.expectEqual(.Ram, ranges[0].type);
        try std.testing.expectEqual(0x40000000, ranges[0].start);
        try std.testing.expectEqual(0xbfffffff, ranges[0].end);
    }
}

inline fn byteSize(tag: *ZimageTag) u32 {
    return tag.hdr.size << 2;
}

fn findExtensionTag(
    hdr: *ZimageHeader,
    kernel_buf: []u8,
    kernel_size: u32,
    tag_id: u32,
) !?*ZimageTag {
    var offset = hdr.extension_tag_offset;
    const max = kernel_size - @sizeOf(@FieldType(ZimageTag, "hdr"));

    while (true) {
        const tag: *ZimageTag = @ptrCast(@alignCast(kernel_buf[offset..]));
        if (@intFromPtr(tag) == 0) {
            break;
        }

        if (offset >= max) {
            break;
        }

        const size = std.mem.littleToNative(u32, byteSize(tag));
        if (size == 0) {
            break;
        }

        if (offset + size >= kernel_size) {
            break;
        }

        std.log.debug(
            "offset 0x{x} tag 0x{x} size {}",
            .{ offset, std.mem.littleToNative(u32, tag.hdr.tag), size },
        );

        if (tag.hdr.tag == tag_id) {
            return tag;
        }

        offset += size;
    }

    return null;
}
