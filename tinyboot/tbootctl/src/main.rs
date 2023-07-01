extern crate tbootctl;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tbootctl::run(std::env::args().collect()).await
}
