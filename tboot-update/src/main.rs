use nix::libc;
use std::{os::fd::AsRawFd, path::PathBuf, thread::sleep, time::Duration};

fn update() -> std::io::Result<()> {
    tboot::system::setup_system();

    let args: Vec<String> = std::env::args().collect();
    let cfg = tboot::config::Config::from_args(&args);

    if let Ok(tty) = std::fs::OpenOptions::new()
        .write(true)
        .read(true)
        .open(PathBuf::from("/dev").join(cfg.tty))
    {
        let fd = tty.as_raw_fd();
        unsafe { libc::dup2(fd, libc::STDIN_FILENO) };
        unsafe { libc::dup2(fd, libc::STDOUT_FILENO) };
        unsafe { libc::dup2(fd, libc::STDERR_FILENO) };
        _ = tboot::system::setup_tty(fd);
    }

    let mut flashrom = std::process::Command::new("/bin/flashrom");

    println!("using flashrom programmer {}", cfg.programmer);

    let output = flashrom
        .args(&[
            "-p",
            cfg.programmer,
            "-w",
            "/update.rom",
            "--fmap",
            "-i",
            "RW_SECTION_A",
        ])
        .output()?;

    if output.status.success() {
        println!("flashrom succeeded");
    } else {
        eprintln!(
            "flashrom failed with status {}",
            output.status.code().unwrap()
        );
        eprintln!(
            "flashrom error output:\n{}\n{}",
            String::from_utf8(output.stdout).expect("stdout not utf8"),
            String::from_utf8(output.stderr).expect("stderr not utf8")
        );
    }

    Ok(())
}

fn main() {
    tboot::nologin::detect_nologin();

    if let Err(e) = update() {
        eprintln!("failed to update: {}", e);
    }

    for i in 0..16 {
        println!("rebooting in {} seconds", 15 - i);
        sleep(Duration::from_secs(1));
    }

    unsafe {
        libc::reboot(libc::LINUX_REBOOT_CMD_RESTART);
    }
}
