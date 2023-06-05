use futures::{
    stream::{SplitSink, SplitStream},
    SinkExt, StreamExt,
};
use log::{debug, error, LevelFilter};
use nix::libc;
use std::{io::Write, process::Command};
use tboot::{
    block_device::BlockDevice,
    linux::LinuxBootEntry,
    message::{ClientCodec, Request, Response},
};
use termion::{event::Key, input::TermRead, raw::IntoRawMode};
use tokio::{net::UnixStream, sync::mpsc};
use tokio_serde_cbor::Codec;
use tokio_util::codec::{Decoder, Framed};

const START_OFFSET: u16 = 5;

fn shell() -> anyhow::Result<()> {
    let mut cmd = Command::new("/bin/sh");
    let cmd = cmd.env_clear().current_dir("/home/tinyuser").arg("-l");
    let mut child = cmd.spawn()?;
    child.wait()?;

    Ok(())
}

#[derive(Debug)]
enum Action {
    Next,
    Prev,
    ExitToShell,
    Poweroff,
    Reboot,
    SelectCurrentEntry,
}

fn print_dev<W>(
    stdout: &mut W,
    dev: BlockDevice,
    print_offset: &mut u16,
    entries: &mut Vec<(u16, LinuxBootEntry)>,
    boot_cursor: &mut Option<u16>,
) -> std::io::Result<()>
where
    W: Write,
{
    write!(
        stdout,
        "{}{}",
        termion::cursor::Goto(1, *print_offset),
        dev.name
    )?;
    *print_offset += 1;

    for entry in dev.boot_entries {
        entries.push((*print_offset, entry.clone()));

        // TODO(jared): make sure the server marks all default entries from
        // non-default devices as false, or else we will get multiple default
        // entries here
        if entry.default {
            write!(stdout, "{}->", termion::cursor::Goto(1, *print_offset))?;
            *boot_cursor = Some(*print_offset);
        }

        write!(
            stdout,
            "{}{}",
            termion::cursor::Goto(3, *print_offset),
            entry.display
        )?;
        *print_offset += 1;
    }

    stdout.flush()?;

    *print_offset += 1; // leave a line between devices

    Ok(())
}

