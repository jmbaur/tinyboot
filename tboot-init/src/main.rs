pub(crate) mod block_device;
pub(crate) mod boot_loader;
pub(crate) mod cmd;
pub(crate) mod message;
pub(crate) mod shell;
const TICK_DURATION: Duration = Duration::from_secs(1);

use crate::{
    block_device::{handle_unmounting, mount_all_devs, MountMsg},
    boot_loader::{kexec_execute, kexec_load},
};
use log::{debug, error, info};
use message::InternalMsg;
use nix::{
    libc::{self},
    unistd,
};
use raw_sync::{
    events::{Event, EventInit, EventState},
    Timeout,
};
use shared_memory::ShmemConf;
use shell::run_shell;
use std::sync::mpsc;
use std::{
    ffi::CString,
    fs::Permissions,
    io::ErrorKind,
    os::{
        fd::AsRawFd,
        raw::{c_char, c_void},
        unix::prelude::PermissionsExt,
    },
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use syscalls::{syscall, Sysno};
use tboot::{block_device::BlockDevice, linux::LinuxBootEntry};

#[derive(Debug)]
enum SelectEntryError {
    Reboot,
    Poweroff,
    Io(std::io::Error),
}

impl From<std::io::Error> for SelectEntryError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

fn select_entry(
    state: &mut ServerState,
    internal_rx: &mut mpsc::Receiver<InternalMsg>,
) -> Result<LinuxBootEntry, SelectEntryError> {
    let mut selected_entry: Option<LinuxBootEntry> = None;

    loop {
        match internal_rx.recv() {
            Ok(InternalMsg::UserIsPresent) => {
                state.has_user_interaction = true;
            }
            Ok(InternalMsg::Command(cmd)) => {
                let shmem = ShmemConf::new().flink("/run/tboot.shmem").open().unwrap();
                let (tx_evt, _) = unsafe { Event::from_existing(shmem.as_ptr().add(256)) }.unwrap();

                match cmd {
                    cmd::Command::List => {
                        state
                            .block_devices
                            .iter()
                            .enumerate()
                            .for_each(|(dev_idx, dev)| {
                                println!("{}: {}", dev_idx + 1, dev.name);
                                dev.boot_entries.iter().enumerate().for_each(
                                    |(entry_idx, entry)| {
                                        println!("\t{}: {}", entry_idx + 1, entry.display);
                                        println!("\t\tlinux {:?}", entry.linux);
                                        println!("\t\tinitrd {:?}", entry.initrd);
                                        println!("\t\tcmdline {:?}", entry.cmdline);
                                    },
                                );
                            })
                    }
                    cmd::Command::Select((dev, entry)) => {
                        if let Some(dev) = state.block_devices.get(dev - 1) {
                            if let Some(entry) = dev.boot_entries.get(entry - 1) {
                                selected_entry = Some(entry.clone());
                            } else {
                                println!("entry {} not found", entry);
                            }
                        } else {
                            println!("device {} not found", dev);
                        }
                    }
                    cmd::Command::Boot => {
                        if let Some(selected_entry) = selected_entry {
                            return Ok(selected_entry);
                        } else if let Some(default_entry) = &state.default_entry {
                            return Ok(default_entry.clone());
                        } else {
                            println!("no entry selected and no default entry to boot from");
                        }
                    }
                    cmd::Command::Reboot => return Err(SelectEntryError::Reboot),
                    cmd::Command::Poweroff => return Err(SelectEntryError::Poweroff),
                };

                // signal to the client that it can produce a prompt
                tx_evt.set(EventState::Signaled).unwrap();
            }
            Ok(InternalMsg::Device(device)) => {
                // only start timeout when we actually have a device to boot
                if !state.found_first_device {
                    state.found_first_device = true;
                    state.start = Instant::now();
                }

                let new_timeout = device.timeout;
                if new_timeout > state.timeout {
                    state.timeout = new_timeout;
                }

                let new_entries = &device.boot_entries;

                // TODO(jared): improve selection of default device
                if state.default_entry.is_none() && !state.has_internal_device {
                    state.default_entry = new_entries.iter().find(|&entry| entry.default).cloned();

                    // Ensure that if none of the entries from the bootloader were marked as
                    // default, we still have some default entry to boot into.
                    if state.default_entry.is_none() {
                        state.default_entry = new_entries.first().cloned();
                    }

                    if let Some(entry) = &state.default_entry {
                        debug!("assigned default entry: {}", entry.display);
                    }
                }

                if !device.removable {
                    state.has_internal_device = true;
                }

                println!("found new device {}", device.name);
                state.block_devices.push(device);
            }
            Ok(InternalMsg::Tick) => {
                let elapsed = state.start.elapsed();

                // don't send TimeLeft response if timeout <= elapsed, this will panic
                if !state.has_user_interaction && state.timeout > elapsed {
                    let seconds_left = (state.timeout - elapsed).as_secs();
                    println!("booting in {} seconds", seconds_left);
                }

                // Timeout has occurred without any user interaction
                if !state.has_user_interaction && elapsed >= state.timeout {
                    if let Some(default_entry) = &state.default_entry {
                        return Ok(default_entry.clone());
                    }
                }
            }
            Err(e) => {
                error!("failed to receive internal msg: {e}");
            }
        }
    }
}

#[derive(Debug)]
enum PrepareBootError {
    SelectEntry(SelectEntryError),
    Io(std::io::Error),
    Nix(nix::Error),
}

impl From<SelectEntryError> for PrepareBootError {
    fn from(value: SelectEntryError) -> Self {
        Self::SelectEntry(value)
    }
}

impl From<std::io::Error> for PrepareBootError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<nix::Error> for PrepareBootError {
    fn from(value: nix::Error) -> Self {
        Self::Nix(value)
    }
}

struct ServerState {
    start: Instant,
    block_devices: Vec<BlockDevice>,
    found_first_device: bool,
    default_entry: Option<LinuxBootEntry>,
    has_internal_device: bool,
    has_user_interaction: bool,
    timeout: Duration,
}

impl Default for ServerState {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(10),
            start: Instant::now(),
            block_devices: Vec::new(),
            found_first_device: false,
            default_entry: None,
            has_internal_device: false,
            has_user_interaction: false,
        }
    }
}

