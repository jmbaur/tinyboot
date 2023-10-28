use std::{
    io::Read,
    sync::mpsc::{Receiver, Sender},
};

use crate::{cmd, ClientToServer, ServerToClient};
use log::{debug, error};

const PROMPT: &str = ">> ";

pub fn wait_for_user_presence(tx: Sender<ClientToServer>) {
    let mut stdin = std::io::stdin().lock();

    // This is a trash buffer just for detecting user input, we don't actually care about the
    // contents. Once we detect user input, we can print a prompt and start receiving real
    // commands from the user.
    let mut buf = [0; 1];
    stdin.read_exact(&mut buf).unwrap();
    debug!("user presence detected");

    // Send initial signal that a user is present.
    tx.send(ClientToServer::UserIsPresent).unwrap();
}

pub fn run_shell(tx: Sender<ClientToServer>, rx: Receiver<ServerToClient>) {
    match rx.recv().unwrap() {
        ServerToClient::Stop => return,
        ServerToClient::ServerIsReady => {}
    }

    let mut rl = rustyline::DefaultEditor::new().unwrap();
    rl.save_history("/run/history").unwrap();

    loop {
        let readline = rl.readline(PROMPT);

        match readline {
            Ok(line) => {
                if let Err(e) = rl.add_history_entry(line.clone()) {
                    debug!("failed to add input to history: {e}");
                }

                match cmd::parse_input(line) {
                    Err(e) => {
                        error!("failed to parse input: {e}");
                        continue;
                    }
                    Ok(None) => continue,
                    Ok(Some(cmd)) => {
                        tx.send(ClientToServer::Command(cmd)).unwrap();
                    }
                };
            }
            Err(e) => error!("readline error: {e}"),
        }

        match rx.recv().unwrap() {
            ServerToClient::Stop => break,
            ServerToClient::ServerIsReady => {}
        };
    }
}
