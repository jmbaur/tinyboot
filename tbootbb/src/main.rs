#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args: Vec<String> = std::env::args().collect();

    loop {
        let prog = args
            .first()
            .map(std::path::Path::new)
            .and_then(|p| p.file_name())
            .and_then(std::ffi::OsStr::to_str);

        match prog {
            Some("tbootbb") => {
                args = args[1..].to_vec();
                continue;
            }
            Some("tbootd") => tbootd::run(args).await?,
            Some("tbootui") => tbootui::run(args).await?,
            _ => {
                return Err(anyhow::anyhow!(
                    "program must be tbootbb, tbootd, or tbootui"
                ))
            }
        };

        return Ok(());
    }
}
