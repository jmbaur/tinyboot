#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();

    let prog = args
        .first()
        .map(std::path::Path::new)
        .and_then(|p| p.file_name())
        .and_then(std::ffi::OsStr::to_str);

    match prog {
        Some("tbootd") => tbootd::run(args).await,
        Some("tbootctl") => tbootctl::run(args).await,
        Some("tbootui") => tbootui::run(args).await,
        _ => Err(anyhow::anyhow!(
            "program must be tbootd, tbootctl, or tbootui"
        )),
    }
}
