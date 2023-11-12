pub(crate) mod boot_loader;
pub(crate) mod cmd;
pub(crate) mod fs;
pub(crate) mod kexec;
pub(crate) mod keys;
pub(crate) mod shell;

const VERSION: Option<&'static str> = option_env!("version");
const TICK_DURATION: Duration = Duration::from_secs(1);

use crate::{
    cmd::Command,
    kexec::{kexec_execute, kexec_load},
};
use boot_loader::{disk::BlsBootLoader, Loader, LoaderType};
use cmd::print_help;
use log::{debug, error, info, warn, LevelFilter};
use nix::libc::{self};
use shell::{run_shell, wait_for_user_presence};
use std::{io::Write, time::Duration};
use std::{os::fd::AsRawFd, path::PathBuf, sync::mpsc};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClientToServer {
    Command(Command),
    UserIsPresent,
}

#[derive(Clone, Debug)]
pub enum ServerToClient {
    ServerIsReady,
    Stop,
}

enum Outcome {
    Reboot,
    Poweroff,
    Kexec,
}

fn prepare_boot() -> anyhow::Result<Outcome> {
    let (client_tx, server_rx) = mpsc::channel::<ClientToServer>();
    let (server_tx, client_rx) = mpsc::channel::<ServerToClient>();

    let user_presence_tx = client_tx.clone();
    let user_presence_thread = std::thread::spawn(move || wait_for_user_presence(user_presence_tx));

    let mut user_is_present = false;
    let mut outcome: Option<Outcome> = None;
    let mut stdout = std::io::stdout();

    // TODO(jared): fetch boot order from some nonvolatile storage
    let boot_loaders: Vec<Loader> = vec![Loader::new(Box::new(BlsBootLoader::new()))];

    'autoboot: for loader in boot_loaders {
        let mut loader = Loader::from(loader);

        match loader.boot_devices() {
            Err(e) => {
                error!("failed to probe loader: {e}");
                continue;
            }
            Ok(boot_devices) => {
                for boot_dev in boot_devices {
                    info!("using boot device {}", boot_dev.name);

                    println!("press <ENTER> to stop boot");

                    print!("booting in ");
                    stdout.flush().expect("flush failed");

                    let mut time_left = boot_dev.timeout;
                    while !time_left.is_zero() {
                        print!("{}.", time_left.as_secs());
                        stdout.flush().expect("flush failed");

                        match server_rx.recv_timeout(TICK_DURATION) {
                            Ok(ClientToServer::UserIsPresent) => {
                                user_is_present = true;
                                break 'autoboot;
                            }
                            _ => {}
                        }

                        time_left -= TICK_DURATION;
                    }
                    println!();

                    if boot_dev.entries.is_empty() {
                        info!("boot device {} contains no entries", boot_dev.name);
                        continue;
                    } else {
                        let mut entries = boot_dev.entries.iter();
                        let first_entry = entries.next().expect("boot device has no entries");

                        let default_entry = 'default: {
                            while let Some(entry) = entries.next() {
                                if entry.is_default() {
                                    break 'default entry;
                                }
                            }
                            first_entry
                        };

                        let boot_parts = default_entry.select();

                        match kexec_load(boot_parts) {
                            Ok(()) => {
                                outcome = Some(Outcome::Kexec);
                                break 'autoboot;
                            }
                            Err(e) => {
                                error!("failed to kexec load: {e}");
                                outcome = None;
                                break 'autoboot;
                            }
                        }
                    }
                }
            }
        }
    }

    if let Some(outcome) = outcome {
        Ok(outcome)
    } else {
        if !user_is_present {
            error!("failed to boot");
            print!("press <ENTER> to enter interactive mode");
            stdout.flush().expect("flush failed");

            assert_eq!(server_rx.recv().unwrap(), ClientToServer::UserIsPresent);
        }

        user_presence_thread
            .join()
            .expect("failed to join user presence thread");

        let shell_thread = std::thread::spawn(move || run_shell(client_tx, client_rx));
        let outcome = handle_commands(server_tx, server_rx);

        shell_thread.join().expect("failed to join shell thread");

        Ok(outcome)
    }
}

