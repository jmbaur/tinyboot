pub struct Logger {
    pub level: log::LevelFilter,
}

impl Logger {
    pub fn new(level: log::LevelFilter) -> Self {
        Self { level }
    }

    pub fn setup(self) -> Result<(), log::SetLoggerError> {
        let logger = Box::leak(Box::new(self));
        log::set_max_level(logger.level);
        log::set_logger(logger)
    }
}

impl log::Log for Logger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        self.level >= metadata.level()
    }

    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            if let Some(module) = record.module_path() {
                if module.starts_with("tboot") {
                    eprintln!("[{}][{}] {}", record.level(), module, record.args());
                }
            }
        }
    }

    fn flush(&self) {}
}
