const std = @import("std");
const builtin = @import("builtin");

fn pathExists(p: []const u8) bool {
    std.fs.accessAbsolute(p, .{}) catch {
        return false;
    };

    return true;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var allocator = arena.allocator();

    var args = std.process.ArgIterator.init();
    _ = args.next().?;
    const tmpdir = args.next().?;
    const initrd = args.next().?;
    const kernel = args.next().?;

    try std.os.chdir(tmpdir);

    var qemu_args = std.ArrayList([]const u8).init(allocator);

    try qemu_args.append(switch (builtin.target.cpu.arch) {
        .aarch64 => "qemu-system-aarch64",
        .x86_64 => "qemu-system-x86_64",
        else => @compileError("don't know how to run qemu on build system"),
    });

    if (builtin.target.os.tag == .linux and pathExists("/dev/kvm")) {
        try qemu_args.append("-enable-kvm");
    }

    try qemu_args.appendSlice(switch (builtin.target.cpu.arch) {
        .aarch64 => &.{ "-machine", "virt", "-cpu", "cortex-a53" },
        .x86_64 => &.{ "-machine", "q35", "-cpu", "max" },
        else => @compileError("don't know how to run qemu on build system"),
    });

    const swtpm_sock_path = try std.fs.path.join(allocator, &.{ tmpdir, "swtpm.sock" });

    try qemu_args.appendSlice(&.{
        // "-fw_cfg",  "name=opt/org.tboot/pubkey,file=TODO",
        "-display", "none",
        "-serial",  "mon:stdio",
        "-smp",     "2",
        "-m",       "2G",
        "-netdev",  "user,id=n1",
        "-device",  "virtio-net-pci,netdev=n1",
        "-initrd",  initrd,
        "-kernel",  kernel,
    });

    try qemu_args.appendSlice(&.{
        "-chardev", try std.fmt.allocPrint(allocator, "socket,id=chrtpm,path={s}", .{swtpm_sock_path}),
        "-tpmdev",  "emulator,id=tpm0,chardev=chrtpm",
        "-device",
        switch (builtin.target.cpu.arch) {
            .aarch64 => "tpm-tis-device,tpmdev=tpm0",
            .x86_64 => "tpm-tis,tpmdev=tpm0",
            else => @compileError("don't know how to run qemu on build system"),
        },
    });

    while (args.next()) |arg| {
        try qemu_args.append(arg);
    }

    var swtpm_child = std.ChildProcess.init(&.{
        "swtpm",
        "socket",
        "--terminate",
        "--tpmstate",
        try std.fmt.allocPrint(allocator, "dir={s}", .{tmpdir}),
        "--ctrl",
        try std.fmt.allocPrint(allocator, "type=unixio,path={s}", .{swtpm_sock_path}),
        "--tpm2",
    }, allocator);
    try swtpm_child.spawn();
    defer _ = swtpm_child.kill() catch {};

    var qemu_child = std.ChildProcess.init(try qemu_args.toOwnedSlice(), allocator);
    _ = try qemu_child.spawnAndWait();
}
