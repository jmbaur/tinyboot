use log::{debug, error};
use nix::mount;
use std::fmt::Write;
use std::path::PathBuf;
use std::{
    fs,
    io::{self, Read, Seek},
    path::Path,
};
use uuid::Uuid;

// UUID, label
#[derive(Debug, PartialEq, Eq)]
pub enum FsType {
    Ext4(String, String),
    Fat32(String, String),
    Fat16(String, String),
}

/// formatted as (start, length)
/// FAT documentation: https://www.win.tue.nl/~aeb/linux/fs/fat/fat-1.html
/// EXT4 documentation: https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout
mod fs_constants {
    pub const FAT_MAGIC_SIGNATURE_START: u64 = 510;
    pub const FAT_MAGIC_SIGNATURE_LENGTH: usize = 2;

    pub const FAT32_IDENTIFIER_START: u64 = 82;
    pub const FAT32_IDENTIFIER_LENGTH: usize = 8;
    pub const FAT32_LABEL_START: u64 = 71;
    pub const FAT32_LABEL_LENGTH: usize = 11;
    pub const FAT32_UUID_START: u64 = 67;
    pub const FAT32_UUID_LENGTH: usize = 4;

    pub const FAT16_IDENTIFIER_START: u64 = 54;
    pub const FAT16_IDENTIFIER_LENGTH: usize = 8;
    pub const FAT16_LABEL_START: u64 = 43;
    pub const FAT16_LABEL_LENGTH: usize = 11;
    pub const FAT16_UUID_START: u64 = 39;
    pub const FAT16_UUID_LENGTH: usize = 4;

    pub const EXT4_SUPERBLOCK_START: u64 = 0x400;
    pub const EXT4_MAGIC_SIGNATURE_START: u64 = EXT4_SUPERBLOCK_START + 0x38;
    pub const EXT4_MAGIC_SIGNATURE_LENGTH: usize = 2;
    pub const EXT4_UUID_START: u64 = EXT4_SUPERBLOCK_START + 0x68;
    pub const EXT4_UUID_LENGTH: usize = 16;
    pub const EXT4_LABEL_START: u64 = EXT4_SUPERBLOCK_START + 0x78;
    pub const EXT4_LABEL_LENGTH: usize = 16;
}

pub fn detect_fs_type(p: impl AsRef<Path>) -> anyhow::Result<FsType> {
    let mut f = fs::File::open(p)?;

    {
        // fat detection
        f.seek(io::SeekFrom::Start(fs_constants::FAT_MAGIC_SIGNATURE_START))?;
        let mut buffer = [0; fs_constants::FAT_MAGIC_SIGNATURE_LENGTH];
        f.read_exact(&mut buffer)?;
        if buffer == [0x55u8, 0xaau8] {
            // fat32 detection
            {
                f.seek(io::SeekFrom::Start(fs_constants::FAT32_IDENTIFIER_START))?;
                let mut buffer = [0; fs_constants::FAT32_IDENTIFIER_LENGTH];
                f.read_exact(&mut buffer)?;

                if std::str::from_utf8(&buffer)
                    .map(|res| res == "FAT32   ")
                    .unwrap_or(false)
                {
                    let uuid: String;
                    let label: String;
                    {
                        f.seek(io::SeekFrom::Start(fs_constants::FAT32_UUID_START))?;
                        let mut buffer = [0; fs_constants::FAT32_UUID_LENGTH];
                        f.read_exact(&mut buffer)?;
                        buffer.reverse();
                        let mut s = String::new();
                        write!(&mut s, "{:02X}", buffer[0]).expect("unable to write");
                        write!(&mut s, "{:02X}", buffer[1]).expect("unable to write");
                        write!(&mut s, "-").expect("unable to write");
                        write!(&mut s, "{:02X}", buffer[2]).expect("unable to write");
                        write!(&mut s, "{:02X}", buffer[3]).expect("unable to write");
                        uuid = s
                    }
                    {
                        f.seek(io::SeekFrom::Start(fs_constants::FAT32_LABEL_START))?;
                        let mut buffer = [0; fs_constants::FAT32_LABEL_LENGTH];
                        f.read_exact(&mut buffer)?;
                        label = String::from_utf8(buffer.to_vec())?.trim_end().to_string();
                    }
                    return Ok(FsType::Fat32(uuid, label));
                };
            }

            // fat16 detection
            {
                f.seek(io::SeekFrom::Start(fs_constants::FAT16_IDENTIFIER_START))?;
                let mut buffer = [0; fs_constants::FAT16_IDENTIFIER_LENGTH];
                f.read_exact(&mut buffer)?;

                if std::str::from_utf8(&buffer)
                    .map(|res| res == "FAT16   ")
                    .unwrap_or(false)
                {
                    let uuid: String;
                    let label: String;
                    {
                        f.seek(io::SeekFrom::Start(fs_constants::FAT16_UUID_START))?;
                        let mut buffer = [0; fs_constants::FAT16_UUID_LENGTH];
                        f.read_exact(&mut buffer)?;
                        buffer.reverse();
                        let mut s = String::new();
                        write!(&mut s, "{:02X}", buffer[0]).expect("unable to write");
                        write!(&mut s, "{:02X}", buffer[1]).expect("unable to write");
                        write!(&mut s, "-").expect("unable to write");
                        write!(&mut s, "{:02X}", buffer[2]).expect("unable to write");
                        write!(&mut s, "{:02X}", buffer[3]).expect("unable to write");
                        uuid = s
                    }
                    {
                        f.seek(io::SeekFrom::Start(fs_constants::FAT16_LABEL_START))?;
                        let mut buffer = [0; fs_constants::FAT16_LABEL_LENGTH];
                        f.read_exact(&mut buffer)?;
                        label = String::from_utf8(buffer.to_vec())?.trim_end().to_string();
                    }
                    return Ok(FsType::Fat16(uuid, label));
                };
            }
        }
    }

    // ext4 detection
    {
        f.seek(io::SeekFrom::Start(
            fs_constants::EXT4_MAGIC_SIGNATURE_START,
        ))?;
        let mut buffer = [0; fs_constants::EXT4_MAGIC_SIGNATURE_LENGTH];
        f.read_exact(&mut buffer)?;
        let comp_buf = &nix::sys::statfs::EXT4_SUPER_MAGIC.0.to_le_bytes()
            [0..fs_constants::EXT4_MAGIC_SIGNATURE_LENGTH];
        if buffer == comp_buf {
            let uuid: Uuid;
            {
                f.seek(io::SeekFrom::Start(fs_constants::EXT4_UUID_START))?;
                let mut buffer = [0; fs_constants::EXT4_UUID_LENGTH];
                f.read_exact(&mut buffer)?;
                uuid = Uuid::from_bytes(buffer);
            }
            let label: String;
            {
                f.seek(io::SeekFrom::Start(fs_constants::EXT4_LABEL_START))?;
                let mut buffer = [0; fs_constants::EXT4_LABEL_LENGTH];
                f.read_exact(&mut buffer)?;
                label = String::from_utf8(buffer.to_vec())?
                    .trim_matches('\0')
                    .to_string();
            }
            return Ok(FsType::Ext4(uuid.to_string(), label));
        }
    }

    anyhow::bail!("unsupported fs type")
}

