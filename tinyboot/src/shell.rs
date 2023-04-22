use nix::libc;
use std::io;
use std::io::Write;
use termion::input::TermRead;

const USAGE_STRING: &str = r#"Usage:
reboot   - restart the machine
poweroff - poweroff the machine
help     - print help output
"#;

fn run_command(input: String) {
    let mut split = input.split_whitespace();
    let Some(first) = split.next() else { return; };

    // Busybox's /init signal handling:
    // https://github.com/mirror/busybox/blob/2d4a3d9e6c1493a9520b907e07a41aca90cdfd94/init/init.c#L826
    // SIGTERM => reboot
    // SIGUSR2 => poweroff
    match first {
        "reboot" => unsafe {
            libc::kill(1, libc::SIGTERM);
        },
        "poweroff" => unsafe {
            libc::kill(1, libc::SIGUSR2);
        },
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
