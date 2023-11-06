use std::str::{FromStr, SplitWhitespace};

use log::error;

use crate::boot_loader::LoaderType;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Loader(Option<LoaderType>),
    Help(Option<String>),
    List,
    Boot((Option<usize>, Option<usize>)),
    Reboot,
    Poweroff,
    Dmesg,
    Rescan,
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
        "boot" => parse_boot(iter)?,
        "help" => Command::Help(iter.next().map(|s| s.to_string())),
        "loader" => parse_loader(iter)?,
        "list" => Command::List,
        "rescan" => Command::Rescan,
        "poweroff" => Command::Poweroff,
        "reboot" => Command::Reboot,
        "dmesg" => Command::Dmesg,
        _ => anyhow::bail!("unknown command '{input}'"),
    }))
}

fn parse_loader(mut iter: SplitWhitespace<'_>) -> anyhow::Result<Command> {
    Ok(Command::Loader(
        iter.next().map(LoaderType::from_str).transpose()?,
    ))
}

fn parse_boot(mut iter: SplitWhitespace<'_>) -> anyhow::Result<Command> {
    let dev = iter
        .next()
        .map(|dev| usize::from_str_radix(dev, 10))
        .transpose()?;

    let entry = iter
        .next()
        .map(|entry| usize::from_str_radix(entry, 10))
        .transpose()?;

    Ok(Command::Boot((dev, entry)))
}

pub fn print_help(cmd_to_help: Option<&str>) {
    match cmd_to_help.as_deref() {
        Some("list") => print_list_usage(),
        Some("boot") => print_boot_usage(),
        Some("reboot") => print_reboot_usage(),
        Some("poweroff") => print_poweroff_usage(),
        Some("loader") => print_loader_usage(),
        Some("dmesg") => print_dmesg_usage(),
        Some("rescan") => print_rescan_usage(),
        Some(_) => error!(""),
        None => print_all_usage(),
    }
}

const POWEROFF_USAGE: &str = r#"
Immediately poweroff the machine.
"#;

fn print_poweroff_usage() {
    println!();
    println!("poweroff");
    println!("{POWEROFF_USAGE}");
}

const REBOOT_USAGE: &str = r#"
Immediately reboot the machine.
"#;

fn print_reboot_usage() {
    println!();
    println!("reboot");
    println!("{REBOOT_USAGE}");
}

fn print_all_usage() {
    println!();
    println!("list\t\tlist all boot entries");
    println!("boot\t\tboot from selection");
    println!("dmesg\t\tprint kernel logs");
    println!("reboot\t\treboot the machine");
    println!("poweroff\tpoweroff the machine");
}

const BOOT_USAGE: &str = r#"
Boot from the selected entry. If no entry is selected, boot from the default entry.
"#;

fn print_boot_usage() {
    println!();
    println!("boot");
    println!("{BOOT_USAGE}");
}

const LIST_USAGE: &str = r#"
List all detected boot entries.
"#;

fn print_list_usage() {
    println!();
    println!("list");
    println!("{LIST_USAGE}");
}

const LOADER_USAGE: &str = r#"
Select or print current boot loader.
"#;

fn print_loader_usage() {
    println!();
    println!("loader");
    println!("{LOADER_USAGE}");
}

const DMESG_USAGE: &str = r#"
Print kernel logs.
"#;

fn print_dmesg_usage() {
    println!();
    println!("dmesg");
    println!("{DMESG_USAGE}");
}

const RESCAN_USAGE: &str = r#"
Rescan loader for devices and boot entries.
"#;

fn print_rescan_usage() {
    println!();
    println!("rescan");
    println!("{RESCAN_USAGE}");
}
