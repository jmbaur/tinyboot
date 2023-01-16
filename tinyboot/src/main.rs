mod boot;

use boot::boot_loader::{kexec_execute, kexec_load, BootLoader, MenuEntry};
use boot::syslinux::SyslinuxBootLoader;
use log::LevelFilter;
use log::{debug, error, info};
use nix::mount;
use std::fmt::Write;
use std::io::{self, Read, Seek};
use std::path::{Path, PathBuf};
use std::str::{self, FromStr};
use std::sync::mpsc;
use std::time::{Duration, Instant};
use std::{env, fs, thread};
use termion::event::Key;
use termion::input::TermRead;
use termion::raw::IntoRawMode;
use tui::backend::{Backend, TermionBackend};
use tui::layout::{Alignment, Constraint, Direction, Layout};
use tui::style::{Color, Style};
use tui::text::Spans;
use tui::widgets::{Block, List, ListItem, ListState, Paragraph};
use tui::{Frame, Terminal};
use uuid::Uuid;

const NONE: Option<&'static [u8]> = None;

struct StatefulList<T> {
    chosen: Option<usize>,
    state: ListState,
    items: Vec<T>,
}

impl<T> StatefulList<T> {
    fn with_items(items: Vec<T>) -> StatefulList<T> {
        let non_empty = !items.is_empty();
        let mut s = StatefulList {
            chosen: None,
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

    fn choose_currently_selected(&mut self) {
        if let Some(selected) = self.state.selected() {
            self.chosen = Some(selected);
        }
    }

    fn clear_chosen(&mut self) {
        self.chosen = None;
    }
}

fn find_block_devices() -> anyhow::Result<Vec<PathBuf>> {
    Ok(fs::read_dir("/sys/class/block")?
        .into_iter()
        .filter_map(|blk_dev| {
            let direntry = blk_dev.ok()?;
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

// UUID, label
#[derive(Debug, PartialEq, Eq)]
enum FsType {
    Ext4(String, String),
    Fat(String, String),
}

const FAT32_MAGIC_SIGNATURE_START: u64 = 82; // 82 to 89
const FAT32_LABEL_START: u64 = 71; // 71 to 81
const FAT32_UUID_START: u64 = 67; // 67 to 70

const EXT4_SUPERBLOCK_START: u64 = 1024;
const EXT4_MAGIC_SIGNATURE_START: u64 = EXT4_SUPERBLOCK_START + 0x38;
const EXT4_UUID_START: u64 = EXT4_SUPERBLOCK_START + 0x68;
const EXT4_LABEL_START: u64 = EXT4_SUPERBLOCK_START + 0x78;

fn detect_fs_type(p: impl AsRef<Path>) -> anyhow::Result<FsType> {
    let mut f = fs::File::open(p)?;

    // https://www.win.tue.nl/~aeb/linux/fs/fat/fat-1.html
    {
        f.seek(io::SeekFrom::Start(FAT32_MAGIC_SIGNATURE_START))?;
        let mut buffer = [0; 8];
        f.read_exact(&mut buffer)?;
        if let Ok("FAT32   ") = str::from_utf8(&buffer) {
            let uuid: String;
            let label: String;
            {
                f.seek(io::SeekFrom::Start(FAT32_UUID_START))?;
                let mut buffer = [0; 4];
                f.read_exact(&mut buffer)?;
                buffer.reverse();
                let mut s = String::new();
                write!(&mut s, "{:02X}", buffer[0]).expect("unable to write");
                write!(&mut s, "{:02X}", buffer[1]).expect("unable to write");
                write!(&mut s, "-").expect("unable to write");
                write!(&mut s, "{:02X}", buffer[2]).expect("unable to write");
                write!(&mut s, "{:02X}", buffer[3]).expect("unable to write");
                uuid = s
            }
            {
                f.seek(io::SeekFrom::Start(FAT32_LABEL_START))?;
                let mut buffer = [0; 11];
                f.read_exact(&mut buffer)?;
                label = String::from_utf8(buffer.to_vec())?.trim_end().to_string();
            }
            return Ok(FsType::Fat(uuid, label));
        }
    }

    // https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout
    {
        f.seek(io::SeekFrom::Start(EXT4_MAGIC_SIGNATURE_START))?;
        let mut buffer = [0; 2];
        f.read_exact(&mut buffer)?;
        let comp_buf = &nix::sys::statfs::EXT4_SUPER_MAGIC.0.to_le_bytes()[0..2];
        if buffer == comp_buf {
            let uuid: Uuid;
            {
                f.seek(io::SeekFrom::Start(EXT4_UUID_START))?;
                let mut buffer = [0; 16];
                f.read_exact(&mut buffer)?;
                uuid = Uuid::from_bytes(buffer);
            }
            let label: String;
            {
                f.seek(io::SeekFrom::Start(EXT4_LABEL_START))?;
                let mut buffer = [0; 16];
                f.read_exact(&mut buffer)?;
                label = String::from_utf8(buffer.to_vec())?
                    .trim_matches('\0')
                    .to_string();
            }
            return Ok(FsType::Ext4(uuid.to_string(), label));
        }
    }

    anyhow::bail!("unsupported fs type")
}

fn ui<B: Backend>(
    f: &mut Frame<B>,
    boot_entries: &mut StatefulList<MenuEntry>,
    (has_user_interaction, elapsed, timeout): (bool, Duration, Duration),
) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints(if has_user_interaction {
            vec![Constraint::Percentage(100)]
        } else {
            vec![Constraint::Percentage(90), Constraint::Percentage(10)]
        })
        .split(f.size());

    let (title, items): (String, Vec<ListItem>) = {
        if let Some(MenuEntry::SubMenu(submenu)) = boot_entries
            .chosen
            .and_then(|chosen| boot_entries.items.get(chosen))
        {
            (
                format!("tinyboot->{}", submenu.0,),
                submenu
                    .1
                    .iter()
                    .filter_map(|i| match i {
                        MenuEntry::BootEntry(boot_entry) => {
                            let lines = vec![Spans::from(boot_entry.1)];
                            Some(ListItem::new(lines))
                        }
                        _ => None, // nested submenus are not valid
                    })
                    .collect(),
            )
        } else {
            (
                String::from("tinyboot"),
                boot_entries
                    .items
                    .iter()
                    .map(|i| match i {
                        MenuEntry::BootEntry(boot_entry) => {
                            let lines = vec![Spans::from(boot_entry.1)];
                            ListItem::new(lines)
                        }
                        MenuEntry::SubMenu(submenu) => {
                            let lines = vec![Spans::from(format!("<->{}", submenu.0))];
                            ListItem::new(lines)
                        }
                    })
                    .collect(),
            )
        }
    };

    let items = List::new(items)
        .block(
            Block::default()
                .title(title)
                .title_alignment(Alignment::Center),
        )
        .highlight_style(Style::default().bg(Color::White).fg(Color::Black))
        .highlight_symbol(">>");

    f.render_stateful_widget(items, chunks[0], &mut boot_entries.state);

    if !has_user_interaction {
        let time_left = (timeout - elapsed).as_secs();
        let text = vec![Spans::from(format!(
            "Will boot automatically in {:?}s",
            time_left
        ))];
        let paragraph = Paragraph::new(text).alignment(Alignment::Center);
        f.render_widget(paragraph, chunks[1]);
    }
}

fn unmount(path: &Path) {
    if let Err(e) = nix::mount::umount2(path, mount::MntFlags::MNT_DETACH) {
        error!("umount2({}): {e}", path.display());
    }
}

fn logic<B: Backend>(terminal: &mut Terminal<B>) -> anyhow::Result<()> {
    let mut boot_loaders = find_block_devices()?
        .iter()
        .filter_map(|dev| {
            let mountpoint = PathBuf::from("/mnt").join(
                dev.to_str()
                    .expect("invalid unicode")
                    .trim_start_matches('/')
                    .replace('/', "-"),
            );

            let Ok(fstype) = detect_fs_type(dev) else { return None; };
            debug!("detected {:?} fstype on {}", fstype, dev.to_str()?);

            if let Err(e) = fs::create_dir_all(&mountpoint) {
                error!("failed to create mountpoint: {e}");
                return None;
            }

            if let Err(e) = nix::mount::mount(
                Some(dev.as_path()),
                &mountpoint,
                Some(match fstype {
                    FsType::Ext4(..) => "ext4",
                    FsType::Fat(..) => "fat",
                }),
                mount::MsFlags::MS_RDONLY,
                NONE,
            ) {
                error!("mount({}): {e}", dev.display());
                return None;
            };

            debug!("mounted {} at {}", dev.display(), mountpoint.display());

            let boot_loader: Box<dyn BootLoader> = 'loader: {
                // TODO(jared): enable grub boot loader
                // if let Ok(grub) = Grub::new(&mountpoint) {
                //     break 'loader Box::new(grub);
                // }
                if let Ok(syslinux) = SyslinuxBootLoader::new(&mountpoint) {
                    break 'loader Box::new(syslinux);
                }
                unmount(&mountpoint);
                return None;
            };

            Some(boot_loader)
        })
        .collect::<Vec<Box<dyn BootLoader>>>();

    let mut boot_loader = {
        if boot_loaders.is_empty() {
            anyhow::bail!("no boot configurations");
        } else {
            // TODO(jared): provide menu for picking device configuration
            let chosen_loader = boot_loaders.swap_remove(0);

            // unmount non-chosen devices
            for loader in boot_loaders {
                unmount(loader.mountpoint());
            }

            chosen_loader
        }
    };

    info!(
        "using boot loader from device mounted at {}",
        boot_loader.mountpoint().display()
    );

    enum Msg {
        Key(Key),
        Tick,
    }

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

    thread::spawn(move || {
        let mut keys = io::stdin().lock().keys();
        while let Some(Ok(key)) = keys.next() {
            if tx.send(Msg::Key(key)).is_err() {
                break;
            }
        }
    });

    terminal.clear()?;

    let start_instant = Instant::now();

    let mut has_user_interaction = false;

    let timeout = boot_loader.timeout();
    let menu_entries = boot_loader.menu_entries()?;
    let mut boot_entries = StatefulList::with_items(menu_entries);
    let selected_entry_id: Option<String> = 'selection: loop {
        terminal.draw(|f| {
            ui(
                f,
                &mut boot_entries,
                (has_user_interaction, start_instant.elapsed(), timeout),
            )
        })?;
        match rx.recv()? {
            Msg::Key(key) => {
                has_user_interaction = true;
                match key {
                    Key::Char('l') | Key::Char('\n') => {
                        let Some(entry) = boot_entries
                            .state
                            .selected()
                            .and_then(|idx| boot_entries.items.get(idx)) else { continue; };
                        match entry {
                            MenuEntry::BootEntry(entry) => {
                                break 'selection Some(entry.0.to_string())
                            }
                            MenuEntry::SubMenu(_) => boot_entries.choose_currently_selected(),
                        };
                    }
                    Key::Left | Key::Char('h') => boot_entries.clear_chosen(),
                    Key::Down | Key::Char('j') => boot_entries.next(),
                    Key::Up | Key::Char('k') => boot_entries.previous(),
                    Key::Char('r') => terminal.clear()?,
                    _ => {}
                };
            }
            Msg::Tick => {
                // Timeout has occurred without any user interaction
                if !has_user_interaction && start_instant.elapsed() >= timeout {
                    break 'selection None;
                }
            }
        }
    };

    let (kernel, initrd, cmdline, _dtb) = boot_loader.boot_info(selected_entry_id)?;
    kexec_load(kernel, initrd, cmdline)?;

    let mountpoint = boot_loader.mountpoint();
    unmount(mountpoint);

    Ok(kexec_execute()?)
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

    let stdout = io::stdout().lock().into_raw_mode()?;
    let backend = TermionBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    if let Err(e) = logic(&mut terminal) {
        error!("{e}");
    }

    terminal.show_cursor()?;

    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    #[ignore]
    // TODO(jared): figure out how to run these commands before running tests and cleanup after.
    // TODO(jared): Run these commands for setup:
    // dd bs=512M count=1 if=/dev/zero of=/tmp/disk.fat
    // mkfs.fat -n FOOBAR /tmp/disk.fat
    // dd bs=512M count=1 if=/dev/zero of=/tmp/disk.ext4
    // mkfs.ext4 -L foobar /tmp/disk.ext4
    fn detect_fs_type() {
        let fstype = super::detect_fs_type("/tmp/disk.fat").unwrap();
        eprintln!("{:#?}", fstype);
        let fstype = super::detect_fs_type("/tmp/disk.ext4").unwrap();
        eprintln!("{:#?}", fstype);
    }
}
