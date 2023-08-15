use clap::Parser;
use futures::{
    stream::{SplitSink, SplitStream},
    SinkExt, StreamExt,
};
use log::{debug, error, LevelFilter};
use nix::libc;
use ratatui::{
    backend::TermionBackend,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Style},
    widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph},
    Terminal,
};
use std::{
    io::{self, Write},
    os::fd::AsRawFd,
    process::Command,
    time::Duration,
};
use tboot::{
    block_device::BlockDevice,
    linux::LinuxBootEntry,
    message::{ClientCodec, ClientMessage, ServerError, ServerMessage},
};
use termion::{event::Key, input::TermRead, raw::IntoRawMode, screen::IntoAlternateScreen};
use termios::{
    cfgetispeed, cfgetospeed, cfsetispeed, cfsetospeed,
    os::linux::{B115200, B576000},
    speed_t, tcsetattr, Termios, B38400, B9600, TCSANOW,
};
use tokio::{net::UnixStream, sync::mpsc};
use tokio_serde_cbor::Codec;
use tokio_util::codec::{Decoder, Framed};

pub fn edit<W: Write>(
    entry: LinuxBootEntry,
    terminal: &mut Terminal<TermionBackend<W>>,
) -> Option<LinuxBootEntry> {
    let stdin = std::io::stdin();

    let mut input = entry.cmdline.clone().unwrap_or_default();
    let mut pos = input.len();
    let mut scroll = (0, 0); // (y, x)
    let mut keys = stdin.keys();
    let scroll_off = 8;

    loop {
        terminal
            .draw(|f| {
                let rect = f.size();
                let pos = pos as u16;
                let pos = if pos > scroll.1 + rect.width - 1 {
                    // text overflows rect width

                    // add one so that the cursor is always one position to the right of the last
                    // character of input
                    scroll.1 = pos - rect.width + 1;

                    rect.width - 1
                } else if pos > scroll.1 && 0 < scroll.1 && (pos - scroll.1) < scroll_off {
                    // text is closer to beginning than scroll off width
                    scroll.1 = pos - scroll_off;

                    scroll_off
                } else if scroll.1 >= pos {
                    // text underflows rect width
                    scroll.1 = pos;

                    0
                } else {
                    // text is somewhere greater than the scroll off width and less than the end
                    pos - scroll.1
                };

                let widget = Paragraph::new(input.as_str())
                    .block(Block::default().title("edit kernel params:"))
                    .scroll(scroll);
                f.render_widget(widget, f.size());
                f.set_cursor(pos, 1); // (x, y)
            })
            .ok()?;

        let Some(Ok(key)) = keys.next() else {
            break;
        };

        match key {
            Key::Esc | Key::Ctrl('[') | Key::Ctrl('c') => return None,
            Key::Backspace | Key::Ctrl('h') if pos > 0 => {
                pos -= 1;
                input = format!("{}{}", &input[..pos], &input[pos + 1..]);
            }
            Key::Ctrl('d') if pos < input.len() => {
                input = format!("{}{}", &input[..pos], &input[pos + 1..])
            }
            Key::Ctrl('u') if pos > 0 => {
                input = input[pos..].to_string();
                pos = 0;
            }
            Key::Ctrl('k') => input = input[..pos].to_string(),
            Key::Ctrl('b') | Key::Left if pos > 0 => pos -= 1,
            Key::Ctrl('f') | Key::Right if pos < input.len() => pos += 1,
            Key::Ctrl('a') | Key::Home => pos = 0,
            Key::Ctrl('e') | Key::End => pos = input.len(),
            Key::Alt('b') if pos > 0 => {
                if let Some((next_pos, _)) = input[..pos - 1]
                    .char_indices()
                    .rev()
                    .find(|(_, c)| !char::is_ascii_alphanumeric(c))
                {
                    pos -= input[..pos].len() - next_pos - 1;
                } else {
                    pos = 0;
                }
            }
            Key::Alt('f') if pos < input.len() => {
                if let Some(next_pos) = input[pos + 1..].find(|c| !char::is_ascii_alphanumeric(&c))
                {
                    pos += next_pos + 1;
                } else {
                    pos = input.len();
                }
            }
            Key::Char(c) if c != '\n' => {
                input = format!("{}{}{}", &input[..pos], c, &input[pos..]);
                pos += 1;
            }
            Key::Char('\n') | Key::Ctrl('x') => {
                let mut entry = entry;
                entry.cmdline = Some(input);
                return Some(entry);
            }
            _ => {}
        }
    }

    None
}

