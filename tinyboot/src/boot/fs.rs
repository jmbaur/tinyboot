use log::error;
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
    Fat(String, String),
}

const FAT32_MAGIC_SIGNATURE_START: u64 = 82; // 82 to 89
const FAT32_LABEL_START: u64 = 71; // 71 to 81
const FAT32_UUID_START: u64 = 67; // 67 to 70

const EXT4_SUPERBLOCK_START: u64 = 1024;
const EXT4_MAGIC_SIGNATURE_START: u64 = EXT4_SUPERBLOCK_START + 0x38;
const EXT4_UUID_START: u64 = EXT4_SUPERBLOCK_START + 0x68;
const EXT4_LABEL_START: u64 = EXT4_SUPERBLOCK_START + 0x78;

pub fn detect_fs_type(p: impl AsRef<Path>) -> anyhow::Result<FsType> {
    let mut f = fs::File::open(p)?;

    // https://www.win.tue.nl/~aeb/linux/fs/fat/fat-1.html
    {
        f.seek(io::SeekFrom::Start(FAT32_MAGIC_SIGNATURE_START))?;
        let mut buffer = [0; 8];
        f.read_exact(&mut buffer)?;
        if let Ok("FAT32   ") = std::str::from_utf8(&buffer) {
            let uuid: String;
            let label: String;
            {
                f.seek(io::SeekFrom::Start(FAT32_UUID_START))?;
                let mut buffer = [0; 4];
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
                f.seek(io::SeekFrom::Start(FAT32_LABEL_START))?;
                let mut buffer = [0; 11];
                f.read_exact(&mut buffer)?;
                label = String::from_utf8(buffer.to_vec())?.trim_end().to_string();
            }
            return Ok(FsType::Fat(uuid, label));
        }
    }

    // https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout
    {
        f.seek(io::SeekFrom::Start(EXT4_MAGIC_SIGNATURE_START))?;
        let mut buffer = [0; 2];
        f.read_exact(&mut buffer)?;
        let comp_buf = &nix::sys::statfs::EXT4_SUPER_MAGIC.0.to_le_bytes()[0..2];
        if buffer == comp_buf {
            let uuid: Uuid;
            {
                f.seek(io::SeekFrom::Start(EXT4_UUID_START))?;
                let mut buffer = [0; 16];
                f.read_exact(&mut buffer)?;
                uuid = Uuid::from_bytes(buffer);
            }
            let label: String;
            {
                f.seek(io::SeekFrom::Start(EXT4_LABEL_START))?;
                let mut buffer = [0; 16];
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
        .into_iter()
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
    #[test]
    #[ignore]
    // TODO(jared): figure out how to run these commands before running tests and cleanup after.
    // TODO(jared): Run these commands for setup:
    // dd bs=512M count=1 if=/dev/zero of=/tmp/disk.fat
    // mkfs.fat -n FOOBAR /tmp/disk.fat
    // dd bs=512M count=1 if=/dev/zero of=/tmp/disk.ext4
    // mkfs.ext4 -L foobar /tmp/disk.ext4
    fn detect_fs_type() {
        let fstype = super::detect_fs_type("/tmp/disk.fat").unwrap();
        eprintln!("{:#?}", fstype);
        let fstype = super::detect_fs_type("/tmp/disk.ext4").unwrap();
        eprintln!("{:#?}", fstype);
    }
}
