use std::io;

pub fn setup_logging(level: log::LevelFilter) -> Result<(), log::SetLoggerError> {
    fern::Dispatch::new()
        .format(|out, message, record| {
            out.finish(format_args!(
                "[{}][{}] {}",
                record.target(),
                record.level(),
                message
            ))
        })
        .level(level)
        .chain(io::stderr())
        .apply()
}
