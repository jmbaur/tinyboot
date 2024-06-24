const std = @import("std");
const posix = std.posix;
const system = std.posix.system;

const linux_headers = @import("linux_headers");

// TODO(jared): some comptime magic to automate this
pub const MAX_POLICY_SIZE =
    (PROC_SUPER_MAGIC.len +
    SYSFS_MAGIC.len +
    DEBUGFS_MAGIC.len +
    TMPFS_MAGIC.len +
    DEVPTS_SUPER_MAGIC.len +
    BINFMTFS_MAGIC.len +
    SECURITYFS_MAGIC.len +
    SELINUX_MAGIC.len +
    SMACK_MAGIC.len +
    CGROUP_SUPER_MAGIC.len +
    CGROUP2_SUPER_MAGIC.len +
    NSFS_MAGIC.len +
    KEY_CHECK.len +
    POLICY_CHECK.len +
    KEXEC_KERNEL_CHECK.len +
    KEXEC_INITRAMFS_CHECK.len +
    KEXEC_CMDLINE.len +
    KEXEC_KERNEL_CHECK_APPRAISE.len +
    KEXEC_INITRAMFS_CHECK_APPRAISE.len) * 2; // TODO(jared): this extra space shouldn't be needed?

pub const IMA_POLICY_PATH = "/sys/kernel/security/ima/policy";

// PROC_SUPER_MAGIC = 0x9fa0
pub const PROC_SUPER_MAGIC = withNewline("dont_measure fsmagic=0x9fa0");

// SYSFS_MAGIC = 0x62656572
pub const SYSFS_MAGIC = withNewline("dont_measure fsmagic=0x62656572");

// DEBUGFS_MAGIC = 0x64626720
pub const DEBUGFS_MAGIC = withNewline("dont_measure fsmagic=0x64626720");

// TMPFS_MAGIC = 0x01021994
pub const TMPFS_MAGIC = withNewline("dont_measure fsmagic=0x1021994");

// DEVPTS_SUPER_MAGIC=0x1cd1
pub const DEVPTS_SUPER_MAGIC = withNewline("dont_measure fsmagic=0x1cd1");

// BINFMTFS_MAGIC=0x42494e4d
pub const BINFMTFS_MAGIC = withNewline("dont_measure fsmagic=0x42494e4d");

// SECURITYFS_MAGIC=0x73636673
pub const SECURITYFS_MAGIC = withNewline("dont_measure fsmagic=0x73636673");

// SELINUX_MAGIC=0xf97cff8c
pub const SELINUX_MAGIC = withNewline("dont_measure fsmagic=0xf97cff8c");

// SMACK_MAGIC=0x43415d53
pub const SMACK_MAGIC = withNewline("dont_measure fsmagic=0x43415d53");

// CGROUP_SUPER_MAGIC=0x27e0eb
pub const CGROUP_SUPER_MAGIC = withNewline("dont_measure fsmagic=0x27e0eb");

// CGROUP2_SUPER_MAGIC=0x63677270
pub const CGROUP2_SUPER_MAGIC = withNewline("dont_measure fsmagic=0x63677270");

// NSFS_MAGIC=0x6e736673
pub const NSFS_MAGIC = withNewline("dont_measure fsmagic=0x6e736673");

pub const KEY_CHECK = withNewline("measure func=KEY_CHECK pcr=7");

pub const POLICY_CHECK = withNewline("measure func=POLICY_CHECK pcr=7");

pub const KEXEC_KERNEL_CHECK = withNewline("measure func=KEXEC_KERNEL_CHECK pcr=8");

pub const KEXEC_INITRAMFS_CHECK = withNewline("measure func=KEXEC_INITRAMFS_CHECK pcr=9");

pub const KEXEC_CMDLINE = withNewline("measure func=KEXEC_CMDLINE pcr=12");

pub const KEXEC_KERNEL_CHECK_APPRAISE = withNewline("appraise func=KEXEC_KERNEL_CHECK appraise_type=imasig|modsig");

pub const KEXEC_INITRAMFS_CHECK_APPRAISE = withNewline("appraise func=KEXEC_INITRAMFS_CHECK appraise_type=imasig|modsig");

fn installImaPolicy(policy: []const u8) !void {
    var policy_file = try std.fs.openFileAbsolute(IMA_POLICY_PATH, .{ .mode = .write_only });
    defer policy_file.close();

    std.log.debug("writing IMA policy", .{});

    try policy_file.writeAll(policy);
}

const TEST_KEY = @embedFile("test_key");

// https://github.com/torvalds/linux/blob/3b517966c5616ac011081153482a5ba0e91b17ff/security/integrity/digsig.c#L193
fn loadVerificationKey() !void {
    const keyfile: std.fs.File = b: {
        inline for (.{ VPD_KEY, FW_CFG_KEY }) |keypath| {
            if (std.fs.cwd().openFile(keypath, .{})) |file| {
                break :b file;
            } else |err| {
                switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                }
            }
        }

        break :b null;
    } orelse return error.MissingKey;

    defer keyfile.close();

    const keyring_id = try addKeyring(IMA_KEYRING_NAME, KeySerial.User);
    std.log.info("added ima keyring (id = 0x{x})", .{keyring_id});

    var buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const keyfile_contents = try keyfile.readToEndAlloc(fba.allocator(), buf.len);

    const key_id = try addKey(keyring_id, keyfile_contents);
    std.log.info("added verification key (id = 0x{x})", .{key_id});

    if (std.mem.eql(u8, keyfile_contents, TEST_KEY)) {
        std.log.warn("test key in use!", .{});
    }
}

