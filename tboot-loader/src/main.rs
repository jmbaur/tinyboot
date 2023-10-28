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
use boot_loader::{disk::BlsBootLoader, LinuxBootEntry, LinuxBootLoader, Loader, LoaderType};
use cmd::print_help;
use log::{debug, error, info, warn, LevelFilter};
use nix::libc::{self};
use shell::{run_shell, wait_for_user_presence};
use std::{io::Write, time::Duration};
use std::{os::fd::AsRawFd, path::PathBuf, sync::mpsc};

#[derive(Clone, Debug)]
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

    let mut outcome: Option<Outcome> = None;

    // TODO(jared): fetch boot order from some nonvolatile storage
    let boot_loaders: Vec<Box<dyn LinuxBootLoader>> = vec![Box::new(BlsBootLoader::new())];

    let mut stdout = std::io::stdout();

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

                    println!("press ENTER to stop boot");

                    print!("booting in ");
                    stdout.flush().expect("flush failed");

                    let mut time_left = boot_dev.timeout;
                    while !time_left.is_zero() {
                        print!("{}.", time_left.as_secs());
                        stdout.flush().expect("flush failed");

                        match server_rx.recv_timeout(TICK_DURATION) {
                            Ok(ClientToServer::UserIsPresent) => break 'autoboot,
                            _ => {}
                        }

                        time_left -= TICK_DURATION;
                    }
                    println!();

                    if boot_dev.entries.is_empty() {
                        info!("boot device {} contains no entries", boot_dev.name);
                        continue;
                    } else {
                        let default_entry = boot_dev
                            .entries
                            .get(boot_dev.default_entry)
                            .unwrap_or_else(|| {
                                boot_dev.entries.first().expect("entries is non-empty")
                            });

                        match kexec_load(default_entry) {
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
        let client_thread = std::thread::spawn(move || run_shell(client_tx, client_rx));
        let outcome = handle_commands(server_tx, server_rx);
        user_presence_thread
            .join()
            .expect("failed to join user presence thread");
        client_thread.join().expect("failed to join client thread");
        Ok(outcome)
    }
}

fn handle_commands(
    server_tx: mpsc::Sender<ServerToClient>,
    server_rx: mpsc::Receiver<ClientToServer>,
) -> Outcome {
    let mut loader: Option<Loader> = None;
    let mut selected: Option<LinuxBootEntry> = None;

    loop {
        // ensure that stdout is flushed to before indicating that the server is ready to receive
        // new commands
        std::io::stdout().flush().unwrap();
        server_tx.send(ServerToClient::ServerIsReady).unwrap();

        match server_rx.recv().unwrap() {
            ClientToServer::UserIsPresent => {}
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
                                    println!("   {}: {}", entry_idx + 1, entry.display);
                                    println!("      linux {}", entry.linux.display());

                                    if let Some(initrd) = &entry.initrd {
                                        println!("      initrd {}", initrd.display());
                                    }

                                    if let Some(cmdline) = &entry.cmdline {
                                        println!("      cmdline {}", cmdline);
                                    }
                                });
                        });
                    }
                },
            },
            ClientToServer::Command(Command::Select((dev_idx, entry_idx))) => match loader {
                None => println!("no loader selected"),
                Some(ref mut loader) => {
                    match loader.boot_devices().map(|devs| {
                        let Some(dev_idx) = dev_idx.checked_sub(1) else {
                            return None;
                        };

                        devs.get(dev_idx)
                            .map(|dev| {
                                let Some(entry_idx) = entry_idx.checked_sub(1) else {
                                    return None;
                                };

                                dev.entries.get(entry_idx)
                            })
                            .flatten()
                    }) {
                        Ok(Some(entry)) => {
                            selected = Some(entry.clone());
                            println!("selected entry '{}'", entry.display);
                        }
                        Ok(None) => println!("cannot select non-existent entry"),
                        Err(e) => println!("failed to get entries: {e}"),
                    }
                }
            },
            ClientToServer::Command(Command::Boot) => {
                let entry = {
                    if let Some(entry) = selected.as_ref() {
                        Some(entry)
                    } else if let Some(Ok(Some(Some(default_entry)))) =
                        loader.as_mut().map(|loader| {
                            loader.boot_devices().map(|devs| {
                                devs.first()
                                    .map(|dev| dev.entries.first().map(|entry| entry))
                            })
                        })
                    {
                        Some(default_entry)
                    } else {
                        println!("no entry selected");
                        None
                    }
                };

                match entry.map(|entry| kexec_load(entry)) {
                    Some(Err(e)) => println!("failed to load entry: {e}"),
                    Some(Ok(_)) => {
                        server_tx.send(ServerToClient::Stop).unwrap();
                        return Outcome::Kexec;
                    }
                    None => {}
                }
            }
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

    if let Err(e) = std::fs::copy("/etc/resolv.conf.static", "/etc/resolv.conf") {
        error!("failed to copy static resolv.conf to /etc/resolv.conf: {e}");
    }

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
