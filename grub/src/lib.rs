use std::io;

pub(crate) mod eval;
pub(crate) mod lexer;
pub(crate) mod parser;
pub(crate) mod token;

pub use eval::{CommandReturn, ExitCode, Grub, GrubEnvironment};

pub fn evaluate_config(
    mut config: impl io::Read,
    commands: impl eval::Grub,
) -> Result<(), String> {
    let mut input = String::new();
    _ = config
        .read_to_string(&mut input)
        .map_err(|err| err.to_string())?;
    let mut parser = parser::Parser::new(lexer::Lexer::new(&input));
    let ast = parser.parse()?;
    let mut evaluator = eval::GrubEvaluator::new(commands);
    evaluator.eval(ast)
}
