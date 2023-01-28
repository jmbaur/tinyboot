use std::fmt::Display;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Token {
    Ampersand,
    Case,
    CloseBrace,
    CloseBracket,
    Comment(String),
    Do,
    Done,
    Elif,
    Else,
    Esac,
    Fi,
    For,
    Function,
    If,
    Illegal(char),
    In,
    Literal(String),
    Newline,
    OpenBrace,
    Pipe,
    Select,
    Semicolon,
    Then,
    Time,
    Until,
    Value(String),
    While,
}

impl Display for Token {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
