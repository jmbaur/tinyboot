mod cli;
mod handlers;

use clap::Parser;
use cli::{TopLevel, TopLevelCommand, VerifiedBootCommand};
use log::error;
use std::{path::Path, process};

async fn run_top_level(args: TopLevel) -> anyhow::Result<()> {
    match args.command {
        TopLevelCommand::Reboot => handlers::handle_reboot().await,
        TopLevelCommand::Poweroff => handlers::handle_poweroff().await,
        TopLevelCommand::VerifiedBoot(vboot_args) => match vboot_args.command {
            VerifiedBootCommand::Sign(sign_args) => handlers::handle_verified_boot_sign(&sign_args),
            VerifiedBootCommand::Verify(verify_args) => {
                handlers::handle_verified_boot_verify(&verify_args)
            }
        },
    }
}

#[tokio::main]
async fn main() {
    let top_level = TopLevel::parse();

    tboot::log::setup_logging(
        if top_level.verbose {
            log::LevelFilter::Debug
        } else {
            log::LevelFilter::Error
        },
        None::<&Path>,
    )
    .expect("failed to setup logging");

    if let Err(e) = run_top_level(top_level).await {
        error!("{e:?}");
        process::exit(1);
    }
}
