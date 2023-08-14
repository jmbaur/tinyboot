mod cli;
mod handlers;

use clap::Parser;
use cli::{TopLevel, TopLevelCommand};
use std::path::Path;

async fn run_top_level(args: TopLevel) -> anyhow::Result<()> {
    match args.command {
        TopLevelCommand::Reboot => handlers::handle_reboot().await,
        TopLevelCommand::Poweroff => handlers::handle_poweroff().await,
    }
}

pub async fn run(args: Vec<String>) -> anyhow::Result<()> {
    let top_level = TopLevel::try_parse_from(args)?;

    tboot::log::setup_logging(
        if top_level.verbose {
            log::LevelFilter::Debug
        } else {
            log::LevelFilter::Error
        },
        None::<&Path>,
    )
    .expect("failed to setup logging");

    run_top_level(top_level).await
}