fn handle_shell_input(interactive_tx: mpsc::Sender<InternalMsg>) -> anyhow::Result<()> {
    let shmem = ShmemConf::new()
        .size(2 * 4096 /* TODO(jared): calculate size */)
        .flink("/run/tboot.shmem")
        .force_create_flink()
        .create()?;

    std::fs::set_permissions("/run/tboot.shmem", Permissions::from_mode(0o770))?;
    let mut dev_shmem_path = PathBuf::from("/dev/shm");
    dev_shmem_path.push(
        shmem
            .get_os_id()
            .strip_prefix("/")
            .unwrap_or_else(|| shmem.get_os_id()),
    );
    unistd::chown(
        "/run/tboot.shmem",
        Some(tboot::TINYUSER_UID.into()),
        Some(tboot::TINYUSER_GID.into()),
    )?;
    unistd::chown(
        &dev_shmem_path,
        Some(tboot::TINYUSER_UID.into()),
        Some(tboot::TINYUSER_GID.into()),
    )?;

    let (rx_evt, _rx_used_bytes) = (unsafe { Event::new(shmem.as_ptr(), true) })
        .map_err(|e| anyhow::anyhow!("failed to create daemon rx event {e}"))?;
    let (_tx_evt, _tx_used_bytes) = (unsafe { Event::new(shmem.as_ptr().add(256), true) })
        .map_err(|e| anyhow::anyhow!("failed to create daemon tx event {e}"))?;

    std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .open("/run/tboot.ready")?;

    let cmd_loc = unsafe { shmem.as_ptr().add(2 * 256) };

    // Wait for user presence
    rx_evt.wait(Timeout::Infinite).unwrap();
    rx_evt.set(EventState::Clear).unwrap();
    _ = interactive_tx.send(InternalMsg::UserIsPresent);

    loop {
        rx_evt.wait(Timeout::Infinite).unwrap();
        rx_evt.set(EventState::Clear).unwrap();

        let cmd = unsafe { std::ptr::read(cmd_loc as *const cmd::Command) };

        _ = interactive_tx.send(InternalMsg::Command(cmd));
    }
}

