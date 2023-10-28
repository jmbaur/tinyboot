fn nologin() {
    println!("This account is currently not available.");
    std::process::exit(1);
}

/// Act as an /sbin/nologin program if the program name is "nologin".
pub fn detect_nologin() {
    match std::env::args()
        .next()
        .as_deref()
        .map(|arg0| arg0.split(std::path::MAIN_SEPARATOR_STR).last())
    {
        Some(Some("nologin")) => nologin(),
        _ => {}
    }
}
