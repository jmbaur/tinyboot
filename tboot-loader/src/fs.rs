use std::{
    fs,
    io::{self, Read, Seek},
    path::Path,
};

#[derive(Debug, PartialEq, Eq)]
pub enum FsType {
    Ext4,
    Vfat,
    Iso9660,
}

impl FsType {
    pub fn as_str(&self) -> &str {
        match self {
            FsType::Iso9660 => "iso9660",
            FsType::Ext4 => "ext4",
            FsType::Vfat => "vfat",
        }
    }
}

/// formatted as (start, length)
/// FAT documentation: https://www.win.tue.nl/~aeb/linux/fs/fat/fat-1.html
/// EXT4 documentation: https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout
/// ISO9660 documentation: https://www.loc.gov/preservation/digital/formats/fdd/fdd000348.shtml
mod fs_constants {
    pub const FAT_MAGIC_SIGNATURE_START: u64 = 510;
    pub const FAT_MAGIC_SIGNATURE_LENGTH: usize = 2;

    pub const FAT32_IDENTIFIER_START: u64 = 82;
    pub const FAT32_IDENTIFIER_LENGTH: usize = 8;

    pub const FAT16_IDENTIFIER_START: u64 = 54;
    pub const FAT16_IDENTIFIER_LENGTH: usize = 8;

    pub const EXT4_SUPERBLOCK_START: u64 = 0x400;
    pub const EXT4_MAGIC_SIGNATURE_START: u64 = EXT4_SUPERBLOCK_START + 0x38;
    pub const EXT4_MAGIC_SIGNATURE_LENGTH: usize = 2;

    pub const ISO9660_MAGIC_SIGNATURE_START_1: u64 = 0x8001;
    pub const ISO9660_MAGIC_SIGNATURE_START_2: u64 = 0x8801;
    pub const ISO9660_MAGIC_SIGNATURE_START_3: u64 = 0x9001;
    pub const ISO9660_MAGIC_SIGNATURE_LENGTH: usize = 5;
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
                    return Ok(FsType::Vfat);
                };
            }

            // fat16 detection
            {
                f.seek(io::SeekFrom::Start(fs_constants::FAT16_IDENTIFIER_START))?;
                let mut buffer = [0; fs_constants::FAT16_IDENTIFIER_LENGTH];
                f.read_exact(&mut buffer)?;

                if std::str::from_utf8(&buffer)
                    // fat12 is mostly consistent with fat16 for our uses
                    .map(|res| res == "FAT16   " || res == "FAT12   ")
                    .unwrap_or(false)
                {
                    return Ok(FsType::Vfat);
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
            return Ok(FsType::Ext4);
        }
    }

    // iso9660 detection
    {
        for start in [
            fs_constants::ISO9660_MAGIC_SIGNATURE_START_1,
            fs_constants::ISO9660_MAGIC_SIGNATURE_START_2,
            fs_constants::ISO9660_MAGIC_SIGNATURE_START_3,
        ] {
            f.seek(io::SeekFrom::Start(start))?;
            let mut buffer = [0; fs_constants::ISO9660_MAGIC_SIGNATURE_LENGTH];
            f.read_exact(&mut buffer)?;
            if std::str::from_utf8(&buffer)
                .map(|res| res == "CD001")
                .unwrap_or(false)
            {
                return Ok(FsType::Iso9660);
            }
        }
    }

    anyhow::bail!("unsupported fs type")
}
