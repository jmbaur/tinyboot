use std::str::{FromStr, SplitWhitespace};

use log::error;

use crate::boot_loader::LoaderType;

#[derive(Debug, Clone)]
pub enum Command {
    Loader(Option<LoaderType>),
    Help(Option<String>),
    List,
    Select((usize, usize)),
    Boot,
    Reboot,
    Poweroff,
}

pub fn parse_input(input: String) -> anyhow::Result<Option<Command>> {
    let mut iter = input.split_whitespace().into_iter();

    let Some(cmd) = iter.next() else {
        return Ok(None);
    };

    if cmd.is_empty() {
        return Ok(None);
    }

    Ok(Some(match cmd {
        "boot" => Command::Boot,
        "help" => Command::Help(iter.next().map(|s| s.to_string())),
        "list" => Command::List,
        "loader" => parse_loader(iter)?,
        "poweroff" => Command::Poweroff,
        "reboot" => Command::Reboot,
        "select" => parse_select(iter)?,
        _ => anyhow::bail!("unknown command '{input}'"),
    }))
}

fn parse_loader(mut iter: SplitWhitespace<'_>) -> anyhow::Result<Command> {
    Ok(Command::Loader(
        iter.next().map(LoaderType::from_str).transpose()?,
    ))
}

fn parse_select(mut iter: SplitWhitespace<'_>) -> anyhow::Result<Command> {
    let dev = iter
        .next()
        .map(|dev| usize::from_str_radix(dev, 10))
        .ok_or(anyhow::anyhow!("no device number specified"))??;

    let entry = iter
        .next()
        .map(|entry| usize::from_str_radix(entry, 10))
        .ok_or(anyhow::anyhow!("no entry number specified"))??;

    Ok(Command::Select((dev, entry)))
}

pub fn print_help(cmd_to_help: Option<&str>) {
    match cmd_to_help.as_deref() {
        Some("list") => print_list_usage(),
        Some("select") => print_select_usage(),
        Some("boot") => print_boot_usage(),
        Some("reboot") => print_reboot_usage(),
        Some("poweroff") => print_poweroff_usage(),
        Some("loader") => print_loader_usage(),
        Some(_) => error!(""),
        None => print_all_usage(),
    }
}

// use line wrap of 80 characters by wrapping at 78, then indenting by 2 spaces
macro_rules! print_usage {
    ($x:expr) => {
        textwrap::wrap(($x).trim_matches(char::is_whitespace), 78)
            .iter()
            .for_each(|line| {
                println!("{}", textwrap::indent(line, "  "));
            });
    };
}

const POWEROFF_USAGE: &str = r#"
Immediately poweroff the machine.
"#;

fn print_poweroff_usage() {
    println!();
    println!("poweroff");
    print_usage!(POWEROFF_USAGE);
}

const REBOOT_USAGE: &str = r#"
Immediately reboot the machine.
"#;

fn print_reboot_usage() {
    println!();
    println!("reboot");
    print_usage!(REBOOT_USAGE);
}

fn print_all_usage() {
    println!();
    println!("list\t\tlist all boot entries");
    println!("select\t\tselect a boot entry");
    println!("boot\t\tboot from selection");
    println!("reboot\t\treboot the machine");
    println!("poweroff\tpoweroff the machine");
}

const BOOT_USAGE: &str = r#"
Boot from the selected entry. If no entry is selected, boot from the default entry.
"#;

fn print_boot_usage() {
    println!();
    println!("boot");
    print_usage!(BOOT_USAGE);
}

const SELECT_USAGE: &str = r#"
Select an entry to boot from.
"#;

fn print_select_usage() {
    println!();
    println!("select");
    print_usage!(SELECT_USAGE);
}

const LIST_USAGE: &str = r#"
List all detected boot entries.
"#;

fn print_list_usage() {
    println!();
    println!("list");
    print_usage!(LIST_USAGE);
}

const LOADER_USAGE: &str = r#"
Select or print current boot loader.
"#;

fn print_loader_usage() {
    println!();
    println!("loader");
    print_usage!(LOADER_USAGE);
}
