use sha2::{Digest, Sha256, Sha512};
use std::{fs, io, path::Path};

pub fn sha256_digest_file(p: impl AsRef<Path>) -> io::Result<Vec<u8>> {
    let mut file = fs::File::open(p)?;
    let mut hasher = Sha256::new();
    io::copy(&mut file, &mut hasher)?;
    let hash = hasher.finalize();
    let hash = hash.as_slice();
    Ok(hash.to_vec())
}

pub fn sha512_digest_file(p: impl AsRef<Path>) -> io::Result<Vec<u8>> {
    let mut file = fs::File::open(p)?;
    let mut hasher = Sha512::new();
    io::copy(&mut file, &mut hasher)?;
    let hash = hasher.finalize();
    let hash = hash.as_slice();
    Ok(hash.to_vec())
}
