use ed25519_dalek::{pkcs8::DecodePublicKey, verify_batch, Signature, VerifyingKey};
use log::debug;
use std::{fs, path::Path};

pub fn verify_artifacts(
    kernel: (impl AsRef<Path>, impl AsRef<str>),
    initrd: (impl AsRef<Path>, impl AsRef<str>),
) -> anyhow::Result<String> {
    let kernel_extension = if let Some(kernel_extension) = kernel.0.as_ref().extension() {
        format!(
            "{}.sig",
            kernel_extension
                .to_str()
                .ok_or(anyhow::anyhow!("invalid UTF-8"))?
        )
    } else {
        String::from("sig")
    };
    let kernel_sig_path = kernel.0.as_ref().with_extension(kernel_extension);

    let initrd_extension = if let Some(initrd_extension) = initrd.0.as_ref().extension() {
        format!(
            "{}.sig",
            initrd_extension
                .to_str()
                .ok_or(anyhow::anyhow!("invalid UTF-8"))?
        )
    } else {
        String::from("sig")
    };
    let initrd_sig_path = initrd.0.as_ref().with_extension(initrd_extension);

    debug!("Using kernel signature file at {:?}", kernel_sig_path);
    debug!("Using initrd signature file at {:?}", initrd_sig_path);

    if !kernel_sig_path.exists() || !initrd_sig_path.exists() {
        anyhow::bail!("cannot verify without signatures");
    }

    let pem = include_str!(env!("VERIFIED_BOOT_PUBLIC_KEY"));

    debug!("Using public key: {}", pem);

    let verifying_key = VerifyingKey::from_public_key_pem(pem).map_err(|e| anyhow::anyhow!(e))?;

    verify_batch(
        &[kernel.1.as_ref().as_bytes(), initrd.1.as_ref().as_bytes()],
        &[
            Signature::from_slice(fs::read(kernel_sig_path)?.as_slice())?,
            Signature::from_slice(fs::read(initrd_sig_path)?.as_slice())?,
        ],
        &[verifying_key, verifying_key],
    )?;

    Ok(sha256::digest(verifying_key.as_bytes()))
}
