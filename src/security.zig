const std = @import("std");
const base64 = std.base64.standard;
const posix = std.posix;

const kexec_file_load_available = @import("./kexec/kexec.zig").kexec_file_load_available;

const linux_headers = @import("linux_headers");

const MEASURE_POLICY =
    PROC_SUPER_MAGIC ++
    SYSFS_MAGIC ++
    DEBUGFS_MAGIC ++
    TMPFS_MAGIC ++
    DEVPTS_SUPER_MAGIC ++
    BINFMTFS_MAGIC ++
    SECURITYFS_MAGIC ++
    SELINUX_MAGIC ++
    SMACK_MAGIC ++
    CGROUP_SUPER_MAGIC ++
    CGROUP2_SUPER_MAGIC ++
    NSFS_MAGIC ++
    KEY_CHECK ++
    POLICY_CHECK ++
    KEXEC_KERNEL_CHECK ++
    KEXEC_INITRAMFS_CHECK ++
    KEXEC_CMDLINE;

const APPRAISE_POLICY = KEXEC_KERNEL_CHECK_APPRAISE ++ KEXEC_INITRAMFS_CHECK_APPRAISE;

const MEASURE_AND_APPRAISE_POLICY = MEASURE_POLICY ++ APPRAISE_POLICY;

const IMA_POLICY_PATH = "/sys/kernel/security/ima/policy";

// Individual IMA policy lines below

// PROC_SUPER_MAGIC = 0x9fa0
const PROC_SUPER_MAGIC = withNewline("dont_measure fsmagic=0x9fa0");

// SYSFS_MAGIC = 0x62656572
const SYSFS_MAGIC = withNewline("dont_measure fsmagic=0x62656572");

// DEBUGFS_MAGIC = 0x64626720
const DEBUGFS_MAGIC = withNewline("dont_measure fsmagic=0x64626720");

// TMPFS_MAGIC = 0x01021994
const TMPFS_MAGIC = withNewline("dont_measure fsmagic=0x1021994");

// DEVPTS_SUPER_MAGIC=0x1cd1
const DEVPTS_SUPER_MAGIC = withNewline("dont_measure fsmagic=0x1cd1");

// BINFMTFS_MAGIC=0x42494e4d
const BINFMTFS_MAGIC = withNewline("dont_measure fsmagic=0x42494e4d");

// SECURITYFS_MAGIC=0x73636673
const SECURITYFS_MAGIC = withNewline("dont_measure fsmagic=0x73636673");

// SELINUX_MAGIC=0xf97cff8c
const SELINUX_MAGIC = withNewline("dont_measure fsmagic=0xf97cff8c");

// SMACK_MAGIC=0x43415d53
const SMACK_MAGIC = withNewline("dont_measure fsmagic=0x43415d53");

// CGROUP_SUPER_MAGIC=0x27e0eb
const CGROUP_SUPER_MAGIC = withNewline("dont_measure fsmagic=0x27e0eb");

// CGROUP2_SUPER_MAGIC=0x63677270
const CGROUP2_SUPER_MAGIC = withNewline("dont_measure fsmagic=0x63677270");

// NSFS_MAGIC=0x6e736673
const NSFS_MAGIC = withNewline("dont_measure fsmagic=0x6e736673");

const KEY_CHECK = withNewline("measure func=KEY_CHECK pcr=7");

const POLICY_CHECK = withNewline("measure func=POLICY_CHECK pcr=7");

const KEXEC_KERNEL_CHECK = withNewline("measure func=KEXEC_KERNEL_CHECK pcr=8");

const KEXEC_INITRAMFS_CHECK = withNewline("measure func=KEXEC_INITRAMFS_CHECK pcr=9");

const KEXEC_CMDLINE = withNewline("measure func=KEXEC_CMDLINE pcr=12");

const KEXEC_KERNEL_CHECK_APPRAISE = withNewline("appraise func=KEXEC_KERNEL_CHECK appraise_type=imasig|modsig");

