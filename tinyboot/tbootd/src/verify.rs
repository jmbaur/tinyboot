use log::debug;
use std::path::Path;

pub const PEM: &str = include_str!(env!("VERIFIED_BOOT_PUBLIC_KEY"));

pub fn verify_boot_payload(payload: impl AsRef<Path>) -> anyhow::Result<()> {
    let sig_path = tboot::verified_boot::signature_file_path(payload.as_ref());

    if !sig_path.exists() {
        anyhow::bail!("cannot verify without signatures");
    }

    debug!("Using initrd signature file at {:?}", sig_path);

    debug!("Using public key:");
    PEM.lines().for_each(|line| {
        debug!("{}", line);
    });

    tboot::verified_boot::verify(PEM, payload, &sig_path)?;

    Ok(())
}
