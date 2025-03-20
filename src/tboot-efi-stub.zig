const std = @import("std");
const uefi = std.os.uefi;

var con_out: *uefi.protocol.SimpleTextOutput = undefined;
var boot_services: *uefi.tables.BootServices = undefined;

fn puts(msg: []const u8) void {
    for (msg) |c| {
        const c_ = [2]u16{ c, 0 }; // work around https://github.com/ziglang/zig/issues/4372
        _ = con_out.outputString(@ptrCast(&c_));
    }
}

var print_buf: [256]u8 = undefined;
fn printf(comptime fmt: []const u8, args: anytype) void {
    var fbs = std.io.fixedBufferStream(&print_buf);

    std.fmt.format(fbs.writer().any(), fmt, args) catch |err| switch (err) {
        // Ignore NoSpaceLeft errors, since the writer will still have written
        // enough bytes for us to get something on the screen to likely still
        // be useful. In this case, the output will just be truncated. This is
        // the same as what the Linux EFI stub does.
        error.NoSpaceLeft => {},
        else => unreachable,
    };

    const written = fbs.getWritten();
    puts(written[0 .. written.len - 1]);
    puts(">"); // Indicate that we truncated the output
}

fn println(comptime fmt: []const u8, args: anytype) void {
    printf(fmt, args);

    // Do this in another call to puts since the printf formatted string might
    // get truncated.
    puts("\r\n");
}

const LINUX_INITRD_MEDIA_GUID align(8) = uefi.Guid{
    .time_low = 0x5568e427,
    .time_mid = 0x68fc,
    .time_high_and_version = 0x4f3d,
    .clock_seq_high_and_reserved = 0xac,
    .clock_seq_low = 0x74,
    .node = [_]u8{ 0xca, 0x55, 0x52, 0x31, 0xcc, 0x68 },
};

const EFI_LOAD_FILE2_PROTOCOL_GUID align(8) = uefi.Guid{
    .time_low = 0x4006c0c1,
    .time_mid = 0xfcb3,
    .time_high_and_version = 0x403e,
    .clock_seq_high_and_reserved = 0x99,
    .clock_seq_low = 0x6d,
    .node = [_]u8{ 0x4a, 0x6c, 0x87, 0x24, 0xe0, 0x6d },
};

const LoadFile = *const fn (
    *LoadFileProtocol,
    *uefi.protocol.DevicePath,
    bool,
    *usize,
    ?*anyopaque,
) callconv(uefi.cc) uefi.Status;

const LoadFileProtocol = extern struct {
    load_file: LoadFile,
};

const InitrdLoader = struct {
    load_file: LoadFileProtocol,
    address: *const anyopaque,
    length: usize,
};

fn initrd_load_file(
    this: *LoadFileProtocol,
    filepath: *uefi.protocol.DevicePath,
    boot_policy: bool,
    buffer_size: *usize,
    buffer: ?*anyopaque,
) callconv(uefi.cc) uefi.Status {
    _ = filepath;

    if (boot_policy) {
        return .unsupported;
    }

    const loader: *InitrdLoader = @ptrCast(this);

    if (loader.length == 0) {
        return .not_found;
    }

    if (buffer == null or buffer_size.* < loader.length) {
        buffer_size.* = loader.length;
        return .buffer_too_small;
    }

    const dest: [*]u8 = @ptrCast(buffer);
    const source: [*]u8 = @ptrCast(@constCast(loader.address));
    @memcpy(dest, source[0..loader.length]);
    buffer_size.* = loader.length;

    return .success;
}

const efi_initrd_device_path: extern struct {
    vendor: uefi.DevicePath.Media.VendorDevicePath,
    end: uefi.protocol.DevicePath,
} = .{
    .vendor = .{
        .type = .media,
        .subtype = .vendor,
        .length = @sizeOf(uefi.DevicePath.Media.VendorDevicePath),
        .guid = LINUX_INITRD_MEDIA_GUID,
    },
    .end = .{
        .type = .end,
        .subtype = @intFromEnum(uefi.DevicePath.End.Subtype.end_entire),
        .length = @sizeOf(uefi.protocol.DevicePath),
    },
};

