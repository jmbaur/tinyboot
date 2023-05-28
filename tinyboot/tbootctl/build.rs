use clap::CommandFactory;
use clap_complete::{
    generate_to,
    shells::{Bash, Fish, Zsh},
};
use std::{env, io::Error};

include!("src/cli.rs");

fn main() -> Result<(), Error> {
    let outdir = match env::var_os("OUT_DIR") {
        None => return Ok(()),
        Some(outdir) => outdir,
    };

    let mut cmd = TopLevel::command();
    generate_to(Bash, &mut cmd, "tbootctl", &outdir)?;
    generate_to(Fish, &mut cmd, "tbootctl", &outdir)?;
    generate_to(Zsh, &mut cmd, "tbootctl", &outdir)?;

    Ok(())
}
