use log::debug;
use sha2::{Digest, Sha256};
use std::path::Path;

const PEM: &str = include_str!(env!("VERIFIED_BOOT_PUBLIC_KEY"));

pub fn verify_boot_payloads(
    kernel: impl AsRef<Path>,
    initrd: impl AsRef<Path>,
) -> anyhow::Result<Vec<u8>> {
    let kernel_sig_path = tboot::verified_boot::signature_file_path(kernel.as_ref());
    let initrd_sig_path = tboot::verified_boot::signature_file_path(initrd.as_ref());

    if !kernel_sig_path.exists() || !initrd_sig_path.exists() {
        anyhow::bail!("cannot verify without signatures");
    }

    debug!("Using kernel signature file at {:?}", kernel_sig_path);
    debug!("Using initrd signature file at {:?}", initrd_sig_path);

    debug!("Using public key:");
    PEM.lines().for_each(|line| {
        debug!("  {}", line);
    });

    tboot::verified_boot::verify(PEM, kernel, &kernel_sig_path)?;
    tboot::verified_boot::verify(PEM, initrd, &initrd_sig_path)?;

    let key_digest = Sha256::digest(PEM);

    Ok(key_digest.to_vec())
}
