use clap::{Args, Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
pub struct TopLevel {
    #[command(subcommand)]
    pub command: TopLevelCommand,

    #[arg(short, long, global = true)]
    pub verbose: bool,
}

#[derive(Subcommand)]
pub enum TopLevelCommand {
    VerifiedBoot(VerifiedBoot),
    Reboot,
    Poweroff,
}

#[derive(Args)]
pub struct VerifiedBoot {
    #[command(subcommand)]
    pub command: VerifiedBootCommand,
}

#[derive(Subcommand)]
pub enum VerifiedBootCommand {
    Sign(SignCommand),
    Verify(VerifyCommand),
}

#[derive(Args, Debug)]
pub struct SignCommand {
    #[arg(short, long, value_parser)]
    pub file: PathBuf,

    #[arg(short, long, value_parser)]
    pub private_key: PathBuf,
}

#[derive(Args, Debug)]
pub struct VerifyCommand {
    #[arg(short, long, value_parser)]
    pub file: PathBuf,

    #[arg(short, long, value_parser)]
    pub signature_file: PathBuf,

    #[arg(short, long, value_parser)]
    pub public_key: PathBuf,
}