const KEXEC_INITRAMFS_CHECK_APPRAISE = withNewline("appraise func=KEXEC_INITRAMFS_CHECK appraise_type=imasig|modsig");

fn installImaPolicy(policy: []const u8) !void {
    var policy_file = try std.fs.cwd().openFile(IMA_POLICY_PATH, .{ .mode = .write_only });
    defer policy_file.close();

    std.log.debug("writing IMA policy", .{});

    try policy_file.writeAll(policy);
}

const MAX_KEY_SIZE = 8192;

// The public key is held in VPD as a base64 encoded string.
// https://github.com/torvalds/linux/blob/master/drivers/firmware/google/vpd.c#L193
const VPD_KEY = "/sys/firmware/vpd/ro/pubkey";

fn loadVpdKey(allocator: std.mem.Allocator) ![]const u8 {
    const vpd_key = std.fs.cwd().openFile(
        VPD_KEY,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingKey,
        else => return err,
    };
    defer vpd_key.close();

    const contents = try vpd_key.readToEndAlloc(allocator, MAX_KEY_SIZE);
    defer allocator.free(contents);
    const out_size = try base64.Decoder.calcSizeForSlice(contents);
    var out_buf = try allocator.alloc(u8, out_size);

    try base64.Decoder.decode(out_buf[0..], contents);
    return out_buf;
}

// https://qemu-project.gitlab.io/qemu/specs/fw_cfg.html
const QEMU_FW_CFG_KEY = "/sys/firmware/qemu_fw_cfg/by_name/opt/org.tboot/pubkey/raw";

fn loadQemuFwCfgKey(allocator: std.mem.Allocator) ![]const u8 {
    const fw_cfg_key = std.fs.cwd().openFile(
        QEMU_FW_CFG_KEY,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingKey,
        else => return err,
    };
    defer fw_cfg_key.close();

    return try fw_cfg_key.readToEndAlloc(allocator, MAX_KEY_SIZE);
}

// https://github.com/torvalds/linux/blob/3b517966c5616ac011081153482a5ba0e91b17ff/security/integrity/digsig.c#L193
fn loadVerificationKey(allocator: std.mem.Allocator) !void {
    const keyring_id = try addKeyring(IMA_KEYRING_NAME, KeySerial.User);
    std.log.info("added ima keyring (id=0x{x})", .{keyring_id});

    inline for (.{ loadVpdKey, loadQemuFwCfgKey }) |load_key_fn| {
        if (load_key_fn(allocator)) |pubkey| {
            defer allocator.free(pubkey);

            const key_id = try addKey(keyring_id, pubkey);

            std.log.info("added verification key (id=0x{x})", .{key_id});

            return;
        } else |err| switch (err) {
            error.MissingKey => {},
            else => return err,
        }
    }

    return error.MissingKey;
}

// Initialize the IMA subsystem in linux to perform measurements and optionally
// appraisals (verification) of boot components. We always do measured boot
// with IMA since we basically get it for free; measurements are held in memory
// and persisted across kexecs, and the measurements are extended to the
// system's TPM if one is available.
pub fn initializeSecurity(allocator: std.mem.Allocator) !void {
    if (!kexec_file_load_available) {
        std.log.warn("platform does not have kexec_file_load(), skipping security setup", .{});
        return;
    }

    if (loadVerificationKey(allocator)) {
        try installImaPolicy(MEASURE_AND_APPRAISE_POLICY);
        std.log.info("boot measurement and verification is enabled", .{});
    } else |err| {
        std.log.warn("failed to load verification key, cannot perform boot verification: {}", .{err});
        try installImaPolicy(MEASURE_POLICY);
        std.log.info("boot measurement is enabled", .{});
    }
}

// Each line in an IMA policy, including the last line, needs to be terminated
// with a single line feed.
fn withNewline(comptime line: []const u8) []const u8 {
    return line ++ "\n";
}

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

    const rc = std.os.linux.syscall5(
        .add_key,
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
    const rc = std.os.linux.syscall5(
        .add_key,
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