fn handle_commands(
    server_tx: mpsc::Sender<ServerToClient>,
    server_rx: mpsc::Receiver<ClientToServer>,
) -> Outcome {
    let mut loader: Option<Loader> = None;

    loop {
        // ensure that stdout buffer is flushed before indicating that the server is ready to
        // receive new commands
        std::io::stdout().flush().unwrap();
        server_tx.send(ServerToClient::ServerIsReady).unwrap();

        match server_rx.recv().unwrap() {
            ClientToServer::UserIsPresent => {}
            ClientToServer::Command(Command::Shell) => {
                if std::process::Command::new("/bin/busybox")
                    .arg("sh")
                    .env("TERM", "linux")
                    .status()
                    .is_err()
                {
                    error!("failed to run shell");
                }
            }
            ClientToServer::Command(Command::Dmesg(level)) => {
                match tboot::system::kernel_logs(level) {
                    Ok(logs) => println!("{logs}"),
                    Err(e) => error!("failed to get kernel logs: {e}"),
                }
            }
            ClientToServer::Command(Command::Help(help)) => {
                print_help(help.as_deref());
            }
            ClientToServer::Command(Command::Reboot) => {
                server_tx.send(ServerToClient::Stop).unwrap();
                return Outcome::Reboot;
            }
            ClientToServer::Command(Command::Poweroff) => {
                server_tx.send(ServerToClient::Stop).unwrap();
                return Outcome::Poweroff;
            }
            ClientToServer::Command(Command::Rescan) => match loader {
                None => println!("no loader selected"),
                Some(ref mut loader) => {
                    if let Err(e) = loader.probe(true) {
                        error!("failed to rescan: {e}");
                    }
                }
            },
            ClientToServer::Command(Command::List) => match loader {
                None => println!("no loader selected"),
                Some(ref mut loader) => match loader.boot_devices() {
                    Err(e) => println!("failed to get boot devices: {e}"),
                    Ok(devs) => {
                        devs.iter().enumerate().for_each(|(dev_idx, dev)| {
                            println!("{}: {}", dev_idx + 1, dev.name);

                            dev.entries
                                .iter()
                                .enumerate()
                                .for_each(|(entry_idx, entry)| {
                                    println!("   {}: {}", entry_idx + 1, entry);
                                });
                        });
                    }
                },
            },
            ClientToServer::Command(Command::Boot((dev_idx, entry_idx))) => match loader {
                None => println!("no loader selected"),
                Some(ref mut loader) => {
                    match loader.boot_devices().map(|devs| {
                        let Some(boot_dev) = dev_idx
                            .map(|dev_idx| dev_idx.checked_sub(1).map(|idx| devs.get(idx)))
                            .flatten()
                            .unwrap_or_else(|| devs.first())
                        else {
                            return None;
                        };

                        entry_idx
                            .map(|entry_idx| {
                                entry_idx
                                    .checked_sub(1)
                                    .map(|idx| boot_dev.entries.get(idx))
                            })
                            .flatten()
                            .unwrap_or_else(|| {
                                boot_dev.entries.iter().find(|entry| entry.is_default())
                            })
                    }) {
                        Ok(Some(entry)) => {
                            println!("selected entry '{}'", entry);

                            if let Err(e) = kexec_load(entry.select()) {
                                println!("failed to load entry: {e}");
                            } else {
                                server_tx.send(ServerToClient::Stop).unwrap();
                                return Outcome::Kexec;
                            }
                        }
                        Ok(None) => println!("cannot select non-existent entry"),
                        Err(e) => println!("failed to get entries: {e}"),
                    }
                }
            },
            ClientToServer::Command(Command::Loader(desired_loader)) => {
                if let Some(desired_loader) = desired_loader {
                    // shutdown the current loader
                    match loader {
                        Some(ref mut loader) => loader.shutdown(),
                        None => {}
                    };

                    // create the new loader
                    loader = Some(Loader::new(Box::new(match desired_loader {
                        LoaderType::Disk => BlsBootLoader::new(),
                    })));
                } else if let Some(ref mut loader) = loader {
                    println!("currently using '{}' loader", loader.loader_type());
                } else {
                    println!("no loader selected");
                }
            }
        }
    }
}

pub fn main() -> ! {
    tboot::nologin::detect_nologin();

    tboot::system::setup_system();

    let args: Vec<String> = std::env::args().collect();
    let cfg = tboot::config::Config::from_args(&args);

    if cfg.log_level >= LevelFilter::Debug {
        debug!("enabling backtrace printing");
        std::env::set_var("RUST_BACKTRACE", "full");
    }

    tboot::log::Logger::new(cfg.log_level)
        .setup()
        .expect("failed to setup logger");

    if (unsafe { libc::getuid() }) != 0 {
        warn!("tinyboot not running as root");
    }

    let tty = PathBuf::from("/dev").join(cfg.tty);
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

    let (new_dev_tx, new_dev_rx) = std::sync::mpsc::channel::<()>();

    // listen_and_create_devices prints logs, so make sure it starts after logging and output
    // console is setup
    std::thread::spawn(|| {
        // We must first run scan_and_create_devices since this code will run after some devices
        // have already been created by the linux kernel, so starting the listener will end up with
        // us missing a bunch of devices.
        tboot::dev::scan_and_create_devices();

        if let Err(e) = tboot::dev::listen_and_create_devices(new_dev_tx) {
            error!("listen_and_create_devices failed: {e}");
            panic!()
        }
    });

    println!(
        "{} tinyboot {}",
        "=".repeat(4),
        "=".repeat(80 - 4 - " tinyboot ".len())
    );
    info!("version {}", VERSION.unwrap_or("devel"));
    info!("{}", cfg);

    if let Err(e) = keys::load_verification_key() {
        error!("failed to load verification keys: {:?}", e);
        warn!("boot verification is OFF");
    } else {
        info!("boot verification is ON");
    }

    debug!("waiting for new events to settle");
    tboot::dev::wait_for_settle(new_dev_rx, Duration::from_secs(1));

    match prepare_boot() {
        Ok(Outcome::Kexec) => {
            debug!("kexec'ing");
            kexec_execute().expect("kexec execute failed")
        }
        Ok(Outcome::Reboot) => {
            debug!("rebooting");
            unsafe { libc::reboot(libc::LINUX_REBOOT_CMD_RESTART) };
        }
        Ok(Outcome::Poweroff) => {
            debug!("powering off");
            unsafe { libc::reboot(libc::LINUX_REBOOT_CMD_POWER_OFF) };
        }
        Err(e) => {
            error!("failed to boot: {e}");
            error!("powering off");
            std::thread::sleep(Duration::from_secs(5));
            unsafe { libc::reboot(libc::LINUX_REBOOT_CMD_POWER_OFF) };
        }
    };

    unreachable!("some variant of reboot should have occurred")
}
