use boot::booter::{BootParts, Booter};
use boot::syslinux;
use log::LevelFilter;
use log::{debug, error, info};
use nix::mount;
use std::io::{self, Read, Seek};
use std::path::{Path, PathBuf};
use std::str::{self, FromStr};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::Duration;
use std::{env, fs, thread};
use termion::event::Key;
use termion::input::TermRead;
use termion::raw::IntoRawMode;
use tui::backend::{Backend, TermionBackend};
use tui::layout::{Constraint, Direction, Layout};
use tui::style::{Color, Style};
use tui::text::Spans;
use tui::widgets::{Block, Borders, List, ListItem, ListState};
use tui::{Frame, Terminal};

const NONE: Option<&'static [u8]> = None;

struct StatefulList<T> {
    state: ListState,
    items: Vec<T>,
}

impl<T> StatefulList<T> {
    fn with_items(items: Vec<T>) -> StatefulList<T> {
        let non_empty = !items.is_empty();
        let mut s = StatefulList {
            state: ListState::default(),
            items,
        };
        if non_empty {
            s.state.select(Some(0));
        }
        s
    }

    fn next(&mut self) {
        let i = match self.state.selected() {
            Some(i) => {
                if i >= self.items.len() - 1 {
                    0
                } else {
                    i + 1
                }
            }
            None => 0,
        };
        self.state.select(Some(i));
    }

    fn previous(&mut self) {
        let i = match self.state.selected() {
            Some(i) => {
                if i == 0 {
                    self.items.len() - 1
                } else {
                    i - 1
                }
            }
            None => 0,
        };
        self.state.select(Some(i));
    }
}

fn find_block_devices() -> anyhow::Result<Vec<PathBuf>> {
    Ok(fs::read_dir("/sys/class/block")?
        .into_iter()
        .filter_map(|blk_dev| {
            if blk_dev.is_err() {
                return None;
            }
            let direntry = blk_dev.expect("not err");
            let mut path = direntry.path();
            path.push("uevent");
            match fs::read_to_string(path).map(|uevent| {
                let mut is_partition = false;
                let mut dev_path = PathBuf::from("/dev");
                for line in uevent.lines() {
                    if line == "DEVTYPE=partition" {
                        is_partition = true;
                    }
                    if line.starts_with("DEVNAME") {
                        dev_path.push(line.split_once('=').expect("invalid DEVNAME").1);
                    }
                }
                (is_partition, dev_path)
            }) {
                Ok((true, dev_path)) => Some(dev_path),
                _ => None,
            }
        })
        .collect::<Vec<PathBuf>>())
}

fn detect_fs_type(p: impl AsRef<Path>) -> anyhow::Result<String> {
    let mut f = fs::File::open(p)?;

    {
        f.seek(io::SeekFrom::Start(3))?;
        let mut buffer = [0; 8];
        f.read_exact(&mut buffer)?;
        if let Ok("mkfs.fat") = str::from_utf8(&buffer) {
            return Ok(String::from("fat"));
        }
    }

    {
        f.seek(io::SeekFrom::Start(1080))?;
        let mut buffer = [0; 2];
        f.read_exact(&mut buffer)?;
        let comp_buf = &nix::sys::statfs::EXT4_SUPER_MAGIC.0.to_le_bytes()[0..2];
        if buffer == comp_buf {
            return Ok(String::from("ext4"));
        }
    }

    anyhow::bail!("unsupported fs type")
}

fn ui<B: Backend>(f: &mut Frame<B>, boot_parts: &mut StatefulList<BootParts>) {
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(100), Constraint::Percentage(100)].as_ref())
        .split(f.size());

    let items: Vec<ListItem> = boot_parts
        .items
        .iter()
        .map(|i| {
            let lines = vec![Spans::from(i.name.clone())];
            ListItem::new(lines)
        })
        .collect();

    let items = List::new(items)
        .block(Block::default().borders(Borders::ALL).title("tinyboot"))
        .highlight_style(Style::default().bg(Color::White).fg(Color::Black))
        .highlight_symbol(">>");

    f.render_stateful_widget(items, chunks[0], &mut boot_parts.state);
}

