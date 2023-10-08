use std::{io::Read, time::Duration};

use crate::cmd;
use log::{debug, info};
use raw_sync::{
    events::{Event, EventInit, EventState},
    Timeout,
};
use shared_memory::ShmemConf;

const PROMPT: &str = ">> ";

pub fn run_shell() -> anyhow::Result<()> {
    let mut rl = rustyline::DefaultEditor::new()?;
    rl.save_history("/run/history")?;

    let mut stdin = std::io::stdin().lock();

    // This is a trash buffer just for detecting user input, we don't actually care about the
    // contents. Once we detect user input, we can print a prompt and start receiving real
    // commands from the user.
    let mut buf = [0; 1];
    stdin.read_exact(&mut buf)?;

    let shmem = loop {
        if std::fs::metadata("/run/tboot.ready").is_ok() {
            break ShmemConf::new().flink("/run/tboot.shmem").open()?;
        }
        std::thread::sleep(Duration::from_millis(100));
    };

    let (tx_evt, _tx_used_bytes) = (unsafe { Event::from_existing(shmem.as_ptr()) })
        .map_err(|e| anyhow::anyhow!("get shell tx event error {e}"))?;

    let (rx_evt, _rx_used_bytes) = (unsafe { Event::from_existing(shmem.as_ptr().add(256)) })
        .map_err(|e| anyhow::anyhow!("get shell rx event error {e}"))?;

    let cmd_loc = unsafe { shmem.as_ptr().add(2 * 256) };

    // Send initial signal that a user is present.
    tx_evt
        .set(EventState::Signaled)
        .map_err(|e| anyhow::anyhow!("tx signal error {e}"))?;

    loop {
        let readline = rl.readline(PROMPT);

        match readline {
            Ok(line) => {
                if let Err(e) = rl.add_history_entry(line.clone()) {
                    debug!("failed to add input to history: {e}");
                }

                match cmd::parse_input(line) {
                    Err(e) => {
                        println!("{e}");
                        continue;
                    }
                    Ok(None) => continue,
                    Ok(Some(cmd)) => {
                        unsafe { std::ptr::write(cmd_loc as *mut cmd::Command, cmd) };
                        tx_evt
                            .set(EventState::Signaled)
                            .map_err(|e| anyhow::anyhow!("tx signal error {e}"))?;
                    }
                };
            }
            Err(_) => {}
        }

        info!("waiting for daemon to be ready to accept new commands");
        rx_evt
            .wait(Timeout::Infinite)
            .map_err(|e| anyhow::anyhow!("rx wait error {e}"))?;
        rx_evt
            .set(EventState::Clear)
            .map_err(|e| anyhow::anyhow!("rx clear error {e}"))?;
    }
}
