use crate::cli::{SignCommand, VerifyCommand};
use futures::{SinkExt, StreamExt};
use log::{debug, info};
use std::fs;
use tboot::{
    message::{Request, Response},
    verified_boot,
};

pub(crate) fn handle_verified_boot_sign(args: &SignCommand) -> anyhow::Result<()> {
    let target_file = tboot::verified_boot::signature_file_path(&args.file);

    debug!("signing {:?}", args.file);

    let pem = fs::read_to_string(&args.private_key)?;
    match verified_boot::sign(&pem, &args.file, &target_file) {
        Ok(()) => debug!("detached signature written to {:?}", target_file),
        Err(verified_boot::VerifiedBootError::FileAlreadyExists) => {
            info!("file at signature file path already exists");
        }
        Err(e) => return Err(e.into()),
    }

    Ok(())
}

pub(crate) fn handle_verified_boot_verify(args: &VerifyCommand) -> anyhow::Result<()> {
    let pem = fs::read_to_string(&args.public_key)?;

    verified_boot::verify(&pem, &args.file, &args.signature_file)?;

    Ok(())
}

pub(crate) async fn handle_reboot() -> Result<(), anyhow::Error> {
    let (mut sink, mut stream) = tboot::message::get_client_codec(None).await?;
    sink.send(Request::Reboot).await?;
    if matches!(stream.next().await, Some(Ok(Response::ServerDone))) {
        Ok(())
    } else {
        Err(anyhow::anyhow!("could not poweroff"))
    }
}

pub(crate) async fn handle_poweroff() -> Result<(), anyhow::Error> {
    let (mut sink, mut stream) = tboot::message::get_client_codec(None).await?;
    sink.send(Request::Poweroff).await?;
    if matches!(stream.next().await, Some(Ok(Response::ServerDone))) {
        Ok(())
    } else {
        Err(anyhow::anyhow!("could not poweroff"))
    }
}
