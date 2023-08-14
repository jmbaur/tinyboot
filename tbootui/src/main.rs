extern crate tbootui;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tbootui::run(std::env::args().collect()).await
}