fn logic() -> anyhow::Result<()> {
    let parts = find_block_devices()?
        .iter()
        .filter_map(|dev| {
            let mountpoint = PathBuf::from("/mnt").join(
                dev.to_str()
                    .expect("invalid unicode")
                    .trim_start_matches('/')
                    .replace('/', "-"),
            );

            let Ok(fstype) = detect_fs_type(dev) else { return None; };
            debug!(
                "detected {} fstype on {}",
                fstype,
                dev.to_str().expect("invalid unicode")
            );

            if let Err(e) = fs::create_dir_all(&mountpoint) {
                error!("{e}");
                return None;
            }

            if let Err(e) = nix::mount::mount(
                Some(dev.as_path()),
                &mountpoint,
                Some(fstype.as_str()),
                mount::MsFlags::MS_RDONLY,
                NONE,
            ) {
                error!("{e}");
                return None;
            };

            debug!("mounted {} at {}", dev.display(), mountpoint.display());

            match syslinux::Syslinux::new(&mountpoint).map(|s| s.get_parts()) {
                Ok(Ok(p)) => Some(p),
                e => {
                    match e {
                        Ok(Err(e)) => error!("failed to get boot parts: {}", e),
                        Err(e) => error!("failed to get syslinux config: {}", e),
                        _ => unreachable!(),
                    }
                    if let Err(e) = nix::mount::umount2(&mountpoint, mount::MntFlags::MNT_DETACH) {
                        error!("umount2: {e}");
                    }
                    None
                }
            }
        })
        .flatten()
        .collect::<Vec<BootParts>>();

    let (tx, rx) = mpsc::channel::<anyhow::Result<Option<usize>>>();

    let mut boot_parts = StatefulList::with_items(parts.to_vec());

    thread::spawn(move || {
        tx.send((|| {
            let stdout = io::stdout().lock();
            let stdout = stdout.into_raw_mode()?;
            let backend = TermionBackend::new(stdout);
            let mut terminal = Terminal::new(backend)?;

            terminal.clear()?;

            let mut keys = io::stdin().lock().keys();

            let mut first_interaction = true;
            let selected: Option<usize> = loop {
                terminal.draw(|f| ui(f, &mut boot_parts))?;

                let key = keys
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("no more keys"))??;

                if first_interaction {
                    tx.send(Ok(None)).expect("send failed");
                    first_interaction = false;
                }

                match key {
                    Key::Down | Key::Char('j') => boot_parts.next(),
                    Key::Up | Key::Char('k') => boot_parts.previous(),
                    Key::Char('\n') => break boot_parts.state.selected(),
                    Key::Char('r') => terminal.clear()?,
                    Key::Char('q') | Key::Esc => break None,
                    _ => {}
                };
            };

            Ok(selected)
        })())
        .expect("send failed")
    });

    let default = {
        let mut default = if parts.is_empty() { None } else { Some(0usize) };
        for (i, part) in parts.iter().enumerate() {
            if part.default {
                default = Some(i);
                break;
            }
        }
        default
    };

    // TODO(jared): read timeout value from boot configuration
    let timeout = Duration::from_secs(10);

    let idx = (match rx.recv_timeout(timeout) {
        Err(RecvTimeoutError::Timeout) => default,
        _ => rx.recv()??,
    })
    .ok_or_else(|| anyhow::anyhow!("no selection"))?;

    let selected = parts
        .get(idx)
        .ok_or_else(|| anyhow::anyhow!("selection does not exist"))?;

    Ok(selected.kexec()?)
}

#[derive(Debug)]
struct Config {
    log_level: LevelFilter,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            log_level: LevelFilter::Info,
        }
    }
}

impl Config {
    pub fn new<T, I>(args: T) -> Self
    where
        T: IntoIterator<Item = I>,
        I: Into<String>,
    {
        let mut cfg = Config::default();

        args.into_iter().for_each(|arg| {
            if let Some(split) = arg.into().split_once('=') {
                // TODO(jared): remove when more cmdline options are added
                #[allow(clippy::single_match)]
                match split.0 {
                    "tinyboot.log" => {
                        cfg.log_level = LevelFilter::from_str(split.1).unwrap_or(LevelFilter::Info)
                    }
                    _ => {}
                }
            }
        });

        cfg
    }
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = env::args().collect();

    let cfg = Config::new(args.as_slice());

    printk::init("tinyboot", cfg.log_level)?;

    info!("started");
    debug!("args: {:?}", args);
    debug!("config: {:?}", cfg);

    if let Err(e) = logic() {
        error!("{e}");
    }

    Ok(())
}
