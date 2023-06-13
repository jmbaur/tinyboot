use futures::{
    stream::{SplitSink, SplitStream},
    SinkExt, StreamExt,
};
use log::{debug, error, LevelFilter};
use nix::libc;
use ratatui::{
    backend::TermionBackend,
    layout::{Constraint, Layout},
    style::{Color, Style},
    widgets::{Block, List, ListItem, ListState, Paragraph},
    Terminal,
};
use std::{io, process::Command, time::Duration};
use tboot::{
    block_device::BlockDevice,
    linux::LinuxBootEntry,
    message::{ClientCodec, Request, Response},
};
use tbootui::edit;
use termion::{event::Key, input::TermRead, raw::IntoRawMode, screen::IntoAlternateScreen};
use tokio::{net::UnixStream, sync::mpsc};
use tokio_serde_cbor::Codec;
use tokio_util::codec::{Decoder, Framed};

struct Device {
    pub state: ListState,
    pub device: BlockDevice,
}

#[derive(Default)]
struct DeviceList {
    pub devices: Vec<Device>,
    pub selected: Option<usize>,
}

impl DeviceList {
    pub fn add(&mut self, device: BlockDevice) {
        let mut state = ListState::default();

        if self.selected.is_none() {
            self.selected = Some(0usize);

            if let Some((i, _)) = device
                .boot_entries
                .iter()
                .enumerate()
                .find(|(_, d)| d.default)
            {
                state.select(Some(i));
            }
        }

        self.devices.push(Device { state, device });
    }

    pub fn next(&mut self) {
        if let Some(dev) = self
            .selected
            .and_then(|selected| self.devices.get_mut(selected))
        {
            if let Some(selected) = dev.state.selected() {
                if selected < dev.device.boot_entries.len() - 1 {
                    // select the next entry within the same device
                    dev.state.select(Some(selected + 1));
                } else {
                    // unselect previously selected entry in last device
                    dev.state.select(None);

                    // select the first entry within the next device
                    // unwrap safe here because we wouldn't be in this block unless it was not None
                    let selected = self.selected.unwrap();
                    let dev = if selected < self.devices.len() - 1 {
                        self.selected = Some(selected + 1);
                        self.devices.get_mut(selected + 1).unwrap()
                    } else {
                        // wrap around to first device
                        self.selected = Some(0usize);
                        self.devices.get_mut(0usize).unwrap()
                    };
                    dev.state.select(Some(0usize));
                }
            }
        }
    }

    pub fn prev(&mut self) {
        if let Some(dev) = self
            .selected
            .and_then(|selected| self.devices.get_mut(selected))
        {
            if let Some(selected) = dev.state.selected() {
                if selected > 0 {
                    // select the next entry within the same device
                    dev.state.select(Some(selected - 1));
                } else {
                    // unselect previously selected entry in last device
                    dev.state.select(None);

                    // select the first entry within the next device
                    // unwrap safe here because we wouldn't be in this block unless it was not None
                    let selected = self.selected.unwrap();
                    let dev = if selected > 0 {
                        self.selected = Some(selected - 1);
                        self.devices.get_mut(self.selected.unwrap()).unwrap()
                        // select the last entry in the previous device
                    } else {
                        // wrap around to last device
                        self.selected = Some(self.devices.len() - 1);
                        self.devices.get_mut(self.selected.unwrap()).unwrap()
                    };
                    // select the last entry in the previous device
                    dev.state.select(Some(dev.device.boot_entries.len() - 1));
                }
            }
        }
    }
}

fn shell() -> anyhow::Result<()> {
    let mut cmd = Command::new("/bin/sh");
    let cmd = cmd.current_dir("/home/tinyuser").arg("-l");
    let mut child = cmd.spawn()?;
    child.wait()?;

    Ok(())
}

enum BreakType {
    ExitToShell,
    Edit(LinuxBootEntry),
    Unknown,
}

