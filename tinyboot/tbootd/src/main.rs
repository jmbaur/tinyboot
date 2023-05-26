pub(crate) mod block_device;
pub(crate) mod bls;
pub(crate) mod boot_loader;
pub(crate) mod device;
pub(crate) mod fs;
pub(crate) mod grub;
pub(crate) mod syslinux;
pub(crate) mod tpm;
pub(crate) mod util;
pub(crate) mod verify;

use crate::boot_loader::{kexec_execute, kexec_load, LinuxBootEntry};
use crate::fs::unmount;
use block_device::find_disks;
use clap::Parser;
use device::BlockDevice;
use kobject_uevent::UEvent;
use log::LevelFilter;
use log::{debug, error, info};
use netlink_sys::protocols::NETLINK_KOBJECT_UEVENT;
use netlink_sys::{Socket, SocketAddr};
use nix::libc;
use sha2::{Digest, Sha256};
use std::io::{self, Write};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{self, Command};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant};
use termion::event::Key;
use termion::input::TermRead;
use termion::raw::IntoRawMode;
use termion::{clear, cursor};

enum Msg {
    Key(Key),
    Device(BlockDevice),
    Tick,
}

fn select_entry(
    rx: Receiver<Msg>,
    mountpoints: &mut Vec<PathBuf>,
) -> anyhow::Result<LinuxBootEntry> {
    let start = Instant::now();

    let mut stdout = io::stdout().into_raw_mode()?;

    let mut timeout = Duration::from_secs(10);
    let mut boot_entries = Vec::new();
    let mut default_entry: Option<LinuxBootEntry> = None;

    let mut has_internal_device = false;

    let mut has_user_interaction = false;
    let mut user_input = String::new();

    loop {
        stdout.flush()?;
        match rx.recv()? {
            Msg::Device(device) => {
                debug!(
                    "getting boot entries on {:?}",
                    device.boot_partition_mountpoint
                );

                let bl = device.bootloader;
                mountpoints.push(device.boot_partition_mountpoint);

                let new_timeout = bl.timeout();
                if new_timeout > timeout {
                    timeout = new_timeout;
                }

                let new_entries = bl.boot_entries()?;
                let start_num = boot_entries.len();

                if default_entry.is_none() && !has_internal_device {
                    default_entry = new_entries.iter().find(|&entry| entry.default).cloned();

                    // Ensure that if none of the entries from the bootloader were marked as
                    // default, we still have some default entry to boot into.
                    if default_entry.is_none() {
                        default_entry = new_entries.first().cloned();
                    }

                    debug!("assigned default entry: {:?}", default_entry);
                }

                if !device.removable {
                    has_internal_device = true;
                }

                // print entries
                {
                    write!(stdout, "{}\r\n", "-".repeat(120))?;
                    write!(stdout, "{}\r\n", device.name)?;
                    for (i, entry) in new_entries.iter().enumerate() {
                        let is_default = default_entry
                            .as_ref()
                            .map(|e| e == entry)
                            .unwrap_or_default();

                        write!(
                            stdout,
                            "{}{}:      {}\r\n",
                            if is_default { "*" } else { " " },
                            start_num + i + 1,
                            entry.display
                        )?;
                    }
                }

                boot_entries.extend(new_entries);
            }
            Msg::Key(key) => {
                has_user_interaction = true;
                match key {
                    Key::Backspace => {
                        _ = user_input.pop();
                        write!(stdout, "{}{}", cursor::Left(1), clear::AfterCursor)?;
                    }
                    Key::Ctrl('u') => {
                        write!(
                            stdout,
                            "{}{}",
                            cursor::Left(user_input.len() as u16),
                            clear::AfterCursor
                        )?;
                        user_input.clear();
                    }
                    Key::Char('\n') => {
                        if user_input.is_empty() {
                            anyhow::bail!("no choice selected");
                        }

                        let Ok(num) = str::parse::<usize>(&user_input) else {
                                anyhow::bail!("did not input a number");
                            };

                        let Some(entry) = boot_entries.get(num - 1) else {
                                anyhow::bail!("boot entry does not exist");
                            };

                        return Ok(entry.clone());
                    }
                    Key::Char(c) => {
                        if c.is_ascii_digit() {
                            user_input.push(c);
                            write!(stdout, "{c}")?;
                        } else {
                            anyhow::bail!("not a numeric input");
                        }
                    }
                    Key::Ctrl('[') | Key::Ctrl('c') | Key::Ctrl('g') => anyhow::bail!("exit"),
                    _ => {}
                };
            }
            Msg::Tick => {
                // Timeout has occurred without any user interaction
                if !has_user_interaction && start.elapsed() >= timeout {
                    if let Some(default_entry) = default_entry {
                        return Ok(default_entry);
                    } else {
                        anyhow::bail!("no default entry");
                    }
                }
            }
        }
    }
}

