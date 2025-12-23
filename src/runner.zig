const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");

const utils = @import("./utils.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Display this help and exit.
        \\<ARCH>                  Architecture of the VM guest.
        \\<KEYDIR>                Directory of keys used for verified boot within the VM guest.
        \\<INITRD>                Initrd file to use when spawning the VM guest.
        \\<KERNEL>                Kernel file to use when spawning the VM guest.
        \\<QEMU_ARGS>...          Extra arguments passed to qemu.
        \\
    );

    const parsers = comptime .{
        .ARCH = clap.parsers.enumeration(std.Target.Cpu.Arch),
        .TEMPDIR = clap.parsers.string,
        .KEYDIR = clap.parsers.string,
        .INITRD = clap.parsers.string,
        .KERNEL = clap.parsers.string,
        .QEMU_ARGS = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, &parsers, .{
        .diagnostic = &diag,
        .allocator = arena.allocator(),
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        try clap.usageToFile(.stderr(), clap.Help, &params);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});
    }

    const arch = res.positionals[0].?;
    const keydir = res.positionals[1].?;
    const initrd = res.positionals[2].?;
    const kernel = res.positionals[3].?;
    const extra_qemu_args = res.positionals[4];

    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();

    if (std.mem.eql(u8, kernel, "")) {
        std.log.err("Cannot execute runner without kernel", .{});
        return error.InvalidArgument;
    }

    var qemu_args = std.ArrayList([]const u8){};

    try qemu_args.append(arena_alloc, switch (arch) {
        .aarch64 => "qemu-system-aarch64",
        .arm => "qemu-system-arm",
        .x86_64 => "qemu-system-x86_64",
        else => return error.UnknownArchitecture,
    });

    if (builtin.target.os.tag == .linux and utils.absolutePathExists("/dev/kvm") and builtin.target.cpu.arch == arch) {
        try qemu_args.append(arena_alloc, "-enable-kvm");
    }

    try qemu_args.appendSlice(arena_alloc, &.{ "-machine", switch (arch) {
        .aarch64, .arm => "virt",
        .x86_64 => "pc",
        else => return error.UnknownArchitecture,
    } });

    try qemu_args.appendSlice(arena_alloc, &.{
        "-display", "none",
        "-serial",  "mon:stdio",
        "-cpu",     "max",
        "-smp",     "1",
        "-m",       "1G",
        "-netdev",  "user,id=n1",
        "-device",  "virtio-net-pci,netdev=n1",
        "-device",  "virtio-serial",
        "-initrd",  initrd,
        "-kernel",  kernel,
    });

    if (!std.mem.eql(u8, keydir, "")) {
        try qemu_args.appendSlice(arena_alloc, &.{
            "-fw_cfg",
            try std.fmt.allocPrint(arena_alloc, "name=opt/org.tboot/pubkey,file={s}/tboot-certificate.der", .{keydir}),
        });
    }

    const tempdir_path = try tempdir.dir.realpathAlloc(arena_alloc, ".");
    try qemu_args.appendSlice(arena_alloc, &.{
        "-chardev", try std.fmt.allocPrint(arena_alloc, "socket,id=chrtpm,path={s}/swtpm.sock", .{tempdir_path}),
        "-tpmdev",  "emulator,id=tpm0,chardev=chrtpm",
        "-device",
        switch (arch) {
            .aarch64, .arm => "tpm-tis-device,tpmdev=tpm0",
            .x86_64 => "tpm-tis,tpmdev=tpm0",
            else => return error.UnknownArchitecture,
        },
    });

    for (extra_qemu_args) |arg| {
        try qemu_args.append(arena_alloc, arg);
    }

    var swtpm_child = std.process.Child.init(&.{
        "swtpm",
        "socket",
        "--terminate",
        "--tpm2",
        "--log",
        try std.fmt.allocPrint(arena_alloc, "file={s}/swtpm.log,level=20", .{tempdir_path}),
        "--tpmstate",
        try std.fmt.allocPrint(arena_alloc, "dir={s}", .{tempdir_path}),
        "--ctrl",
        try std.fmt.allocPrint(arena_alloc, "type=unixio,path={s}/swtpm.sock", .{tempdir_path}),
    }, arena_alloc);
    try swtpm_child.spawn();
    defer _ = swtpm_child.kill() catch {};

    var qemu_child = std.process.Child.init(try qemu_args.toOwnedSlice(
        arena_alloc,
    ), arena_alloc);
    _ = try qemu_child.spawnAndWait();
}