fn logic() uefi.Status {
    var status: uefi.Status = .success;

    var self_loaded_image_: ?*uefi.protocol.LoadedImage = undefined;
    status = boot_services.handleProtocol(
        uefi.handle,
        &uefi.protocol.LoadedImage.guid,
        @ptrCast(&self_loaded_image_),
    );
    if (status != .success) {
        println("failed to get EFI_LOADED_IMAGE_PROTOCOL for tinyboot", .{});
        return status;
    }

    const self_loaded_image = self_loaded_image_.?;

    const coff = std.coff.Coff.init(
        self_loaded_image.image_base[0..self_loaded_image.image_size],
        true,
    ) catch {
        println("failed to get coff image", .{});
        return .invalid_parameter;
    };

    const linux = coff.getSectionByName(".linux") orelse {
        println("failed to get '.linux' section", .{});
        return .not_found;
    };

    const linux_data = coff.getSectionData(linux);

    var linux_image_handle: ?uefi.Handle = null;
    status = boot_services.loadImage(
        false,
        uefi.handle,
        null,
        linux_data.ptr,
        linux_data.len,
        &linux_image_handle,
    );
    if (status != .success) {
        println("failed to load linux", .{});
        return status;
    }

    var linux_loaded_image_: ?*uefi.protocol.LoadedImage = undefined;
    status = boot_services.handleProtocol(
        linux_image_handle.?,
        &uefi.protocol.LoadedImage.guid,
        @ptrCast(&linux_loaded_image_),
    );
    if (status != .success) {
        println("failed to get EFI_LOADED_IMAGE_PROTOCOL for linux", .{});
        return status;
    }

    const initrd = coff.getSectionByName(".initrd") orelse {
        println("failed to get '.initrd' section", .{});
        return .not_found;
    };

    const initrd_data = coff.getSectionData(initrd);

    const loader = uefi.pool_allocator.create(InitrdLoader) catch return .out_of_resources;
    loader.* = InitrdLoader{
        .load_file = .{ .load_file = initrd_load_file },
        .address = @ptrCast(initrd_data.ptr),
        .length = initrd_data.len,
    };

    // In the happy path, this doesn't get cleaned up by us, since it needs to
    // outlive our application so linux can use it.
    errdefer uefi.pool_allocator.destroy(loader);

    // TODO(jared): if StartImage() fails, we need to unregister the initrd.
    // See https://github.com/systemd/systemd/blob/0015502168b868e8b6380765bdce3abee33b856c/src/boot/initrd.c#L112.
    var initrd_image_handle: ?uefi.Handle = null;

    const efi_initrd_device_path_: [*]uefi.protocol.DevicePath = @constCast(@ptrCast(&efi_initrd_device_path));

    // TODO(jared): Use InstallMultipleProtocolInterfaces()
    status = boot_services.installProtocolInterface(
        @ptrCast(&initrd_image_handle),
        &uefi.protocol.DevicePath.guid,
        .efi_native_interface,
        efi_initrd_device_path_,
    );
    if (status != .success) {
        println("failed to register initrd", .{});
        return status;
    }

    status = boot_services.installProtocolInterface(
        @ptrCast(&initrd_image_handle),
        @alignCast(&EFI_LOAD_FILE2_PROTOCOL_GUID),
        .efi_native_interface,
        loader,
    );
    if (status != .success) {
        println("failed to register initrd", .{});
        return status;
    }

    status = boot_services.startImage(linux_image_handle.?, null, null);
    if (status != .success) {
        println("failed to start linux", .{});
        return status;
    }

    return .aborted;
}

pub fn main() uefi.Status {
    con_out = uefi.system_table.con_out.?;
    boot_services = uefi.system_table.boot_services.?;

    const status = logic();

    if (status != .success) {
        println("failed to run tinyboot EFI stub: {}", .{status});

        // Stall so that the user has some time to see what happened.
        _ = boot_services.stall(5 * std.time.ms_per_s);
    }

    return status;
}
