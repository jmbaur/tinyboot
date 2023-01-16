use super::boot_loader::MenuEntry;
use crate::boot::boot_loader::{BootLoader, Error};
use crate::boot::util::*;
use grub::{GrubEnvironment, GrubEvaluator};
use log::debug;
use std::io::Read;
use std::path::PathBuf;
use std::{collections::HashMap, fs, path::Path};

struct TinybootGrubEnvironment {
    env: HashMap<String, String>,
}

impl TinybootGrubEnvironment {
    pub fn new(prefix: impl Into<String>) -> Self {
        Self {
            env: HashMap::from([
                ("prefix".to_string(), prefix.into()),
                ("grub_platform".to_string(), "tinyboot".to_string()),
            ]),
        }
    }

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
                "--skip-sig" => todo!("implement --skip-sig"),
                _ => whitelisted_vars.push(next.to_string()),
            };
        }

        let Some(prefix) = self.env.get("prefix") else { return 1; };
        let prefix = PathBuf::from(prefix);
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
        let mut vars_to_save = Vec::new();
        let Some(next) = args.next() else { return 1; };
        if next == "--file" {
            let Some(next) = args.next() else { return 1; };
            _file = next;
        } else {
            vars_to_save.push(next);
        }

        for next in args {
            vars_to_save.push(next);
        }

        if vars_to_save.is_empty() {
            return 0;
        }

        // TODO(jared): must implement grub environment block:
        // https://www.gnu.org/software/grub/manual/grub/html_node/Environment-block.html#Environment-block
        todo!("implement grub environment block")
    }

    fn run_search(&mut self, _args: Vec<String>) -> u8 {
        todo!("implement search grub command")
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
}

pub struct GrubBootLoader {
    mountpoint: PathBuf,
    evaluator: GrubEvaluator<TinybootGrubEnvironment>,
}

impl GrubBootLoader {
    pub fn new(mountpoint: &Path) -> Result<Self, Error> {
        let evaluator = GrubEvaluator::new(
            fs::File::open(mountpoint.join("boot/grub/grub.cfg"))?,
            TinybootGrubEnvironment::new(mountpoint.to_str().ok_or(Error::InvalidMountpoint)?),
        )
        .map_err(Error::Evaluation)?;

        Ok(Self {
            mountpoint: mountpoint.to_path_buf(),
            evaluator,
        })
    }
}

impl BootLoader for GrubBootLoader {
    fn timeout(&self) -> std::time::Duration {
        self.evaluator.timeout()
    }

    fn mountpoint(&self) -> &Path {
        &self.mountpoint
    }

    fn menu_entries(&self) -> Result<Vec<MenuEntry>, Error> {
        Ok(self
            .evaluator
            .menu
            .iter()
            .filter_map(|entry| {
                // is boot entry
                if entry.consequence.is_some() {
                    Some(MenuEntry::BootEntry((
                        entry.id.as_deref().unwrap_or(entry.title.as_str()),
                        entry.title.as_str(),
                    )))
                }
                // is submenu entry
                else {
                    Some(MenuEntry::SubMenu((
                        entry.id.as_deref().unwrap_or(entry.title.as_str()),
                        entry
                            .menuentries
                            .as_ref()?
                            .iter()
                            .filter_map(|entry| {
                                // ensure this is a boot entry, not a nested submenu (invalid?)
                                entry.consequence.as_ref()?;
                                Some(MenuEntry::BootEntry((
                                    entry.id.as_deref().unwrap_or(entry.title.as_str()),
                                    entry.title.as_str(),
                                )))
                            })
                            .collect(),
                    )))
                }
            })
            .collect())
    }

    /// The entry ID could be the ID or name of a boot entry, submenu, or boot entry nested within
    /// a submenu.
    fn boot_info(
        &mut self,
        entry_id: Option<String>,
    ) -> Result<(&Path, &Path, &str, Option<&Path>), Error> {
        let entries = &self.evaluator.menu.to_vec();
        let boot_entry = ('entry: {
            if let Some(entry_id) = entry_id {
                for entry in entries {
                    if entry.consequence.is_some() {
                        if entry.id.as_deref().unwrap_or(entry.title.as_str()) == entry_id {
                            break 'entry Some(entry);
                        }
                    } else if let Some(subentries) = &entry.menuentries {
                        for subentry in subentries {
                            if entry.consequence.is_some()
                                && entry.id.as_deref().unwrap_or(entry.title.as_str()) == entry_id
                            {
                                break 'entry Some(subentry);
                            }
                        }
                    }
                }

                break 'entry None;
            } else {
                todo!("find default boot entry")
            }
        })
        .ok_or(Error::BootEntryNotFound)?;
        self.evaluator
            .eval_boot_entry(boot_entry)
            .map_err(Error::Evaluation)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grub_run_test() {
        let g = TinybootGrubEnvironment::new("/dev/null");
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