fn prepare_boot(
    internal_tx: mpsc::Sender<InternalMsg>,
    mut internal_rx: mpsc::Receiver<InternalMsg>,
) -> Result<(), PrepareBootError> {
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        error!("failed to fork");
    } else if pid == 0 {
        // child

        // immediately drop permissions
        unsafe { libc::setregid(tboot::TINYUSER_GID, tboot::TINYUSER_GID) };
        unsafe { libc::setreuid(tboot::TINYUSER_UID, tboot::TINYUSER_UID) };

        loop {
            if let Err(e) = run_shell() {
                error!("shell failed: {e}");
                debug!("restarting shell");
            }
        }
    } else {
        // parent

        let mut state = ServerState::default();

        // TODO(jared): don't start ticking until we have at least one thing to boot from
        let tick_tx = internal_tx.clone();
        std::thread::spawn(move || {
            println!("press enter to stop boot");
            loop {
                std::thread::sleep(TICK_DURATION);
                if tick_tx.send(InternalMsg::Tick).is_err() {
                    break;
                }
            }
        });

        std::thread::spawn(move || loop {
            let interactive_tx = internal_tx.clone();
            if let Err(e) = handle_shell_input(interactive_tx) {
                error!("failed to handle shell input: {e}");
            }
        });

        loop {
            let res = select_entry(&mut state, &mut internal_rx);

            let entry = match res {
                Err(e) => {
                    if matches!(e, SelectEntryError::Reboot | SelectEntryError::Poweroff) {
                        // _ = server_msg_tx.send(ServerMessage::ServerDone);
                    }
                    return Err(e.into());
                }
                Ok(entry) => entry,
            };

            let linux = entry.linux.as_path();
            let initrd = entry.initrd.as_deref();
            let cmdline = entry.cmdline.unwrap_or_default();
            let cmdline = cmdline.as_str();

            match kexec_load(linux, initrd, cmdline) {
                Ok(()) => break,
                Err(e) => {
                    match e.kind() {
                        ErrorKind::PermissionDenied => {
                            error!("permission denied performing kexec load");
                            println!("permission denied performing kexec load");
                            // ServerError::ValidationFailed
                        }
                        k => {
                            error!("kexec load resulted in unknown error kind: {k}");
                            println!("kexec load resulted in unknown error kind: {k}");
                            // ServerError::Unknown
                        }
                    };
                    continue;
                }
            };
        }
    }

    Ok(())
}

// columns:
// keyring_id . . . . . . . keyring_name .
fn parse_proc_keys(contents: &str) -> Vec<(i32, &str, &str)> {
    contents
        .lines()
        .filter_map(|key| {
            let mut iter = key.split_ascii_whitespace();
            let Some(key_id) = iter.next() else {
                return None;
            };

            let Ok(key_id) = i32::from_str_radix(key_id, 16) else {
                return None;
            };

            // skip the next 7 columns
            for _ in 0..6 {
                _ = iter.next();
            }

            let Some(key_type) = iter.next() else {
                return None;
            };

            let Some(keyring) = iter.next().and_then(|keyring| keyring.strip_suffix(":")) else {
                return None;
            };

            Some((key_id, key_type, keyring))
        })
        .collect()
}

// https://github.com/torvalds/linux/blob/3b517966c5616ac011081153482a5ba0e91b17ff/security/integrity/digsig.c#L193
fn load_x509_key() -> anyhow::Result<()> {
    let all_keys = std::fs::read_to_string("/proc/keys")?;
    let all_keys = parse_proc_keys(&all_keys);
    let ima_keyring_id = all_keys
        .into_iter()
        .find_map(|(key_id, key_type, keyring)| {
            if key_type != "keyring" {
                return None;
            }

            if keyring != ".ima" {
                return None;
            }

            Some(key_id)
        });

    let Some(ima_keyring_id) = ima_keyring_id else {
        anyhow::bail!(".ima keyring not found");
    };

    let pub_key = std::fs::read("/etc/keys/x509_ima.der")?;

    let key_type = CString::new("asymmetric")?;
    let key_desc: *const c_char = std::ptr::null();

    // see https://github.com/torvalds/linux/blob/59f3fd30af355dc893e6df9ccb43ace0b9033faa/security/keys/keyctl.c#L74
    let key_id = unsafe {
        syscall!(
            Sysno::add_key,
            key_type.as_ptr(),
            key_desc,
            pub_key.as_ptr() as *const c_void,
            pub_key.len(),
            ima_keyring_id
        )?
    };

    info!("added ima key with id: {:?}", key_id);

    // only install the IMA policy after we have loaded the key
    std::fs::copy("/etc/ima/policy.conf", "/sys/kernel/security/ima/policy")?;

    Ok(())
}

