use std::{fs::Permissions, os::unix::prelude::PermissionsExt, process::Child};

use nix::{
    libc::{
        self, B115200, CBAUD, CBAUDEX, CLOCAL, CREAD, CRTSCTS, CSIZE, CSTOPB, ECHO, ECHOCTL, ECHOE,
        ECHOK, ECHOKE, HUPCL, ICANON, ICRNL, IEXTEN, ISIG, IXOFF, IXON, ONLCR, OPOST, PARENB,
        PARODD, TCSANOW, VEOF, VERASE, VINTR, VKILL, VQUIT, VSTART, VSTOP, VSUSP,
    },
    mount::MsFlags,
};
use termios::{cfgetispeed, cfgetospeed, cfsetispeed, cfsetospeed, tcsetattr, Termios};

pub fn setup_system() -> Child {
    std::fs::create_dir_all("/proc").expect("failed to create /proc");
    std::fs::create_dir_all("/sys").expect("failed to create /sys");
    std::fs::create_dir_all("/dev").expect("failed to create /dev");
    std::fs::create_dir_all("/run").expect("failed to create /run");
    std::fs::create_dir_all("/mnt").expect("failed to create /mnt");

    nix::mount::mount(
        None::<&str>,
        "/proc",
        Some("proc"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        None::<&str>,
    )
    .expect("failed to mount to /proc");

    nix::mount::mount(
        None::<&str>,
        "/dev",
        Some("devtmpfs"),
        MsFlags::MS_NOSUID,
        None::<&str>,
    )
    .expect("failed to mount to /dev");

    nix::mount::mount(
        None::<&str>,
        "/sys",
        Some("sysfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC | MsFlags::MS_RELATIME,
        None::<&str>,
    )
    .expect("failed to mount to /sys");

    nix::mount::mount(
        None::<&str>,
        "/run",
        Some("tmpfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        None::<&str>,
    )
    .expect("failed to mount to /run");

    nix::mount::mount(
        None::<&str>,
        "/sys/kernel/security",
        Some("securityfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC | MsFlags::MS_RELATIME,
        None::<&str>,
    )
    .expect("failed to mount to /sys/kernel/securityfs");

    std::os::unix::fs::symlink("/proc/self/fd/0", "/dev/stdin")
        .expect("failed to link to /dev/stdin");
    std::os::unix::fs::symlink("/proc/self/fd/1", "/dev/stdout")
        .expect("failed to link to /dev/stdout");
    std::os::unix::fs::symlink("/proc/self/fd/2", "/dev/stderr")
        .expect("failed to link to /dev/stderr");

    // set permissions on /run
    std::fs::set_permissions("/run", Permissions::from_mode(0o777))
        .expect("failed to set permissions on /run");

    // some programs like to create locks in this directory
    std::fs::create_dir_all("/run/lock").expect("failed to create /run/lock");

    std::fs::create_dir_all("/dev/pts").expect("failed to create /dev/pts");
    nix::mount::mount(
        None::<&str>,
        "/dev/pts",
        Some("devpts"),
        MsFlags::MS_NOSUID | MsFlags::MS_NOEXEC | MsFlags::MS_RELATIME,
        None::<&str>,
    )
    .expect("failed to mount to /dev/pts");

    std::fs::create_dir_all("/dev/shm").expect("failed to create /dev/shm");
    nix::mount::mount(
        None::<&str>,
        "/dev/shm",
        Some("tmpfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        None::<&str>,
    )
    .expect("failed to mount to /dev/shm");

    // set permissions on /dev/shm
    std::fs::set_permissions("/dev/shm", Permissions::from_mode(0o777))
        .expect("failed to set permissions on /dev/shm");

    // TODO(jared): don't use mdevd
    let mdev = std::process::Command::new("/bin/mdevd")
        .spawn()
        .expect("failed to start mdevd");

    mdev
}

// Adapted from https://github.com/mirror/busybox/blob/2d4a3d9e6c1493a9520b907e07a41aca90cdfd94/init/init.c#L341
pub fn setup_tty(fd: i32) -> anyhow::Result<()> {
    let mut tty = Termios::from_fd(fd)?;

    tty.c_cc[VINTR] = 3; // C-c
    tty.c_cc[VQUIT] = 28; // C-\
    tty.c_cc[VERASE] = 127; // C-?
    tty.c_cc[VKILL] = 21; // C-u
    tty.c_cc[VEOF] = 4; // C-d
    tty.c_cc[VSTART] = 17; // C-q
    tty.c_cc[VSTOP] = 19; // C-s
    tty.c_cc[VSUSP] = 26; // C-z

    tty.c_cflag &= CBAUD | CBAUDEX | CSIZE | CSTOPB | PARENB | PARODD | CRTSCTS;
    tty.c_cflag |= CREAD | HUPCL | CLOCAL;

    // input modes
    tty.c_iflag = ICRNL | IXON | IXOFF;

    // output modes
    tty.c_oflag = OPOST | ONLCR;

    // local modes
    tty.c_lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | IEXTEN;

    // set baud speed
    let baud_rate = 115200;
    if cfgetispeed(&tty) != baud_rate {
        cfsetispeed(&mut tty, B115200)?;
    }
    if cfgetospeed(&tty) != baud_rate {
        cfsetospeed(&mut tty, B115200)?;
    }

    // set size if the size is zero
    let mut size = std::mem::MaybeUninit::<libc::winsize>::uninit();
    let ret = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ as _, &mut size) };
    if ret == 0 {
        let mut size = unsafe { size.assume_init() };
        if size.ws_row == 0 {
            size.ws_row = 24;
        }
        if size.ws_col == 0 {
            size.ws_col = 80;
        }

        unsafe { libc::ioctl(fd, libc::TIOCSWINSZ as _, &size as *const _) };
    }

    tcsetattr(fd, TCSANOW, &tty)?;

    Ok(())
}