async fn run_client(
    sink: &mut SplitSink<Framed<UnixStream, ClientCodec>, Request>,
    stream: &mut SplitStream<Framed<UnixStream, ClientCodec>>,
) -> anyhow::Result<()> {
    let (_columns, rows) = termion::terminal_size()?;

    sink.send(Request::Ping).await?;
    debug!("sent ping to server");

    if matches!(stream.next().await, Some(Ok(Response::Pong))) {
        debug!("got pong from server");
    } else {
        anyhow::bail!("could not communicate with server")
    }

    let mut recorded_user_interaction = false;

    'outer: loop {
        let mut boot_cursor = None::<u16>;
        let mut entries: Vec<(u16, LinuxBootEntry)> = Vec::new();
        let mut print_offset = START_OFFSET;

        let mut stdout = std::io::stdout().into_raw_mode()?;

        let (tx, mut rx) = mpsc::channel::<Action>(200);

        let keys_handle = tokio::spawn(async move {
            let stdin = std::io::stdin();
            for key in stdin.keys() {
                let Ok(key) = key else {
                break;
            };

                if match key {
                    Key::Char('j') | Key::Down => tx.send(Action::Next).await,
                    Key::Char('k') | Key::Up => tx.send(Action::Prev).await,
                    Key::Char('s') => tx.send(Action::ExitToShell).await,
                    Key::Char('r') => tx.send(Action::Reboot).await,
                    Key::Char('p') => tx.send(Action::Poweroff).await,
                    Key::Char('\n') => tx.send(Action::SelectCurrentEntry).await,
                    _ => Ok(()),
                }
                .is_err()
                {
                    break;
                }
            }
        });

        'inner: loop {
            write!(
                stdout,
                "{}{}{}tinyboot{}{}",
                termion::clear::All,
                termion::cursor::Goto(1, 1),
                termion::style::Bold,
                termion::style::Reset,
                termion::cursor::Hide,
            )?;

            write!(
                stdout,
                "{}<s> Shell | <r> Reboot | <p> Poweroff",
                termion::cursor::Goto(1, 3)
            )?;
            stdout.flush()?;

            sink.send(Request::ListBlockDevices).await?;
            if let Some(Ok(Response::ListBlockDevices(devs))) = stream.next().await {
                for dev in devs {
                    print_dev(
                        &mut stdout,
                        dev,
                        &mut print_offset,
                        &mut entries,
                        &mut boot_cursor,
                    )?;
                }
            }
            sink.send(Request::StartStreaming).await?;

            loop {
                tokio::select! {
                    Some(action) = rx.recv() => {
                        if !recorded_user_interaction {
                            sink.send(Request::UserIsPresent).await?;
                            recorded_user_interaction = true;
                            write!(stdout, "{}{}", termion::cursor::Goto(1, rows - 1), termion::clear::AfterCursor)?;
                            stdout.flush()?;
                        }

                        match action {
                            Action::Next => {
                                if let Some(current_boot_cursor) = boot_cursor {
                                    if let Some((next_boot_cursor, _)) = entries
                                        .iter()
                                        .find(|(print_offset, _)| print_offset > &current_boot_cursor ) {
                                            boot_cursor = Some(*next_boot_cursor);
                                            write!(stdout, "{}  ", termion::cursor::Goto(1, current_boot_cursor))?;
                                            write!(stdout, "{}->", termion::cursor::Goto(1, *next_boot_cursor))?;
                                            stdout.flush()?;
                                        }
                                }
                            }
                            Action::Prev => {
                                if let Some(current_boot_cursor) = boot_cursor {
                                    if let Some((next_boot_cursor, _)) = entries
                                        .iter()
                                        .rev()
                                        .find(|(print_offset, _)| print_offset < &current_boot_cursor) {
                                            boot_cursor = Some(*next_boot_cursor);
                                            write!(stdout, "{}  ", termion::cursor::Goto(1, current_boot_cursor))?;
                                            write!(stdout, "{}->", termion::cursor::Goto(1, *next_boot_cursor))?;
                                            stdout.flush()?;
                                        }
                                }
                            }
                            Action::SelectCurrentEntry => {
                                if let Some(boot_cursor) = boot_cursor {
                                    if let Some((_, entry)) = entries.iter().find(|(i, _)| *i == boot_cursor) {
                                        _ = sink.send(Request::Boot(entry.clone())).await;
                                    }
                                }
                            },
                            Action::Reboot => sink.send(Request::Reboot).await?,
                            Action::Poweroff => sink.send(Request::Poweroff).await?,
                            Action::ExitToShell => break 'inner,
                        }
                    }
                    Some(Ok(msg)) = stream.next() => {
                        match msg {
                            Response::NewDevice(dev) => print_dev(&mut stdout, dev, &mut print_offset, &mut entries, &mut boot_cursor)?,
                            Response::TimeLeft(time) => {
                                write!(stdout, "{}{}Boot in {}s", termion::cursor::Goto(1, rows-1), termion::clear::CurrentLine, time.as_secs())?;
                                stdout.flush()?;
                            }
                            Response::ServerDone => {
                                break 'outer;
                            },
                            _ => {},
                        }
                    }
                    else => break 'inner,
                }
            }
        }

        sink.send(Request::StopStreaming).await?;
        keys_handle.abort();
        write!(
            stdout,
            "{}{}{}",
            termion::clear::All,
            termion::cursor::Goto(1, 1),
            termion::cursor::Show,
        )?;
        stdout.flush()?;
        stdout.suspend_raw_mode()?;
        shell()?;
        stdout.activate_raw_mode()?;
    }

    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // drop permissions immediately
    unsafe { libc::setregid(tboot::TINYUSER_GID, tboot::TINYUSER_GID) };
    unsafe { libc::setreuid(tboot::TINYUSER_UID, tboot::TINYUSER_UID) };

    tboot::log::setup_logging(LevelFilter::Debug, Some(tboot::log::TBOOTUI_LOG_FILE))?;

    let stream = UnixStream::connect(tboot::TINYBOOT_SOCKET).await?;
    let codec: ClientCodec = Codec::new();
    let (mut sink, mut stream) = codec.framed(stream).split();

    while let Err(e) = run_client(&mut sink, &mut stream).await {
        error!("run_client: {e}");
    }

    Ok(())
}