async fn run_client(
    sink: &mut SplitSink<Framed<UnixStream, ClientCodec>, Request>,
    stream: &mut SplitStream<Framed<UnixStream, ClientCodec>>,
) -> anyhow::Result<()> {
    sink.send(Request::Ping).await?;
    debug!("sent ping to server");

    if matches!(stream.next().await, Some(Ok(Response::Pong))) {
        debug!("got pong from server");
    } else {
        anyhow::bail!("could not communicate with server")
    }

    let mut recorded_user_interaction = false;
    let mut devs = DeviceList::default();

    sink.send(Request::ListBlockDevices).await?;
    if let Some(Ok(Response::ListBlockDevices(new_devs))) = stream.next().await {
        for d in new_devs {
            devs.add(d);
        }
    }

    'outer: loop {
        let mut terminal = Terminal::new(TermionBackend::new(
            std::io::stdout().into_raw_mode()?.into_alternate_screen()?,
        ))?;

        terminal.clear()?;

        let mut time_left = None::<Duration>;

        let (tx, mut rx) = mpsc::channel::<Key>(200);

        let keys_handle = tokio::spawn(async move {
            let stdin = std::io::stdin();
            for key in stdin.keys() {
                let Ok(key) = key else {
                    break;
                };

                if tx.send(key).await.is_err() {
                    break;
                }

                // 's' -> shell, 'e' -> edit
                if matches!(key, Key::Char('s') | Key::Char('e')) {
                    break;
                }
            }
        });

        sink.send(Request::StartStreaming).await?;

        let break_type = 'inner: loop {
            terminal.draw(|frame| {
                let num_of_lists = devs.devices.len();
                let constraints = [Constraint::Percentage(95), Constraint::Percentage(5)].as_ref();

                let chunks = Layout::default()
                    .constraints(constraints)
                    .split(frame.size());

                if num_of_lists > 0 {
                    let num_of_options = devs
                        .devices
                        .iter()
                        .fold(0usize, |n, d| n + d.device.boot_entries.len());

                    let chunks = Layout::default()
                        .constraints(
                            devs.devices
                                .iter()
                                .map(|d| {
                                    Constraint::Ratio(
                                        d.device.boot_entries.len() as u32,
                                        num_of_options as u32,
                                    )
                                })
                                .collect::<Vec<Constraint>>(),
                        )
                        .split(chunks[0]);

                    for (i, dev) in devs.devices.iter_mut().enumerate() {
                        let list: Vec<ListItem> = dev
                            .device
                            .boot_entries
                            .iter()
                            .map(|e| ListItem::new(e.display.clone()))
                            .collect();
                        let list = List::new(list)
                            .block(Block::default().title(dev.device.name.clone()))
                            .highlight_style(Style::new().fg(Color::Black).bg(Color::White));

                        frame.render_stateful_widget(list, chunks[i], &mut dev.state);
                    }
                } else {
                    frame.render_widget(Paragraph::new("no boot devices"), chunks[1]);
                }

                if let Some(time_left) = time_left {
                    let timeout = Paragraph::new(format!("Boot in {}s", time_left.as_secs()));
                    frame.render_widget(timeout, chunks[1]);
                }
            })?;

            tokio::select! {
                Some(key) = rx.recv() => {
                    if !recorded_user_interaction {
                        sink.send(Request::UserIsPresent).await?;
                        recorded_user_interaction = true;
                        time_left = None;
                    }

                    match key {
                        Key::Char('j') | Key::Ctrl('n') | Key::Down => devs.next(),
                        Key::Char('k') | Key::Ctrl('p') | Key::Up => devs.prev(),
                        Key::Char('\n') => {
                            if let Some(dev) = devs.selected.and_then(|selected| devs.devices.get(selected)) {
                                if let Some(entry) = dev.state.selected().and_then(|selected| dev.device.boot_entries.get(selected)) {
                                     _ = sink.send(Request::Boot(entry.clone())).await;
                                }
                            }
                        },
                        Key::Char('s') => break 'inner BreakType::ExitToShell,
                        Key::Char('e') => {
                            if let Some(dev) = devs.selected.and_then(|selected| devs.devices.get(selected)) {
                                if let Some(entry) = dev.state.selected().and_then(|selected| dev.device.boot_entries.get(selected)) {
                                    break 'inner BreakType::Edit(entry.clone());
                                }
                            }
                        },
                        Key::Char('r') => sink.send(Request::Reboot).await?,
                        Key::Char('p') => sink.send(Request::Poweroff).await?,
                        _ => {}
                    }
                }
                Some(Ok(msg)) = stream.next() => {
                    match msg {
                        Response::NewDevice(dev) => devs.add(dev),
                        Response::TimeLeft(time) => time_left = Some(time),
                        Response::ServerDone => {
                            terminal.clear()?;
                            terminal.set_cursor(0, 0)?;
                            break 'outer
                        },
                        _ => {},
                    }
                }
                else => break 'inner BreakType::Unknown,
            }
        };

        sink.send(Request::StopStreaming).await?;
        keys_handle.await?;

        match break_type {
            BreakType::Edit(entry) => {
                terminal.show_cursor()?;
                let edited = edit(entry, &mut terminal);
                terminal.hide_cursor()?;
                if let Some(entry) = edited {
                    _ = sink.send(Request::Boot(entry)).await;
                }
            }
            BreakType::ExitToShell => {
                terminal.clear()?;
                terminal.set_cursor(0, 0)?;
                drop(terminal);
                shell()?
            }
            _ => {}
        }
    }

    Ok(())
}

fn fix_zero_size_terminal() -> io::Result<()> {
    let mut size = std::mem::MaybeUninit::<libc::winsize>::uninit();

    let res = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ as _, &mut size) };
    if res < 0 {
        return Err(io::Error::last_os_error());
    }

    let mut size = unsafe { size.assume_init() };

    if size.ws_row == 0 {
        size.ws_row = 24;
    }
    if size.ws_col == 0 {
        size.ws_col = 80;
    }

    let res = unsafe {
        libc::ioctl(
            libc::STDOUT_FILENO,
            libc::TIOCSWINSZ as _,
            &size as *const _,
        )
    };
    if res < 0 {
        return Err(io::Error::last_os_error());
    }

    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // drop permissions immediately
    unsafe { libc::setregid(tboot::TINYUSER_GID, tboot::TINYUSER_GID) };
    unsafe { libc::setreuid(tboot::TINYUSER_UID, tboot::TINYUSER_UID) };

    // set correct env vars
    std::env::set_var("USER", "tinyuser");
    std::env::set_var("PATH", "/bin");
    std::env::set_var("HOME", "/home/tinyuser");

    tboot::log::setup_logging(LevelFilter::Debug, Some(tboot::log::TBOOTUI_LOG_FILE))?;

    fix_zero_size_terminal()?;

    let stream = UnixStream::connect(tboot::TINYBOOT_SOCKET).await?;
    let codec: ClientCodec = Codec::new();
    let (mut sink, mut stream) = codec.framed(stream).split();

    while let Err(e) = run_client(&mut sink, &mut stream).await {
        error!("run_client: {e}");
    }

    Ok(())
}
