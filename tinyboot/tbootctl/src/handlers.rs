use std::fs;

use crate::cli::{SignCommand, VerifyCommand};
use log::debug;
use tboot::verified_boot;

pub fn handle_verified_boot_sign(args: &SignCommand) -> anyhow::Result<()> {
    let target_file = tboot::verified_boot::signature_file_path(&args.file);

    debug!("signing {:?} with {:?}", args.file, args.private_key);

    let pem = fs::read_to_string(&args.private_key)?;
    verified_boot::sign(&pem, &args.file, &target_file)?;

    debug!("detached signature written to {:?}", target_file);

    Ok(())
}

pub fn handle_verified_boot_verify(args: &VerifyCommand) -> anyhow::Result<()> {
    let pem = fs::read_to_string(&args.public_key)?;

    verified_boot::verify(&pem, &args.file, &args.signature_file)?;

    Ok(())
}
