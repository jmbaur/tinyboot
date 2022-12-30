use crate::booter::{BootParts, Booter, Error};
use std::path::{Path, PathBuf};

pub struct Syslinux {
    path: PathBuf,
}

impl Syslinux {
    pub fn new(mount_point: &Path) -> Result<Syslinux, Error> {
        for path in [
            "/boot/extlinux/extlinux.conf",
            "/extlinux/extlinux.conf",
            "/extlinux.conf",
            "/boot/syslinux/extlinux.conf",
            "/boot/syslinux/syslinux.cfg",
            "/syslinux/extlinux.conf",
            "/syslinux/syslinux.cfg",
            "/syslinux.cfg",
        ] {
            let search_path = mount_point.join(path);
            if std::fs::metadata(&search_path).is_ok() {
                return Ok(Syslinux { path: search_path });
            }
        }
        Err(Error::NotFound)
    }
}

impl Booter for Syslinux {
    fn get_parts(&self) -> Result<Vec<BootParts>, Error> {
        let Ok(contents) = std::fs::read_to_string(&self.path) else {
            return Err(Error::Unknown);
        };

        let mut parts = vec![];
        let mut p = BootParts::default();
        let mut default = String::new();
        let mut in_entry: Option<bool> = None;

        for line in contents.lines() {
            if !in_entry.unwrap_or_default() && line.starts_with("DEFAULT") {
                default = String::from(line.split_once("DEFAULT ").expect("bad syslinux format").1);
                continue;
            }

            if line.starts_with("LABEL") {
                // We have already seen at least one entry, push the previous one into boot parts
                // and start a new one.
                if in_entry.is_some() {
                    parts.push(p);
                    p = BootParts::default();
                }

                if default == line.split_once("LABEL ").expect("bad syslinux format").1 {
                    p.default = true;
                }

                in_entry = Some(true);
                continue;
            }
            if !in_entry.unwrap_or_default() {
                continue;
            }
            if line
                .trim_start_matches(char::is_whitespace)
                .starts_with("MENU LABEL")
            {
                p.name = String::from(
                    line.split_once("MENU LABEL ")
                        .expect("bad syslinux format")
                        .1,
                );
                continue;
            }

            if line
                .trim_start_matches(char::is_whitespace)
                .starts_with("LINUX")
            {
                p.kernel = self.path.parent().unwrap().join(PathBuf::from(
                    line.split_once("LINUX ").expect("bad syslinux format").1,
                ));
                continue;
            }

            if line
                .trim_start_matches(char::is_whitespace)
                .starts_with("INITRD")
            {
                p.initrd = self.path.parent().unwrap().join(PathBuf::from(
                    line.split_once("INITRD ").expect("bad syslinux format").1,
                ));
                continue;
            }

            if line
                .trim_start_matches(char::is_whitespace)
                .starts_with("APPEND")
            {
                p.cmdline =
                    String::from(line.split_once("APPEND ").expect("bad syslinux format").1);
                continue;
            }

            if line
                .trim_start_matches(char::is_whitespace)
                .starts_with("FDT")
            {
                p.dtb = Some(self.path.parent().unwrap().join(PathBuf::from(
                    line.split_once("FDT ").expect("bad syslinux format").1,
                )));
                continue;
            }

            if line.trim().is_empty() {
                in_entry = Some(false);
            }
        }

        // Include the last entry in boot parts.
        parts.push(p);

        Ok(parts)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_syslinux_get_parts() {
        let parts = (Syslinux {
            path: PathBuf::from("testdata/extlinux.conf"),
        })
        .get_parts()
        .unwrap();
        assert_eq!(parts.len(), 6);
        assert_eq!(parts[0].name, "NixOS - Default");
    }
}