const VERSION: Option<&'static str> = option_env!("version");

pub fn main() -> anyhow::Result<()> {
    _ = tboot::system::setup_system();

    let args: Vec<String> = std::env::args().collect();
    let cfg = tboot::config::Config::from_args(&args)?;

    if (unsafe { libc::getuid() }) != 0 {
        panic!("tinyboot not running as root")
    }

    std::fs::copy("/etc/resolv.conf.static", "/etc/resolv.conf")
        .expect("failed to copy static resolv.conf to dynamic one");

    fern::Dispatch::new()
        .format(|out, message, record| out.finish(format_args!("[{}] {}", record.level(), message)))
        .level(cfg.log_level)
        .chain(std::io::stderr())
        .apply()
        .expect("failed to setup logging");

    let mut tty = PathBuf::from("/dev");
    tty.push(cfg.tty);
    if let Ok(tty) = std::fs::OpenOptions::new()
        .write(true)
        .read(true)
        .open(&tty)
    {
        let fd = tty.as_raw_fd();
        unsafe { libc::dup2(fd, libc::STDIN_FILENO) };
        unsafe { libc::dup2(fd, libc::STDOUT_FILENO) };
        unsafe { libc::dup2(fd, libc::STDERR_FILENO) };
        _ = tboot::system::setup_tty(fd);
    } else {
        error!("unable to open tty {}", tty.display());
    }

    println!(
        "{} tinyboot {}",
        "=".repeat(3),
        "=".repeat(80 - 3 - " tinyboot ".len())
    );
    info!("version {}", VERSION.unwrap_or("devel"));
    info!("{}", cfg);

    if let Err(e) = load_x509_key() {
        error!("failed to load x509 keys for IMA: {:?}", e);
    }

    loop {
        let (internal_tx, internal_rx) = mpsc::channel::<InternalMsg>();
        let (mount_tx, mount_rx) = mpsc::channel::<MountMsg>();

        let done = Arc::new(AtomicBool::new(false));
        let mount_handle = mount_all_devs(internal_tx.clone(), mount_tx.clone(), done.clone());

        let unmount_handle = handle_unmounting(mount_rx);

        let res = prepare_boot(internal_tx, internal_rx);

        done.store(true, Ordering::Relaxed);

        if mount_tx.send(MountMsg::UnmountAll).is_ok() {
            // wait for unmounting to finish
            info!("waiting for disks to be unmounted");
            _ = mount_handle;
            _ = unmount_handle;
        }

        match res {
            Ok(()) => {
                info!("kexec'ing");
                kexec_execute()?
            }
            Err(PrepareBootError::SelectEntry(SelectEntryError::Reboot)) => {
                info!("rebooting");
                unsafe {
                    libc::reboot(libc::LINUX_REBOOT_CMD_RESTART);
                }
            }
            Err(PrepareBootError::SelectEntry(SelectEntryError::Poweroff)) => {
                info!("powering off");
                unsafe {
                    libc::reboot(libc::LINUX_REBOOT_CMD_POWER_OFF);
                }
            }
            Err(e) => error!("failed to prepare boot: {e:?}"),
        }
    }
}

#[cfg(test)]
mod tests {

    #[test]
    fn parse_proc_keys() {
        let proc_keys = r#"
3b7511b0 I--Q---     1 perm 0b0b0000     0     0 user      invocation_id: 16
"#;
        assert_eq!(
            super::parse_proc_keys(proc_keys),
            vec![(997527984, "user", "invocation_id")]
        );
    }
}
