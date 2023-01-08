pub(crate) mod eval;
pub(crate) mod lexer;
pub(crate) mod parser;

pub mod token;

use std::io;

pub fn parse_config(mut config: impl io::Read) -> Result<parser::Root, String> {
    let mut input = String::new();
    _ = config
        .read_to_string(&mut input)
        .map_err(|e| e.to_string())?;

    parser::Parser::new(lexer::Lexer::new(&input)).parse()
}
