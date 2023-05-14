use crate::cli::{SignCommand, VerifyCommand};
use log::debug;
use tboot::verified_boot;

pub fn handle_verified_boot_sign(args: &SignCommand) -> anyhow::Result<()> {
    let new_ext = if let Some(ext) = args.file.extension() {
        format!(
            "{}.sig",
            ext.to_str().ok_or(anyhow::anyhow!("invalid UTF-8"))?
        )
    } else {
        String::from("sig")
    };

    let target_file = args.file.with_extension(new_ext);

    debug!("signing {:?} with {:?}", args.file, args.private_key);

    verified_boot::sign(&args.private_key, &args.file, &target_file)?;

    debug!("detached signature at {:?}", target_file);

    Ok(())
}

pub fn handle_verified_boot_verify(args: &VerifyCommand) -> anyhow::Result<()> {
    verified_boot::verify(&args.public_key, &args.file, &args.signature_file)?;

    Ok(())
}
