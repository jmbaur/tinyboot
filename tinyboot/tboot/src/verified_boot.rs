use ed25519_dalek::{
    ed25519::signature,
    pkcs8::{self, spki, DecodePrivateKey, DecodePublicKey},
    DigestSigner, Signature, SigningKey, VerifyingKey,
};
use sha2::{Digest, Sha512};
use std::{
    fs, io,
    path::{Path, PathBuf},
};

#[derive(thiserror::Error, Debug)]
pub enum VerifiedBootError {
    #[error("IO error: {0}")]
    Io(io::Error),
    #[error("PKCS8 error: {0}")]
    Pkcs8(pkcs8::Error),
    #[error("signature error: {0}")]
    Signature(signature::Error),
    #[error("spki error: {0}")]
    Spki(spki::Error),
    #[error("file already exists")]
    FileAlreadyExists,
}

impl From<io::Error> for VerifiedBootError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<signature::Error> for VerifiedBootError {
    fn from(value: signature::Error) -> Self {
        Self::Signature(value)
    }
}

impl From<pkcs8::Error> for VerifiedBootError {
    fn from(value: pkcs8::Error) -> Self {
        Self::Pkcs8(value)
    }
}

impl From<spki::Error> for VerifiedBootError {
    fn from(value: spki::Error) -> Self {
        Self::Spki(value)
    }
}

/// Get the signature path for a file to sign.
pub fn signature_file_path(p: impl AsRef<Path>) -> PathBuf {
    let extension = 'block: {
        let Some(extension) = p.as_ref().extension() else {
            break 'block "sig".to_string();
        };
        let Some(extension) = extension.to_str() else {
            break 'block "sig".to_string();
        };
        format!("{}.sig", extension)
    };

    p.as_ref().with_extension(extension)
}

pub fn sign(
    pem: &str,
    file_to_sign: impl AsRef<Path>,
    signature_file: impl AsRef<Path>,
) -> Result<(), VerifiedBootError> {
    if signature_file.as_ref().exists() {
        return Err(VerifiedBootError::FileAlreadyExists);
    }

    let signing_key = SigningKey::from_pkcs8_pem(pem)?;

    let mut file = fs::File::open(file_to_sign)?;
    let mut digest = Sha512::new();
    io::copy(&mut file, &mut digest)?;

    let signature = signing_key.try_sign_digest(digest)?;

    fs::write(signature_file, signature.to_bytes())?;

    Ok(())
}

pub fn verify(
    pem: &str,
    file_to_verify: impl AsRef<Path>,
    signature_file: impl AsRef<Path>,
) -> Result<VerifyingKey, VerifiedBootError> {
    let verifying_key = VerifyingKey::from_public_key_pem(pem)?;

    let mut file = fs::File::open(file_to_verify)?;
    let mut digest = Sha512::new();
    io::copy(&mut file, &mut digest)?;

    let signature = Signature::from_slice(fs::read(signature_file)?.as_slice())?;

    verifying_key.verify_prehashed(digest, None, &signature)?;

    Ok(verifying_key)
}

#[cfg(test)]
mod tests {
    use mktemp::Temp;
    use std::{fs, path::PathBuf};

    const PRIVATE_KEY: &str = r#"-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEINxJJ4IvE5lIw4nlYgGnXKVm1xLHakOc8SkM5klZwk2H
-----END PRIVATE KEY-----"#;

    const PUBLIC_KEY: &str = r#"-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAKPiHYO0He9hagQI1wwRes0y5P79JF4FDhkq890Uhobs=
-----END PUBLIC KEY-----"#;

    // TODO(jared): don't write to filesystem
    #[test]
    fn test_sign_and_verify() {
        let temp_file = Temp::new_file().unwrap();
        fs::write(temp_file.as_path(), "foobar").unwrap();
        super::sign(
            PRIVATE_KEY,
            temp_file.as_path(),
            PathBuf::from(format!("{}.sig", temp_file.as_path().to_str().unwrap())),
        )
        .expect("sign failed");
        super::verify(
            PUBLIC_KEY,
            temp_file.as_path(),
            PathBuf::from(format!("{}.sig", temp_file.as_path().to_str().unwrap())),
        )
        .expect("verify failed");
    }
}
