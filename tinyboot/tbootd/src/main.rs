extern crate tbootd;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tbootd::run(std::env::args().collect()).await
}
