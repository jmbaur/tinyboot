use nix::libc;
use std::io;
use std::io::Write;
use termion::input::TermRead;

const USAGE_STRING: &str = r#"Usage:

reset - reset the machine
help  - print help output
"#;

fn run_command(input: String) {
    let mut split = input.split_whitespace();
    let Some(first) = split.next() else { return; };

    match first {
        "reset" => {
            let ret = unsafe { libc::reboot(libc::LINUX_REBOOT_CMD_RESTART) };
            if ret < 0 {
                eprintln!("{}", io::Error::last_os_error());
            }
        }
        "help" => print!("{USAGE_STRING}"),
        _ => eprintln!("unknown command: {}", first),
    }
}

pub fn shell() -> ! {
    let mut stdout = io::stdout().lock();
    let mut stdin = io::stdin().lock();
    loop {
        write!(stdout, ">> ").unwrap();
        stdout.flush().unwrap();
        let Ok(Some(input)) = stdin.read_line() else {
            continue;
        };
        run_command(input);
        stdout.flush().unwrap();
    }
}