fn boot() -> anyhow::Result<()> {
    let (tx, rx) = mpsc::channel::<Msg>();

    let tick_tx = tx.clone();
    thread::spawn(move || {
        let tick_duration = Duration::from_secs(1);
        loop {
            thread::sleep(tick_duration);
            if tick_tx.send(Msg::Tick).is_err() {
                break;
            }
        }
    });

    let dev_tx = tx.clone();
    thread::spawn(move || {
        // get disks that have already been discovered by the kernel
        match find_disks() {
            Err(e) => error!("failed to get initial block devices: {e}"),
            Ok(initial_devs) => {
                for dev in initial_devs {
                    if dev_tx.send(Msg::Device(dev)).is_err() {
                        break;
                    }
                }
            }
        };

        let mut socket = Socket::new(NETLINK_KOBJECT_UEVENT).unwrap();
        let sa = SocketAddr::new(0, 1 << 0);
        socket.bind(&sa).unwrap();

        let mut buf = bytes::BytesMut::with_capacity(1024 * 8);
        loop {
            buf.clear();
            let Ok(_) = socket.recv_from(&mut buf, 0) else {
                continue;
            };

            let n = buf.len();
            let Ok(uevent) = UEvent::from_netlink_packet(&buf[..n]) else {
                continue;
            };

            let Ok(bd) = BlockDevice::try_from(uevent) else {
                continue;
            };

            if dev_tx.send(Msg::Device(bd)).is_err() {
                break;
            }
        }
    });

    thread::spawn(move || {
        let mut keys = io::stdin().lock().keys();
        while let Some(Ok(key)) = keys.next() {
            if tx.send(Msg::Key(key)).is_err() {
                break;
            }
        }
    });

    let mut mountpoints = Vec::new();

    match select_entry(rx, &mut mountpoints) {
        Ok(entry) => {
            let linux = entry.linux.as_path();
            let initrd = entry.initrd.as_deref();
            let cmdline = entry.cmdline.unwrap_or_default();
            let cmdline = cmdline.as_str();

            let mut needs_pcr_reset = false;

            let verified_digest = if cfg!(feature = "verified-boot") {
                let key_digest = Sha256::digest(verify::PEM).to_vec();

                let mut verify_errors = vec![verify::verify_boot_payload(linux)];
                if let Some(initrd) = initrd {
                    verify_errors.push(verify::verify_boot_payload(initrd));
                }

                needs_pcr_reset = verify_errors.iter().any(|e| e.is_err());

                if needs_pcr_reset {
                    verify_errors
                        .iter()
                        .filter_map(|e| if let Err(e) = e { Some(e) } else { None })
                        .for_each(|e| error!("Failed to verify boot payload: {}", e));
                } else {
                    info!("Verified boot artifacts");
                }

                Some(key_digest)
            } else {
                None
            };

            kexec_load(linux, initrd, cmdline)?;

            if cfg!(feature = "measured-boot") {
                if !needs_pcr_reset {
                    let kernel_digest = tboot::hash::sha256_digest_file(linux)?;
                    let initrd_digest = initrd.map(tboot::hash::sha256_digest_file).transpose()?;
                    let cmdline_digest = Sha256::digest(cmdline).to_vec();

                    match tpm::measure_boot(
                        verified_digest,
                        (linux, kernel_digest),
                        (initrd, initrd_digest),
                        (cmdline, cmdline_digest),
                    ) {
                        Ok(()) => info!("Measured boot artifacts"),
                        Err(e) => {
                            error!("Failed to measure boot artifacts: {e}");
                            error!("This board may be misconfigured!!");
                        }
                    };
                } else if let Err(e) = tpm::reset_pcr_slots() {
                    error!("Failed to reset tinyboot-managed PCR slots: {e}");
                }
            }

            mountpoints.iter().for_each(|m| unmount(m));

            kexec_execute()?;
            Ok(())
        }
        Err(e) => {
            mountpoints.iter().for_each(|m| unmount(m));
            Err(e)
        }
    }
}

#[derive(Debug, Parser)]
struct Config {
    #[arg(long, value_parser, default_value_t = LevelFilter::Info)]
    log_level: LevelFilter,
}

const VERSION: Option<&'static str> = option_env!("version");

pub fn shell() -> anyhow::Result<()> {
    let mut cmd = Command::new("/bin/sh");
    let cmd = cmd
        .env_clear()
        .current_dir("/home/tinyuser")
        .uid(1000)
        .gid(1000)
        .arg("-l");
    let mut child = cmd.spawn()?;
    child.wait()?;

    Ok(())
}

fn main() -> anyhow::Result<()> {
    let cfg = Config::parse();

    tboot::log::setup_logging(cfg.log_level).expect("failed to setup logging");

    info!("running version {}", VERSION.unwrap_or("devel"));
    debug!("config: {:?}", cfg);

    if (unsafe { libc::getuid() }) != 0 {
        error!("tinyboot not running as root");
        process::exit(1);
    }

    loop {
        if let Err(e) = boot() {
            error!("{e}");
        }

        if let Err(e) = shell() {
            error!("{e}");
        }
    }
}
