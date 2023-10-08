use std::str::SplitWhitespace;

#[derive(Debug, Clone)]
pub enum Command {
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

    if cmd == "help" {
        print_help(iter.next());
        return Ok(None);
    }

    Ok(Some(match cmd {
        "list" => Command::List,
        "select" => parse_select(iter)?,
        "boot" => Command::Boot,
        "reboot" => Command::Reboot,
        "poweroff" => Command::Poweroff,
        _ => anyhow::bail!("unknown command '{input}'"),
    }))
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

fn print_help(cmd_to_help: Option<&str>) {
    match cmd_to_help {
        Some("list") => print_list_usage(),
        Some("select") => print_select_usage(),
        Some("boot") => print_boot_usage(),
        Some("reboot") => print_reboot_usage(),
        Some("poweroff") => print_poweroff_usage(),
        Some(_) | None => print_all_usage(),
    }
}

fn print_poweroff_usage() {
    println!();
    println!("poweroff");
    println!("\timmediately poweroff the machine");
}

fn print_reboot_usage() {
    println!();
    println!("reboot");
    println!("\timmediately reboot the machine");
}

fn print_all_usage() {
    println!();
    println!("list\t\t\tlist all boot entries");
    println!("select\t\t\tselect a boot entry");
    println!("boot\t\t\tboot from selection");
    println!("reboot\t\t\treboot the machine");
    println!("poweroff\t\tpoweroff the machine");
}

fn print_boot_usage() {
    println!();
    println!("boot");
    println!("\tTODO");
}

fn print_select_usage() {
    println!();
    println!("select");
    println!("\tTODO");
}

fn print_list_usage() {
    println!();
    println!("list");
    println!("\tTODO");
}
