use crate::boot::boot_loader::{BootLoader, Error};
use crate::boot::util::*;
use grub::{GrubEnvironment, MenuEntry};
use log::{debug, info, warn};
use std::io::Read;
use std::path::PathBuf;
use std::time::Duration;
use std::{collections::HashMap, fs, path::Path};

#[derive(Default)]
struct TinybootGrubEnvironment {
    env: HashMap<String, String>,
    menu: HashMap<String, Vec<MenuEntry>>,
}

impl TinybootGrubEnvironment {
    // TODO(jared): the docs mention being able to load multiple initrds, but what is the use case
    // for that?
    // https://www.gnu.org/software/grub/manual/grub/html_node/initrd.html#initrd
    fn run_initrd(&mut self, args: Vec<String>) -> u8 {
        let mut args = args.iter();
        let Some(initrd) = args.next() else { return 1; };
        self.env.insert("initrd".to_string(), initrd.to_string());
        0
    }

    fn run_linux(&mut self, args: Vec<String>) -> u8 {
        let mut args = args.iter();
        let Some(kernel) = args.next() else { return 1; };
        let mut cmdline = String::new();
        for next in args {
            cmdline.push_str(next);
            cmdline.push(' ');
        }
        self.env.insert("linux".to_string(), kernel.to_string());
        self.env.insert("linux_cmdline".to_string(), cmdline);
        0
    }

    fn run_load_env(&mut self, args: Vec<String>) -> u8 {
        let mut file = "grubenv";
        let mut args = args.iter();
        let mut whitelisted_vars = Vec::new();
        while let Some(next) = args.next() {
            match next.as_str() {
                "--file" => {
                    let Some(next) = args.next() else { return 1; };
                    file = next;
                }
                "--skip-sig" => todo!(),
                _ => whitelisted_vars.push(next.to_string()),
            };
        }

        // TODO(jared): fill out grub config file prefix
        let prefix = PathBuf::from("TODO_prefix");
        let Ok(mut file) = fs::File::open(prefix.join(file)) else { return 1; };
        let mut contents = String::new();
        if file.read_to_string(&mut contents).is_err() {
            return 1;
        };

        let loaded_env = contents.lines().filter(|line| !line.starts_with('#')).fold(
            HashMap::new(),
            |mut acc, curr| {
                if let Some(split) = curr.split_once('=') {
                    if !whitelisted_vars.is_empty() && whitelisted_vars.iter().any(|a| a == split.0)
                    {
                        acc.insert(split.0.to_string(), split.1.to_string());
                    }
                }
                acc
            },
        );

        self.env = loaded_env;
        0
    }

    fn run_save_env(&self, args: Vec<String>) -> u8 {
        let mut _file = "grubenv";
        let mut args = args.iter();
        let mut _vars_to_save = Vec::new();
        let Some(next) = args.next() else { return 1; };
        if next == "--file" {
            let Some(next) = args.next() else { return 1; };
            _file = next;
        } else {
            _vars_to_save.push(next);
        }

        for next in args {
            _vars_to_save.push(next);
        }

        if _vars_to_save.is_empty() {
            return 0;
        }

        // TODO(jared): must implement grub environment block:
        // https://www.gnu.org/software/grub/manual/grub/html_node/Environment-block.html#Environment-block
        todo!()
    }

    fn run_search(&self, _args: Vec<String>) -> u8 {
        todo!()
    }

    fn run_set(&mut self, args: Vec<String>) -> u8 {
        match args.len() {
            0 | 1 => 2,
            2 => match (args[0].as_str(), args[1].as_str()) {
                (key, "=") => {
                    self.env.remove(key);
                    0
                }
                _ => 2,
            },
            3 => match (args[0].as_str(), args[1].as_str(), args[2].as_str()) {
                (key, "=", val) => {
                    self.env.insert(key.to_string(), val.to_string());
                    0
                }
                _ => 2,
            },
            _ => 2,
        }
    }

