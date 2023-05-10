use ed25519_dalek::{PublicKey, Signature, Verifier};
use std::{fs, path::Path};

pub fn verify_artifacts(
    kernel: (impl AsRef<Path>, impl AsRef<str>),
    initrd: (impl AsRef<Path>, impl AsRef<str>),
) -> anyhow::Result<String> {
    let kernel_sig_path = kernel.0.as_ref().with_extension("sig");
    let initrd_sig_path = initrd.0.as_ref().with_extension("sig");
    if !kernel_sig_path.exists() || !initrd_sig_path.exists() {
        anyhow::bail!("cannot verify without signatures");
    }

    let public_key = PublicKey::from_bytes(include_bytes!(env!("VERIFIED_BOOT_PUBLIC_KEY")))?;

    for (digest, sig_path) in [
        (kernel.1.as_ref(), kernel_sig_path),
        (initrd.1.as_ref(), initrd_sig_path),
    ] {
        let signature = Signature::from_bytes(fs::read_to_string(sig_path)?.as_bytes())?;
        public_key.verify(digest.as_bytes(), &signature)?;
    }

    Ok(sha256::digest(public_key.as_bytes()))
}
