use std::{
    io::{Read, Write},
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

    let mut stdout = std::io::stdout();

    loop {
        print!("{PROMPT}");
        stdout.flush().unwrap();

        let mut input = String::new();

        match std::io::stdin().read_line(&mut input) {
            Ok(bytes_read) => {
                // remove newline
                if bytes_read > 0 {
                    input.truncate(bytes_read - 1);
                }

                match cmd::parse_input(input) {
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
