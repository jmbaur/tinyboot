pub(crate) mod block_device;
pub(crate) mod boot_loader;
pub(crate) mod message;
const TICK_DURATION: Duration = Duration::from_secs(1);

use crate::{
    block_device::{handle_unmounting, mount_all_devs, MountMsg},
    boot_loader::{kexec_execute, kexec_load},
};
use clap::Parser;
use futures::prelude::*;
use log::{debug, error, info, LevelFilter};
use message::InternalMsg;
use nix::{
    libc,
    unistd::{chown, Gid, Uid},
};
use std::{
    collections::VecDeque,
    io::ErrorKind,
    path::Path,
    process,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use tboot::{
    block_device::BlockDevice,
    linux::LinuxBootEntry,
    message::{ClientMessage, ServerCodec, ServerError, ServerMessage},
};
use tokio::{
    net::{UnixListener, UnixStream},
    sync::broadcast,
    sync::mpsc,
};
use tokio_serde_cbor::Codec;
use tokio_util::codec::Decoder;

async fn handle_client(
    stream: UnixStream,
    mut client_rx: broadcast::Receiver<ServerMessage>,
    client_tx: broadcast::Sender<ClientMessage>,
) {
    let codec: ServerCodec = Codec::new();
    let (mut sink, mut stream) = codec.framed(stream).split();

    let mut streaming = false;

    let mut unsent_events: VecDeque<ServerMessage> = VecDeque::new();

    loop {
        tokio::select! {
            Some(Ok(req)) = stream.next() => {
                if req == ClientMessage::Ping {
                    _ = sink.send(ServerMessage::Pong).await;
                } else if req == ClientMessage::StartStreaming {
                    streaming = true;
                    while let Some(msg) = unsent_events.pop_front() {
                         _ = sink.send(msg).await;
                    }
                } else if req == ClientMessage::StopStreaming {
                    streaming = false;
                } else {
                    _ = client_tx.send(req);
                }
            }
            Ok(msg) = client_rx.recv() => {
                if !streaming && matches!(msg, ServerMessage::NewDevice(_) | ServerMessage::TimeLeft(_)) {
                    // don't send these responses if the client is not streaming
                    unsent_events.push_back(msg);
                } else {
                    _ = sink.send(msg).await;
                }
            }
            else => break,
        }
    }
}

#[derive(thiserror::Error, Debug)]
enum SelectEntryError {
    #[error("reboot")]
    Reboot,
    #[error("poweroff")]
    Poweroff,
    #[error("io error: {0}")]
    Io(tokio::io::Error),
}

impl From<tokio::io::Error> for SelectEntryError {
    fn from(value: tokio::io::Error) -> Self {
        Self::Io(value)
    }
}

async fn select_entry(
    state: &mut ServerState,
    listener: &UnixListener,
    internal_rx: &mut mpsc::Receiver<InternalMsg>,
    response_tx: broadcast::Sender<ServerMessage>,
    client_msg_rx: &mut broadcast::Receiver<ClientMessage>,
    client_msg_tx: broadcast::Sender<ClientMessage>,
) -> Result<LinuxBootEntry, SelectEntryError> {
    loop {
        tokio::select! {
            Ok(msg) = client_msg_rx.recv() => {
                match msg {
                    ClientMessage::StartStreaming | ClientMessage::StopStreaming | ClientMessage::Ping => {/* this is handled by the client task */}
                    ClientMessage::ListBlockDevices => {
                        _ = response_tx.send(ServerMessage::ListBlockDevices(state.block_devices.clone()));
                    },
                    ClientMessage::Boot(entry) => return Ok(entry),
                    ClientMessage::UserIsPresent => {
                        state.has_user_interaction = true;
                        _ = response_tx.send(ServerMessage::TimeLeft(None));
                    }
                    ClientMessage::Reboot => {
                        return Err(SelectEntryError::Reboot);
                    },
                    ClientMessage::Poweroff => {
                        return Err(SelectEntryError::Poweroff);
                    },
                }
            }
            Ok((stream, _)) = listener.accept() => {
                tokio::spawn(handle_client(stream, response_tx.subscribe(), client_msg_tx.clone()));
            },
            Some(internal_msg) = internal_rx.recv() => {
                match internal_msg {
                    InternalMsg::Device(device) => {
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

                            _ = response_tx.send(ServerMessage::NewDevice(device.clone()));
                            state.block_devices.push(device);
                    }
                    InternalMsg::Tick => {
                        let elapsed = state.start.elapsed();

                        // don't send TimeLeft response if timeout <= elapsed, this will panic
                        if !state.has_user_interaction && state.timeout > elapsed {
                            _ = response_tx.send(ServerMessage::TimeLeft(Some(state.timeout - elapsed)));
                        }

                        // Timeout has occurred without any user interaction
                        if !state.has_user_interaction && elapsed >= state.timeout {
                            if let Some(default_entry) = &state.default_entry {
                                return Ok(default_entry.clone());
                            }
                        }
                    }
                }
            }
        }
    }
}

#[derive(thiserror::Error, Debug)]
enum PrepareBootError {
    #[error("failed to select entry: {0}")]
    SelectEntry(SelectEntryError),
    #[error("io error: {0}")]
    Io(std::io::Error),
    #[error("nix error: {0}")]
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

async fn prepare_boot(
    internal_tx: mpsc::Sender<InternalMsg>,
    mut internal_rx: mpsc::Receiver<InternalMsg>,
) -> Result<(), PrepareBootError> {
    let (server_msg_tx, _) = broadcast::channel::<ServerMessage>(200);
    let (client_msg_tx, mut client_msg_rx) = broadcast::channel::<ClientMessage>(200);

    let listener = UnixListener::bind(tboot::TINYBOOT_SOCKET)?;
    chown(
        tboot::TINYBOOT_SOCKET,
        Some(Uid::from_raw(tboot::TINYUSER_UID)),
        Some(Gid::from_raw(tboot::TINYUSER_GID)),
    )?;

    // TODO(jared): don't start ticking until we have at least one thing to boot from
    tokio::spawn(async move {
        let tick_tx = internal_tx.clone();
        loop {
            tokio::time::sleep(TICK_DURATION).await;
            if tick_tx.send(InternalMsg::Tick).await.is_err() {
                break;
            }
        }
    });

    let mut state = ServerState::default();

    loop {
        let res = select_entry(
            &mut state,
            &listener,
            &mut internal_rx,
            server_msg_tx.clone(),
            &mut client_msg_rx,
            client_msg_tx.clone(),
        )
        .await;

        let entry = match res {
            Err(e) => {
                if matches!(e, SelectEntryError::Reboot | SelectEntryError::Poweroff) {
                    _ = server_msg_tx.send(ServerMessage::ServerDone);
                }
                return Err(e.into());
            }
            Ok(entry) => entry,
        };

        let linux = entry.linux.as_path();
        let initrd = entry.initrd.as_deref();
        let cmdline = entry.cmdline.unwrap_or_default();
        let cmdline = cmdline.as_str();

        match kexec_load(linux, initrd, cmdline).await {
            Ok(()) => break,
            Err(e) => {
                _ = server_msg_tx.send(ServerMessage::ServerError(match e.kind() {
                    ErrorKind::PermissionDenied => {
                        error!("permission denied performing kexec load");
                        ServerError::ValidationFailed
                    }
                    k => {
                        error!("kexec load resulted in unknown error kind: {k}");
                        ServerError::Unknown
                    }
                }));
                continue;
            }
        };
    }

    _ = server_msg_tx.send(ServerMessage::ServerDone);

    Ok(())
}

#[derive(Debug, Parser)]
struct Config {
    #[arg(short, long, value_parser, default_value_t = LevelFilter::Info)]
    log_level: LevelFilter,
}

const VERSION: Option<&'static str> = option_env!("version");

pub async fn run(args: Vec<String>) -> anyhow::Result<()> {
    let cfg = Config::try_parse_from(args)?;

    tboot::log::setup_logging(cfg.log_level, Some(Path::new(tboot::log::TBOOTD_LOG_FILE)))?;

    info!("running version {}", VERSION.unwrap_or("devel"));
    debug!("config: {:?}", cfg);

    if (unsafe { libc::getuid() }) != 0 {
        error!("tinyboot not running as root");
        process::exit(1);
    }

    loop {
        let (internal_tx, internal_rx) = mpsc::channel::<InternalMsg>(100);
        let (mount_tx, mount_rx) = mpsc::channel::<MountMsg>(100);

        let done = Arc::new(AtomicBool::new(false));
        let mount_handle = mount_all_devs(internal_tx.clone(), mount_tx.clone(), done.clone());

        let unmount_handle = handle_unmounting(mount_rx);

        let res = prepare_boot(internal_tx, internal_rx).await;

        done.store(true, Ordering::Relaxed);

        if mount_tx.send(MountMsg::UnmountAll).await.is_ok() {
            // wait for unmounting to finish
            info!("waiting for disks to be unmounted");
            _ = mount_handle.await;
            _ = unmount_handle.await;
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
            Err(e) => error!("failed to prepare boot: {e}"),
        }
    }
}
