use std::{os::fd::AsRawFd, thread::sleep, time::Duration};

use nix::libc;

fn main() {
    _ = tboot::system::setup_system();
    let stdout = std::fs::OpenOptions::new()
        .append(true)
        .open("/dev/kmsg")
        .expect("open /dev/kmsg failed");

    unsafe { libc::dup2(stdout.as_raw_fd(), libc::STDOUT_FILENO) };
    unsafe { libc::dup2(stdout.as_raw_fd(), libc::STDERR_FILENO) };

    for _ in 0..20 {
        println!("THIS IS A TEST");
        sleep(Duration::from_secs(1));
    }

    for i in 0..6 {
        println!("rebooting in {} seconds", 5 - i);
        sleep(Duration::from_secs(1));
    }

    unsafe {
        libc::reboot(libc::LINUX_REBOOT_CMD_RESTART);
    }
}
