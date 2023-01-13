use crate::token::Token;
use std::{iter::Peekable, str::Chars};

const LINE_FEED: char = 0xa as char;

pub struct Lexer<'a> {
    current_char: char,
    src: Peekable<Chars<'a>>,
}

impl<'a> Lexer<'a> {
    pub fn new(input: &'a str) -> Self {
        Self {
            src: input.chars().peekable(),
            current_char: 0 as char,
        }
    }

    fn read_other(&mut self) -> Token {
        let mut other_str = String::from(self.current_char);
        while let Some(&char) = self.src.peek() {
            if char.is_ascii_whitespace() || char == ';' {
                break;
            }

            other_str.push(self.src.next().expect("peek is not None"));
        }

        match other_str.as_str() {
            "case" => Token::Case,
            "do" => Token::Do,
            "done" => Token::Done,
            "elif" => Token::Elif,
            "else" => Token::Else,
            "esac" => Token::Esac,
            "fi" => Token::Fi,
            "for" => Token::For,
            "function" => Token::Function,
            "if" => Token::If,
            "in" => Token::In,
            "select" => Token::Select,
            "then" => Token::Then,
            "time" => Token::Time,
            "until" => Token::Until,
            "while" => Token::While,
            _ => Token::Value(other_str),
        }
    }

    fn read_comment(&mut self) -> Token {
        let mut comment_str = String::new();

        'outer: while let Some(char) = self.src.next() {
            // Determine if this is a multi-line comment.
            'line_feed: {
                if char == LINE_FEED {
                    while let Some(next) = self.src.peek() {
                        // Multi-line comments can have all-whitespace in front of the octothorpes.
                        if next.is_ascii_whitespace() {
                            // Not a multi-line comment since there were two consecutive line feed
                            // characters.
                            if next == &LINE_FEED {
                                break 'outer;
                            }
                            _ = self.src.next().expect("peek is not None");
                            continue;
                        }

                        // Is a multi-line comment, continue building the token value.
                        if next == &'#' {
                            _ = self.src.next().expect("peek is not None");
                            break 'line_feed;
                        }

                        // Not a multi-line comment, finish the comment token.
                        break 'outer;
                    }
                }
            }

            comment_str.push(char);
        }

        Token::Comment(comment_str.trim().to_string())
    }

    fn read_quoted_val(&mut self) -> Token {
        if self.current_char != '"' {
            return Token::Illegal(self.current_char);
        }
        let mut str_val = String::new();
        for char in self.src.by_ref() {
            if char == '"' {
                break;
            }
            str_val.push(char);
        }
        Token::Value(str_val)
    }

    fn read_literal(&mut self) -> Token {
        if self.current_char != '\'' {
            return Token::Illegal(self.current_char);
        }
        let mut str_val = String::new();
        for char in self.src.by_ref() {
            if char == '\'' {
                break;
            }
            str_val.push(char);
        }
        Token::Literal(str_val)
    }
}

impl Iterator for Lexer<'_> {
    type Item = Token;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let Some(char) = self.src.next() else { return None; };
            if char.is_ascii_whitespace() {
                if char == LINE_FEED {
                    return Some(Token::Newline);
                }
                continue;
            }
            self.current_char = char;
            return Some(match self.current_char {
                '"' => self.read_quoted_val(),
                '#' => self.read_comment(),
                '&' => Token::Ampersand,
                ';' => Token::Semicolon,
                '[' => Token::Value(String::from("[")),
                '\'' => self.read_literal(),
                ']' => Token::CloseBracket,
                '{' => Token::OpenBrace,
                '|' => Token::Pipe,
                '}' => Token::CloseBrace,
                _ => self.read_other(),
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokenize(input: &str) -> Result<Vec<Token>, String> {
        let l = Lexer::new(input);

        let mut tokens = Vec::new();
        for token in l {
            tokens.push(token);
        }

        Ok(tokens)
    }

    #[test]
    fn whitespace() {
        assert_eq!(
            tokenize(
                r#"
                "#
            )
            .unwrap(),
            vec![Token::Newline]
        );
    }

    #[test]
    fn expressions() {
        assert_eq!(
            tokenize("string1 == string2").unwrap(),
            vec![
                Token::Value("string1".to_string()),
                Token::Value("==".to_string()),
                Token::Value("string2".to_string())
            ],
        );
        assert_eq!(
            tokenize("integer1 -gt integer2").unwrap(),
            vec![
                Token::Value("integer1".to_string()),
                Token::Value("-gt".to_string()),
                Token::Value("integer2".to_string()),
            ]
        );
    }

    #[test]
    fn set_command() {
        assert_eq!(
            tokenize("set foo=bar").unwrap(),
            vec![
                Token::Value("set".to_string()),
                Token::Value("foo=bar".to_string()),
            ]
        );
    }

    #[test]
    fn simple_expression() {
        assert_eq!(
            tokenize(
                r#"if [ $default -ne 0 ]; then
                     set default=0
                   fi"#
            )
            .unwrap(),
            vec![
                Token::If,
                Token::Value("[".to_string()),
                Token::Value("$default".to_string()),
                Token::Value("-ne".to_string()),
                Token::Value("0".to_string()),
                Token::CloseBracket,
                Token::Semicolon,
                Token::Then,
                Token::Newline,
                Token::Value("set".to_string()),
                Token::Value("default=0".to_string()),
                Token::Newline,
                Token::Fi,
            ]
        );
    }

    #[test]
    fn menuentry() {
        assert_eq!(
            tokenize("menuentry { linux /path/to/linux; }").unwrap(),
            vec![
                Token::Value("menuentry".to_string()),
                Token::OpenBrace,
                Token::Value("linux".to_string()),
                Token::Value("/path/to/linux".to_string()),
                Token::Semicolon,
                Token::CloseBrace,
            ]
        );
    }

    #[test]
    fn comment() {
        assert_eq!(
            tokenize("foo # bar").unwrap(),
            vec![
                Token::Value("foo".to_string()),
                Token::Comment("bar".to_string()),
            ]
        );

        assert_eq!(
            tokenize(
                r#"# foo
                   # bar

                   # baz"#
            )
            .unwrap(),
            vec![
                Token::Comment("foo\n bar".to_string()),
                Token::Newline,
                Token::Comment("baz".to_string()),
            ]
        );
    }

    #[test]
    fn device_syntax() {
        assert_eq!(
            tokenize("(hd0,1)").unwrap(),
            vec![Token::Value("(hd0,1)".to_string()),]
        );
    }

    #[test]
    fn full_example() {
        let tokens = tokenize(include_str!("../testdata/grub.cfg")).unwrap();
        assert!(!tokens.iter().any(|tok| matches!(tok, Token::Illegal(_))));
    }
}
