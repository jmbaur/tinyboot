use std::path::PathBuf;

use ratatui::{backend::TermionBackend, Terminal};
use tboot::linux::LinuxBootEntry;
use termion::{raw::IntoRawMode, screen::IntoAlternateScreen};

extern crate tbootui;

fn main() {
    let mut terminal = Terminal::new(TermionBackend::new(
        std::io::stdout()
            .into_raw_mode()
            .unwrap()
            .into_alternate_screen()
            .unwrap(),
    ))
    .unwrap();

    let edited = tbootui::edit(
        LinuxBootEntry {
            default: false,
            display: String::from("foo entry"),
            linux: PathBuf::from("/vmlinuz"),
            initrd: None,
            cmdline: None,
        },
        &mut terminal,
    );

    drop(terminal);

    if let Some(entry) = edited {
        println!("{:#?}", entry);
    } else {
        println!("edit canceled");
    }
}