pub fn unmount(path: &Path) {
    if let Err(e) = nix::mount::umount2(path, mount::MntFlags::MNT_DETACH) {
        error!("umount2({}): {e}", path.display());
    }
}

pub fn find_block_device<F>(filter: F) -> anyhow::Result<Vec<PathBuf>>
where
    F: Fn(&Path) -> bool,
{
    Ok(fs::read_dir("/sys/class/block")?
        .filter_map(|blk_dev| {
            let direntry = blk_dev.ok()?;
            let mut path = direntry.path();
            path.push("uevent");
            match fs::read_to_string(path).map(|uevent| {
                let mut is_partition = false;
                let mut dev_path = PathBuf::from("/dev");
                for line in uevent.lines() {
                    if line == "DEVTYPE=partition" {
                        is_partition = true;
                    }
                    if line.starts_with("DEVNAME") {
                        dev_path.push(line.split_once('=').expect("invalid DEVNAME").1);
                    }
                }
                (is_partition, dev_path)
            }) {
                Ok((true, dev_path)) => {
                    if filter(&dev_path) {
                        debug!("found block device at {dev_path:?}");
                        Some(dev_path)
                    } else {
                        None
                    }
                }
                _ => None,
            }
        })
        .collect::<Vec<PathBuf>>())
}

#[cfg(test)]
mod tests {
    use std::{path::PathBuf, process::Command};

    fn filesystems() -> Vec<(&'static str, &'static str, Vec<&'static str>)> {
        vec![
            ("/tmp/disk.fat32", "mkfs.fat", vec!["-F32", "-n", "FOOBAR"]),
            ("/tmp/disk.fat16", "mkfs.fat", vec!["-F16", "-n", "FOOBAR"]),
            ("/tmp/disk.ext4", "mkfs.ext4", vec!["-L", "foobar"]),
        ]
    }

    fn setup() {
        for fs in filesystems() {
            Command::new("dd")
                .arg("bs=512M")
                .arg("count=1")
                .arg("if=/dev/zero")
                .arg(format!("of={}", fs.0))
                .output()
                .expect("failed to allocate disk");
            let mut mkfs = Command::new(fs.1);
            for flag in fs.2 {
                mkfs.arg(flag);
            }
            mkfs.arg(fs.0)
                .output()
                .expect("failed to create filesystem");
        }
    }

    fn teardown() {
        for fs in filesystems() {
            std::fs::remove_file(PathBuf::from(fs.0)).unwrap();
        }
    }

    #[test]
    #[ignore]
    fn detect_fs_type() {
        setup();

        let fstype = super::detect_fs_type("/tmp/disk.fat32").unwrap();
        assert!(match fstype {
            crate::fs::FsType::Fat32(_, label) => label == "FOOBAR",
            _ => false,
        });
        let fstype = super::detect_fs_type("/tmp/disk.fat16").unwrap();
        assert!(match fstype {
            crate::fs::FsType::Fat16(_, label) => label == "FOOBAR",
            _ => false,
        });
        let fstype = super::detect_fs_type("/tmp/disk.ext4").unwrap();
        assert!(match fstype {
            crate::fs::FsType::Ext4(_, label) => label == "foobar",
            _ => false,
        });

        teardown();
    }
}