    /// Returns exit code 0 if the test evaluates to true.
    /// Returns exit code 1 if the test evaluates to false.
    /// Returns exit code 2 if the arguments are invalid.
    fn run_test(&self, args: Vec<String>) -> u8 {
        match args.len() {
            0 => 2,
            1 => string_nonzero_length(&args[0]),
            2 => match (args[0].as_str(), args[1].as_str()) {
                // file exists and is a directory
                ("-d", file) => file_exists_and_is_directory(file),
                // file exists
                ("-e", file) => file_exists(file),
                // file exists and is not a directory
                ("-f", file) => file_exists_and_is_not_directory(file),
                // file exists and has a size greater than zero
                ("-s", file) => file_exists_and_size_greater_than_zero(file),
                // the length of string is nonzero
                ("-n", string) => string_nonzero_length(string),
                // the length of string is zero
                ("-z", string) => string_zero_length(string),
                // expression is false
                ("!", _expression) => todo!(),
                _ => 2,
            },
            3 => match (args[0].as_str(), args[1].as_str(), args[2].as_str()) {
                // the strings are equal
                (string1, "=", string2) => strings_equal(string1, string2),
                // the strings are equal
                (string1, "==", string2) => strings_equal(string1, string2),
                // the strings are not equal
                (string1, "!=", string2) => strings_not_equal(string1, string2),
                // string1 is lexicographically less than string2
                (string1, "<", string2) => strings_lexographically_less_than(string1, string2),
                // string1 is lexicographically less or equal than string2
                (string1, "<=", string2) => {
                    strings_lexographically_less_than_or_equal_to(string1, string2)
                }
                // string1 is lexicographically greater than string2
                (string1, ">", string2) => strings_lexographically_greater_than(string1, string2),
                // string1 is lexicographically greater or equal than string2
                (string1, ">=", string2) => {
                    strings_lexographically_greater_than_or_equal_to(string1, string2)
                }
                // integer1 is equal to integer2
                (integer1, "-eq", integer2) => integers_equal(integer1, integer2),
                // integer1 is greater than or equal to integer2
                (integer1, "-ge", integer2) => {
                    integers_greater_than_or_equal_to(integer1, integer2)
                }
                // integer1 is greater than integer2
                (integer1, "-gt", integer2) => integers_greater_than(integer1, integer2),
                // integer1 is less than or equal to integer2
                (integer1, "-le", integer2) => integers_less_than_or_equal_to(integer1, integer2),
                // integer1 is less than integer2
                (integer1, "-lt", integer2) => integers_less_than(integer1, integer2),
                // integer1 is not equal to integer2
                (integer1, "-ne", integer2) => integers_not_equal(integer1, integer2),
                // integer1 is greater than integer2 after stripping off common non-numeric prefix.
                (prefixinteger1, "-pgt", prefixinteger2) => {
                    integers_prefix_greater_than(prefixinteger1, prefixinteger2)
                }
                // integer1 is less than integer2 after stripping off common non-numeric prefix.
                (prefixinteger1, "-plt", prefixinteger2) => {
                    integers_prefix_less_than(prefixinteger1, prefixinteger2)
                }
                // file1 is newer than file2 (modification time). Optionally numeric bias may be directly appended to -nt in which case it is added to the first file modification time.
                (file1, "-nt", file2) => file_newer_than(file1, file2),
                // file1 is older than file2 (modification time). Optionally numeric bias may be directly appended to -ot in which case it is added to the first file modification time.
                (file1, "-ot", file2) => file_older_than(file1, file2),
                // both expression1 and expression2 are true
                (_expression1, "-a", _expression2) => todo!(),
                // either expression1 or expression2 is true
                (_expression1, "-o", _expression2) => todo!(),
                // expression is true
                ("(", _expression, ")") => todo!(),
                _ => 2,
            },
            _ => 2,
        }
    }
}

impl GrubEnvironment for TinybootGrubEnvironment {
    fn run_command(&mut self, command: String, args: Vec<String>) -> u8 {
        match command.as_str() {
            "initrd" => self.run_initrd(args),
            "linux" => self.run_linux(args),
            "load_env" => self.run_load_env(args),
            "save_env" => self.run_save_env(args),
            "search" => self.run_search(args),
            "set" => self.run_set(args),
            "test" => self.run_test(args),
            _ => {
                debug!("'{}' not implemented", command);
                0
            }
        }
    }

    fn set_env(&mut self, key: String, val: Option<String>) {
        if let Some(val) = val {
            self.env.insert(key, val);
        } else {
            self.env.remove(&key);
        }
    }

    fn get_env(&self, _key: &str) -> Option<&String> {
        self.env.get(_key)
    }

    fn add_entry(&mut self, menu_name: &str, entry: MenuEntry) -> Result<(), String> {
        if !self.menu.contains_key(menu_name) {
            self.menu.insert(menu_name.to_string(), Vec::new());
        }
        let entries = self
            .menu
            .get_mut(menu_name)
            .ok_or_else(|| "submenu does not exist".to_string())?;
        entries.push(entry);
        Ok(())
    }
}

