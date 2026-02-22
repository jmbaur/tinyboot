const std = @import("std");
const linux_headers = @import("linux_headers");
const ioctl = std.os.linux.ioctl;
const E = std.os.linux.E;

const liveupdate_ioctl_create_session = linux_headers.liveupdate_ioctl_create_session;
const liveupdate_ioctl_retrieve_session = linux_headers.liveupdate_ioctl_retrieve_session;
const liveupdate_session_finish = linux_headers.liveupdate_session_finish;
const liveupdate_session_preserve_fd = linux_headers.liveupdate_session_preserve_fd;
const liveupdate_session_retrieve_fd = linux_headers.liveupdate_session_retrieve_fd;
const LIVEUPDATE_IOCTL_CREATE_SESSION = linux_headers.LIVEUPDATE_IOCTL_CREATE_SESSION;
const LIVEUPDATE_IOCTL_RETRIEVE_SESSION = linux_headers.LIVEUPDATE_IOCTL_RETRIEVE_SESSION;
const LIVEUPDATE_SESSION_FINISH = linux_headers.LIVEUPDATE_SESSION_FINISH;
const LIVEUPDATE_SESSION_PRESERVE_FD = linux_headers.LIVEUPDATE_SESSION_PRESERVE_FD;
const LIVEUPDATE_SESSION_RETRIEVE_FD = linux_headers.LIVEUPDATE_SESSION_RETRIEVE_FD;

const LiveUpdate = @This();

const session_name = "tinyboot";
pub const liveupdate_chardev = "/dev/liveupdate";

// We can be doing one of two things: preserving or retrieving.
// Preserving is usually meant for the first kernel, while retrieving
// is meant for the second kernel.
pub const OpMode = enum {
    preserve,
    retrieve,
};

op_mode: OpMode,
liveupdate: std.fs.File,
session_fd: std.posix.fd_t,

pub fn init(op_mode: OpMode) !LiveUpdate {
    var liveupdate = try std.fs.cwd().openFile(liveupdate_chardev, .{ .mode = .read_write });
    errdefer liveupdate.close();

    const session_fd = b: switch (op_mode) {
        .preserve => {
            var session = std.mem.zeroes(liveupdate_ioctl_create_session);
            session.size = @sizeOf(@TypeOf(session));
            std.mem.copyForwards(u8, &session.name, session_name);

            switch (E.init(ioctl(
                liveupdate.handle,
                LIVEUPDATE_IOCTL_CREATE_SESSION,
                @intFromPtr(&session),
            ))) {
                .SUCCESS => {},
                .NOMEM => return error.OutOfMemory,
                .EXIST => return error.SessionExists, // session with the same name already exists
                else => |err| return std.posix.unexpectedErrno(err),
            }

            break :b session.fd;
        },
        .retrieve => {
            var retrieve_session = std.mem.zeroes(liveupdate_ioctl_retrieve_session);
            retrieve_session.size = @sizeOf(@TypeOf(retrieve_session));
            std.mem.copyForwards(u8, &retrieve_session.name, session_name);

            switch (E.init(ioctl(
                liveupdate.handle,
                LIVEUPDATE_IOCTL_RETRIEVE_SESSION,
                @intFromPtr(&retrieve_session),
            ))) {
                .SUCCESS => {},
                .NOENT => return error.SessionNotFound,
                .INVAL => return error.SessionRetrieved, // session was already retrieved
                else => |err| return std.posix.unexpectedErrno(err),
            }

            break :b retrieve_session.fd;
        },
    };

    return .{
        .op_mode = op_mode,
        .liveupdate = liveupdate,
        .session_fd = session_fd,
    };
}

/// Should only be called in the case where a session should _not_ persist
/// across kexec reboots, for example as a part of error handling. Closing the
/// session file descriptor will prevent persisting the session's FDs across
/// kexec reboots.
pub fn closeSession(self: *LiveUpdate) void {
    if (self.op_mode != .preserve) {
        std.log.warn(
            "Running in liveupdate {} mode, {s} is a no-op",
            .{ self.op_mode, @src().fn_name },
        );
        return;
    }

    std.posix.close(self.session_fd);
}

pub fn deinit(self: *LiveUpdate) void {
    if (self.op_mode == .retrieve) {
        var session_finish = std.mem.zeroes(liveupdate_session_finish);
        session_finish.size = @sizeOf(@TypeOf(session_finish));
        _ = ioctl(
            self.session_fd,
            LIVEUPDATE_SESSION_FINISH,
            @intFromPtr(&session_finish),
        );
        std.posix.close(self.session_fd);
    }

    // We do not close the session file descriptor if we are not retrieving,
    // since then the state will not persist across kernels.

    self.liveupdate.close();

    self.* = undefined;
}

pub fn preserve(self: *LiveUpdate, fd: std.posix.fd_t, token: usize) !void {
    var preserve_fd = std.mem.zeroes(liveupdate_session_preserve_fd);
    preserve_fd.size = @sizeOf(@TypeOf(preserve_fd));
    preserve_fd.fd = fd;
    preserve_fd.token = token;
    switch (E.init(std.os.linux.ioctl(
        self.session_fd,
        LIVEUPDATE_SESSION_PRESERVE_FD,
        @intFromPtr(&preserve_fd),
    ))) {
        .SUCCESS => {},
        .EXIST => return error.TokenAlreadyUsed,
        .BADF => return error.InvalidFileDescriptor,
        .NOSPC => return error.LiveupdateFilesetFull,
        .NOENT => return error.HandlerNotFound,
        .NOMEM => return error.OutOfMemory,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub fn retrieve(self: *LiveUpdate, token: usize) !std.posix.fd_t {
    var retrieve_fd = std.mem.zeroes(liveupdate_session_retrieve_fd);
    retrieve_fd.size = @sizeOf(@TypeOf(retrieve_fd));
    retrieve_fd.token = token;
    switch (E.init(ioctl(
        self.session_fd,
        LIVEUPDATE_SESSION_RETRIEVE_FD,
        @intFromPtr(&retrieve_fd),
    ))) {
        .SUCCESS => {},
        .NOENT => return error.TokenNotFound,
        else => |err| return std.posix.unexpectedErrno(err),
    }

    return retrieve_fd.fd;
}