// Initialize the IMA subsystem in linux to perform measurements and optionally
// appraisals (verification) of boot components. We always do measured boot
// with IMA since we basically get it for free; measurements are held in memory
// and persisted across kexecs, and the measurements are extended to the
// system's TPM if one is available.
pub fn initializeSecurity() !void {
    var buf: [MAX_POLICY_SIZE]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    var ima_policy = std.ArrayList(u8).init(allocator);
    defer ima_policy.deinit();

    try ima_policy.appendSlice(PROC_SUPER_MAGIC);
    try ima_policy.appendSlice(SYSFS_MAGIC);
    try ima_policy.appendSlice(DEBUGFS_MAGIC);
    try ima_policy.appendSlice(TMPFS_MAGIC);
    try ima_policy.appendSlice(DEVPTS_SUPER_MAGIC);
    try ima_policy.appendSlice(BINFMTFS_MAGIC);
    try ima_policy.appendSlice(SECURITYFS_MAGIC);
    try ima_policy.appendSlice(SELINUX_MAGIC);
    try ima_policy.appendSlice(SMACK_MAGIC);
    try ima_policy.appendSlice(CGROUP_SUPER_MAGIC);
    try ima_policy.appendSlice(CGROUP2_SUPER_MAGIC);
    try ima_policy.appendSlice(NSFS_MAGIC);
    try ima_policy.appendSlice(KEY_CHECK);
    try ima_policy.appendSlice(POLICY_CHECK);
    try ima_policy.appendSlice(KEXEC_KERNEL_CHECK);
    try ima_policy.appendSlice(KEXEC_INITRAMFS_CHECK);
    try ima_policy.appendSlice(KEXEC_CMDLINE);

    std.log.info("boot measurement is enabled", .{});

    if (loadVerificationKey()) {
        try ima_policy.appendSlice(KEXEC_KERNEL_CHECK_APPRAISE);
        try ima_policy.appendSlice(KEXEC_INITRAMFS_CHECK_APPRAISE);
        std.log.info("boot verification is enabled", .{});
    } else |err| {
        std.log.warn("failed to load verification key, cannot perform boot verification: {}", .{err});
    }

    try installImaPolicy(ima_policy.items);
}

// Each line in an IMA policy, including the last line, needs to be terminated
// with a single line feed.
fn withNewline(comptime line: []const u8) []const u8 {
    return line ++ "\n";
}

// https://qemu-project.gitlab.io/qemu/specs/fw_cfg.html
const FW_CFG_KEY = "/sys/firmware/qemu_fw_cfg/by_name/opt/org.tboot/pubkey/raw";

// The public key is held in VPD as a base64 encoded string.
// https://github.com/torvalds/linux/blob/master/drivers/firmware/google/vpd.c#L193
const VPD_KEY = "/sys/firmware/vpd/ro/pubkey";

// We are using the "_ima" keyring and not the ".ima" keyring since we do not use
// CONFIG_INTEGRITY_TRUSTED_KEYRING=y in our kernel config.
const IMA_KEYRING_NAME = "_ima";

const KeySerial = enum {
    User,

    fn to_keyring(self: @This()) i32 {
        return switch (self) {
            .User => linux_headers.KEY_SPEC_USER_KEYRING,
        };
    }
};

// https://git.kernel.org/pub/scm/linux/kernel/git/dhowells/keyutils.git/tree/keyctl.c#n705
fn addKeyring(name: [*:0]const u8, key_serial: KeySerial) !usize {
    const key_type: [*:0]const u8 = "keyring";

    const keyring = key_serial.to_keyring();

    const key_content: ?[*:0]const u8 = null;

    const rc = system.syscall5(
        system.SYS.add_key,
        @intFromPtr(key_type),
        @intFromPtr(name),
        @intFromPtr(key_content),
        0,
        @as(u32, @bitCast(keyring)),
    );

    switch (posix.errno(rc)) {
        .SUCCESS => {
            return rc;
        },
        else => |err| {
            return posix.unexpectedErrno(err);
        },
    }
}

fn addKey(keyring_id: usize, key_content: []const u8) !usize {
    const key_type: [*:0]const u8 = "asymmetric";

    const key_desc: ?[*:0]const u8 = null;

    // see https://github.com/torvalds/linux/blob/59f3fd30af355dc893e6df9ccb43ace0b9033faa/security/keys/keyctl.c#L74
    const rc = system.syscall5(
        system.SYS.add_key,
        @intFromPtr(key_type),
        @intFromPtr(key_desc),
        @intFromPtr(key_content.ptr),
        key_content.len,
        keyring_id,
    );

    switch (posix.errno(rc)) {
        .SUCCESS => {
            return rc;
        },
        else => |err| return posix.unexpectedErrno(err),
    }
}