pub struct GrubBootLoader {
    mountpoint: PathBuf,
    evaluator: TinybootGrubEnvironment,
}

impl GrubBootLoader {
    pub fn new(mountpoint: &Path) -> Result<Self, Error> {
        let search_path = mountpoint.join("boot/grub/grub.cfg");

        if let Err(e) = fs::metadata(&search_path) {
            warn!("{}: {}", search_path.display(), e)
        } else {
            info!("found grub configuration at {}", search_path.display());
            return Ok(Self {
                mountpoint: mountpoint.to_path_buf(),
                evaluator: TinybootGrubEnvironment::default(),
            });
        }

        Err(Error::BootConfigNotFound)
    }
}

impl BootLoader for GrubBootLoader {
    fn timeout(&self) -> std::time::Duration {
        let Some(timeout) = self.evaluator.get_env("timeout") else {
            return Duration::from_secs(10);
        };
        let timeout: u64 = timeout.parse().unwrap_or(10);
        Duration::from_secs(timeout)
    }

    fn mountpoint(&self) -> &Path {
        &self.mountpoint
    }

    fn menu_entries(&self) -> Result<Vec<crate::boot::boot_loader::MenuEntry>, Error> {
        let mut entries = Vec::new();
        for (menu_name, menu_entries) in &self.evaluator.menu {
            entries.extend(menu_entries.iter().map(|entry| {
                if menu_name == "default" {
                    crate::boot::boot_loader::MenuEntry::BootEntry((
                        entry.id.as_deref().unwrap_or(entry.title.as_str()),
                        &entry.title,
                    ))
                } else {
                    crate::boot::boot_loader::MenuEntry::SubMenu((
                        entry.id.as_deref().unwrap_or(entry.title.as_str()),
                        menu_entries
                            .iter()
                            .map(|entry| {
                                crate::boot::boot_loader::MenuEntry::BootEntry((
                                    entry.id.as_deref().unwrap_or(entry.title.as_str()),
                                    &entry.title,
                                ))
                            })
                            .collect(),
                    ))
                }
            }));
        }
        Ok(entries)
    }

    /// The entry ID could be the ID or name of a boot entry, submenu, or boot entry nested within
    /// a submenu.
    fn boot_info(
        &self,
        entry_id: Option<&str>,
    ) -> Result<(&Path, &Path, &str, Option<&Path>), Error> {
        let _entry_to_boot: &MenuEntry = 'entry: {
            if let Some(entry_id) = entry_id {
                for entries in self.evaluator.menu.values() {
                    for entry in entries {
                        if entry.id.as_ref().unwrap_or(&entry.title) == entry_id {
                            break 'entry entry;
                        }
                    }
                }
                return Err(Error::BootEntryNotFound);
            } else {
                let entry_idx: usize = entry_id
                    .unwrap_or_else(|| {
                        self.evaluator
                            .get_env("default")
                            .map(|s| s.as_str())
                            .unwrap_or("0")
                    })
                    .parse()
                    .unwrap_or_default();

                let entries: Vec<&MenuEntry> = self.evaluator.menu.values().flatten().collect();
                entries.get(entry_idx).ok_or(Error::BootEntryNotFound)?
            }
        };

        // TODO(jared): run statements to get linux, initrd, and cmdline values
        // let MenuType::Menuentry((_statements, _todo)) = entry_to_boot.consequence else {
        //     return Err(Error::BootEntryNotFound);
        // };
        todo!()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grub_run_test() {
        let g = TinybootGrubEnvironment::default();
        assert_eq!(g.run_test(vec!["-d".to_string(), "/dev".to_string()]), 0);
        assert_eq!(g.run_test(vec!["-f".to_string(), "/dev".to_string()]), 1);
        assert_eq!(g.run_test(vec!["-e".to_string(), "/dev".to_string()]), 0);
        assert_eq!(g.run_test(vec!["-n".to_string(), "foo".to_string()]), 0);
        assert_eq!(g.run_test(vec!["-z".to_string(), "foo".to_string()]), 1);
        assert_eq!(g.run_test(vec!["-z".to_string(), "".to_string()]), 0);
        assert_eq!(
            g.run_test(vec![
                "foo1".to_string(),
                "-pgt".to_string(),
                "bar0".to_string()
            ]),
            0
        );
    }
}