const HELP: &str = r#"<s> Shell
<p> Poweroff
<r> Reboot
<e> Edit entry
<Enter> Select entry"#;

const POPUP_FOOTER: &str = r#"press any key to exit"#;

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
    let cmd = cmd.current_dir("/home/tboot").arg("-l");
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
    sink: &mut SplitSink<Framed<UnixStream, ClientCodec>, ClientMessage>,
    stream: &mut SplitStream<Framed<UnixStream, ClientCodec>>,
) -> anyhow::Result<()> {
    sink.send(ClientMessage::Ping).await?;
    debug!("sent ping to server");

    if matches!(stream.next().await, Some(Ok(ServerMessage::Pong))) {
        debug!("got pong from server");
    } else {
        anyhow::bail!("could not communicate with server")
    }

    let mut recorded_user_interaction = false;
    let mut devs = DeviceList::default();

    sink.send(ClientMessage::ListBlockDevices).await?;
    if let Some(Ok(ServerMessage::ListBlockDevices(new_devs))) = stream.next().await {
        for d in new_devs {
            devs.add(d);
        }
    }

    'outer: loop {
        let mut terminal = Terminal::new(TermionBackend::new(
            std::io::stdout().into_raw_mode()?.into_alternate_screen()?,
        ))?;

        terminal.clear()?;

        let mut popup = None::<&str>;
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

        sink.send(ClientMessage::StartStreaming).await?;

        let break_type = 'inner: loop {
            terminal.draw(|frame| {
                let num_of_lists = devs.devices.len();
                let constraints = [Constraint::Percentage(95), Constraint::Percentage(5)].as_ref();

                let chunks = Layout::default()
                    .constraints(constraints)
                    .split(frame.size());

                if num_of_lists > 0 {
                    let chunks = Layout::default()
                        .constraints(
                            devs.devices
                                .iter()
                                .map(|d| Constraint::Length(d.device.boot_entries.len() as u16 + 2))
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
                    frame.render_widget(Paragraph::new("no boot devices"), chunks[0]);
                }

                if let Some(time_left) = time_left {
                    let timeout = Paragraph::new(format!("Boot in {}s", time_left.as_secs()));
                    frame.render_widget(Clear, chunks[1]);
                    frame.render_widget(timeout, chunks[1]);
                }

                if let Some(popup_msg) = popup {
                    let paragraph = Paragraph::new(format!("{}\n\n{}", popup_msg, POPUP_FOOTER))
                        .block(Block::default().borders(Borders::ALL));
                    let area = centered_rect(50, 50, frame.size());
                    frame.render_widget(Clear, area);
                    frame.render_widget(paragraph, area);
                }
            })?;

            tokio::select! {
                Some(key) = rx.recv() => {
                    if !recorded_user_interaction {
                        sink.send(ClientMessage::UserIsPresent).await?;
                        recorded_user_interaction = true;
                    }

                    // allow for acknowledging popup with any key
                    if popup.is_some() {
                        popup = None;
                        continue;
                    }

                    match key {
                        Key::Char('?') | Key::Char('h') => popup = Some(HELP),
                        Key::Char('j') | Key::Ctrl('n') | Key::Down => devs.next(),
                        Key::Char('k') | Key::Ctrl('p') | Key::Up => devs.prev(),
                        Key::Char('\n') => {
                            if let Some(dev) = devs.selected.and_then(|selected| devs.devices.get(selected)) {
                                if let Some(entry) = dev.state.selected().and_then(|selected| dev.device.boot_entries.get(selected)) {
                                     _ = sink.send(ClientMessage::Boot(entry.clone())).await;
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
                        Key::Char('r') => sink.send(ClientMessage::Reboot).await?,
                        Key::Char('p') => sink.send(ClientMessage::Poweroff).await?,
                        _ => {}
                    }
                }
                Some(Ok(msg)) = stream.next() => {
                    match msg {
                        ServerMessage::NewDevice(dev) => devs.add(dev),
                        ServerMessage::TimeLeft(time) => time_left = time,
                        ServerMessage::ServerError(error) => {
                            popup = Some(match error {
                                ServerError::ValidationFailed => "Validation of boot files failed",
                                ServerError::Unknown => "Unknown error occurred",
                            });

                        }
                        ServerMessage::ServerDone => {
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

        sink.send(ClientMessage::StopStreaming).await?;
        keys_handle.await?;

        match break_type {
            BreakType::Edit(entry) => {
                terminal.show_cursor()?;
                let edited = edit(entry, &mut terminal);
                terminal.hide_cursor()?;
                if let Some(entry) = edited {
                    _ = sink.send(ClientMessage::Boot(entry)).await;
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

/// NOTE: from ratatui examples/popup.rs
/// helper function to create a centered rect using up certain percentage of the available rect `r`
fn centered_rect(percent_x: u16, percent_y: u16, r: Rect) -> Rect {
    let popup_layout = Layout::default()
        .direction(Direction::Vertical)
        .constraints(
            [
                Constraint::Percentage((100 - percent_y) / 2),
                Constraint::Percentage(percent_y),
                Constraint::Percentage((100 - percent_y) / 2),
            ]
            .as_ref(),
        )
        .split(r);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints(
            [
                Constraint::Percentage((100 - percent_x) / 2),
                Constraint::Percentage(percent_x),
                Constraint::Percentage((100 - percent_x) / 2),
            ]
            .as_ref(),
        )
        .split(popup_layout[1])[1]
}

/// Ensure that the baud rate on TTYs is at least 115200. This occurs on serial ports where the
/// default baud rate on linux is 9600.
fn fix_serial_baud_rate(baud_rate: speed_t) -> anyhow::Result<()> {
    let tty = termion::get_tty()?;
    let fd = tty.as_raw_fd();
    let mut termios = Termios::from_fd(fd)?;

    if cfgetispeed(&termios) != baud_rate {
        cfsetispeed(&mut termios, baud_rate)?;
    }
    if cfgetospeed(&termios) != baud_rate {
        cfsetospeed(&mut termios, baud_rate)?;
    }

    tcsetattr(fd, TCSANOW, &termios)?;

    Ok(())
}

fn baud_to_speed_t(baud: u32) -> speed_t {
    match baud {
        9600 => B9600,
        38400 => B38400,
        115200 => B115200,
        576000 => B576000,
        _ => {
            error!("unknown baud rate, using 115200");
            B115200
        }
    }
}

#[derive(Parser)]
struct Config {
    #[arg(short, long, default_value_t = 115200)]
    baud_rate: u32,

    #[arg(short, long, value_parser, default_value_t = LevelFilter::Info)]
    log_level: LevelFilter,
}

pub async fn run(args: Vec<String>) -> anyhow::Result<()> {
    let cfg = Config::try_parse_from(args)?;

    // drop permissions
    unsafe { libc::setregid(tboot::TINYUSER_GID, tboot::TINYUSER_GID) };
    unsafe { libc::setreuid(tboot::TINYUSER_UID, tboot::TINYUSER_UID) };

    fix_serial_baud_rate(baud_to_speed_t(cfg.baud_rate))?;

    tboot::log::setup_logging(cfg.log_level, Some(tboot::log::TBOOTUI_LOG_FILE))?;

    // set correct env vars
    std::env::set_var("USER", "tboot");
    std::env::set_var("HOME", "/home/tboot");

    fix_zero_size_terminal()?;

    let stream = UnixStream::connect(tboot::TINYBOOT_SOCKET).await?;
    let codec: ClientCodec = Codec::new();
    let (mut sink, mut stream) = codec.framed(stream).split();

    while let Err(e) = run_client(&mut sink, &mut stream).await {
        error!("run_client: {e}");
    }

    Ok(())
}
