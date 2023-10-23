use std::{collections::HashMap, str::FromStr};

use log::LevelFilter;

#[derive(Debug)]
pub struct Config<'a> {
    pub log_level: LevelFilter,
    pub tty: &'a str,
    pub programmer: &'a str,
}

impl std::fmt::Display for Config<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "log level: {}, tty: {}, programmer: {}",
            self.log_level, self.tty, self.programmer
        )
    }
}

impl Default for Config<'_> {
    fn default() -> Self {
        Self {
            log_level: LevelFilter::Info,
            tty: "tty1",
            programmer: "internal",
        }
    }
}

impl<'a> Config<'a> {
    pub fn from_args(args: &'a [String]) -> Self {
        let mut map = args
            .iter()
            .filter_map(|arg| {
                arg.strip_prefix("tboot.")
                    .and_then(|arg| arg.split_once('='))
            })
            .fold(
                HashMap::new(),
                |mut map: HashMap<&str, Vec<&str>>, (k, v)| {
                    if let Some(existing) = map.get_mut(k) {
                        existing.push(v);
                    } else {
                        _ = map.insert(k, vec![v]);
                    }

                    map
                },
            );

        let mut cfg = Config::default();
        if let Some(log_level) = map.remove("loglevel").and_then(|level| {
            level
                .into_iter()
                .next()
                .and_then(|level| LevelFilter::from_str(level).ok())
        }) {
            cfg.log_level = log_level;
        }

        if let Some(tty) = map.remove("tty") {
            if let Some(tty) = tty.first() {
                cfg.tty = tty;
            }
        }

        if let Some(programmer) = map.remove("programmer") {
            if let Some(programmer) = programmer.first() {
                cfg.programmer = programmer;
            }
        }

        cfg
    }
}
