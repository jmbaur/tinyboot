use crate::lexer::Lexer;
use crate::token::Token;
use std::iter::Peekable;

#[derive(thiserror::Error, Debug)]
pub enum ParserError {
    #[error("required next token is missing")]
    MissingNextToken,
    #[error("missing character {0}")]
    MissingCharacter(String),
    #[error("invalid syntax {0}")]
    InvalidSyntax(Token),
    #[error("unexpected token {found:?}, expected {expected:?}")]
    UnexpectedToken { expected: String, found: Token },
    #[error("unexpected value {0}")]
    UnexpectedValue(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AssignmentStatement {
    pub name: String,
    pub value: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Condition(pub bool, pub CommandStatement);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IfStatement {
    pub condition: Condition,
    pub consequence: Vec<Statement>,
    pub elifs: Vec<IfStatement>,
    pub alternative: Vec<Statement>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WhileStatement {
    pub condition: Condition,
    pub consequence: Vec<Statement>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CommandArgument {
    /// A `Value` is one that can have embedded values inside of it, i.e. "${foo}bar" where the value
    /// of `$foo` is embedded inside the string with extra characters. The final value of a value
    /// expression must be obtained by expanding all inner values.
    Value(String),
    /// A `Literal` is one that must be interpreted literally, oppposed to a value expression whose
    /// final value must be expanded. A literal expressions final value is it's initial value.
    Literal(String),
    Block(Vec<Statement>),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandStatement {
    pub command: String,
    pub args: Vec<CommandArgument>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FunctionStatement {
    pub name: String,
    pub body: Vec<Statement>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Statement {
    Assignment(AssignmentStatement),
    Command(CommandStatement),
    Function(FunctionStatement),
    If(IfStatement),
    While(WhileStatement),
}

#[derive(Debug, PartialEq, Eq)]
pub struct Root {
    pub statements: Vec<Statement>,
}

fn matches_command(s: &str) -> bool {
    matches!(
        s,
        "[" | "acpi"
            | "authenticate"
            | "background_color"
            | "background_image"
            | "badram"
            | "blocklist"
            | "boot"
            | "cat"
            | "chainloader"
            | "clear"
            | "cmosclean"
            | "cmosdump"
            | "cmostest"
            | "cmp"
            | "configfile"
            | "cpuid"
            | "crc"
            | "cryptomount"
            | "cutmem"
            | "date"
            | "devicetree"
            | "distrust"
            | "drivemap"
            | "echo"
            | "eval"
            | "export"
            | "false"
            | "gettext"
            | "gptsync"
            | "halt"
            | "hashsum"
            | "help"
            | "initrd"
            | "initrd16"
            | "insmod"
            | "keystatus"
            | "linux"
            | "linux16"
            | "list_env"
            | "list_trusted"
            | "load_env"
            | "loadfont"
            | "loopback"
            | "ls"
            | "lsfonts"
            | "lsmod"
            | "md5sum"
            | "menuentry"
            | "module"
            | "multiboot"
            | "nativedisk"
            | "normal"
            | "normal_exit"
            | "parttool"
            | "password"
            | "password_pbkdf2"
            | "play"
            | "probe"
            | "rdmsr"
            | "read"
            | "reboot"
            | "regexp"
            | "rmmod"
            | "save_env"
            | "search"
            | "sendkey"
            | "serial"
            | "set"
            | "sha1sum"
            | "sha256sum"
            | "sha512sum"
            | "sleep"
            | "smbios"
            | "source"
            | "submenu"
            | "terminal_input"
            | "terminal_output"
            | "terminfo"
            | "test"
            | "true"
            | "trust"
            | "unset"
            | "verify_detached"
            | "videoinfo"
            | "wrmsr"
            | "xen_hypervisor"
            | "xen_module"
    )
}

pub struct Parser<'a> {
    lexer: Peekable<Lexer<'a>>,
}

impl<'a> Parser<'a> {
    pub fn new(l: Lexer<'a>) -> Self {
        Self {
            lexer: l.peekable(),
        }
    }

    fn must_next_token(&mut self) -> Result<Token, ParserError> {
        self.lexer.next().ok_or(ParserError::MissingNextToken)
    }

    fn parse_assignment_statement(
        &mut self,
        value: String,
    ) -> Result<AssignmentStatement, ParserError> {
        let split = value
            .split_once('=')
            .ok_or_else(|| ParserError::MissingCharacter("=".to_string()))?;

        let name = split.0.to_string();
        let value = split.1.to_string();
        let value = if value.is_empty() { None } else { Some(value) };

        Ok(AssignmentStatement { name, value })
    }

    fn parse_scope(&mut self) -> Result<Vec<Statement>, ParserError> {
        let mut body = Vec::new();
        loop {
            let next = self.must_next_token()?;
            if next == Token::CloseBrace {
                break;
            }
            if let Some(stmt) = self.parse_statement(next)? {
                body.push(stmt);
            }
        }

        Ok(body)
    }

    fn parse_command_statement(
        &mut self,
        command: String,
    ) -> Result<CommandStatement, ParserError> {
        let mut args = Vec::new();

        let mut seen_close_bracket = false;
        while let Some(peek_token) = self.lexer.peek() {
            if matches!(peek_token, &Token::Newline | &Token::Semicolon) {
                if command.as_str() == "[" && !seen_close_bracket {
                    return Err(ParserError::MissingCharacter("]".to_string()));
                }
                break;
            }

            let token = self.must_next_token()?;
            match token {
                Token::Value(value) => args.push(CommandArgument::Value(value)),
                Token::Literal(literal) => args.push(CommandArgument::Literal(literal)),
                Token::CloseBracket => {
                    if command.as_str() != "[" {
                        return Err(ParserError::MissingCharacter("[".to_string()));
                    } else {
                        seen_close_bracket = true;
                        continue;
                    }
                }
                Token::OpenBrace => args.push(CommandArgument::Block(self.parse_scope()?)),
                _ => return Err(ParserError::InvalidSyntax(token)),
            };
        }

        let command = if command.as_str() == "[" {
            "test".to_string()
        } else {
            command
        };

        Ok(CommandStatement { command, args })
    }

    fn parse_condition(&mut self) -> Result<Condition, ParserError> {
        let next = self.must_next_token()?;
        let negation = next == Token::Value(String::from("!"));
        let start_condition_token = if negation {
            self.must_next_token()?
        } else {
            next
        };

        let Token::Value(value) = start_condition_token else {
            return Err(ParserError::UnexpectedToken {
                expected: String::from("grub command"),
                found: start_condition_token
            });
        };

        if !matches_command(&value) {
            return Err(ParserError::UnexpectedValue(value));
        }

        Ok(Condition(!negation, self.parse_command_statement(value)?))
    }

    fn parse_if_statement(&mut self) -> Result<IfStatement, ParserError> {
        self.parse_if_statement_if_or_elif()
    }

    fn parse_if_statement_if_or_elif(&mut self) -> Result<IfStatement, ParserError> {
        let condition = self.parse_condition()?;

        let next = self.must_next_token()?;
        if !matches!(next, Token::Newline | Token::Semicolon) {
            return Err(ParserError::UnexpectedToken {
                expected: String::from("newline or semicolon"),
                found: next,
            });
        }

        let next = self.must_next_token()?;
        if next != Token::Then {
            return Err(ParserError::UnexpectedToken {
                found: next,
                expected: String::from("'then'"),
            });
        }

        let mut alternative = Vec::new();
        let mut consequence = Vec::new();
        let mut elifs = Vec::new();

        while let Some(token) = self.lexer.next() {
            match token {
                Token::Elif => elifs.push(self.parse_if_statement_if_or_elif()?),
                Token::Else => {
                    // allow the next token to be a newline or the start of an "else" body.
                    if let Some(Token::Newline) = self.lexer.peek() {
                        _ = self.must_next_token()?;
                    }
                    alternative = self.parse_if_statement_else()?;

                    // `self.parse_if_statement_else()` consumes the last "fi", so we break after
                    // it has run and we don't consume the "fi" in this loop.
                    break;
                }
                Token::Fi => break,
                _ => {
                    if let Some(stmt) = self.parse_statement(token)? {
                        consequence.push(stmt);
                    }
                }
            }
        }

        Ok(IfStatement {
            condition,
            consequence,
            elifs,
            alternative,
        })
    }

    fn parse_if_statement_else(&mut self) -> Result<Vec<Statement>, ParserError> {
        let mut consequence = Vec::new();

        loop {
            let next = self.must_next_token()?;
            match next {
                Token::Fi => break,
                _ => {
                    if let Some(stmt) = self.parse_statement(next)? {
                        consequence.push(stmt);
                    }
                }
            }
        }

        Ok(consequence)
    }

    fn parse_function_statement(&mut self) -> Result<FunctionStatement, ParserError> {
        let next = self.must_next_token()?;
        let Token::Value(name) = next else {
            return Err(ParserError::UnexpectedToken{
                found: next,
                expected: String::from("function name"),
            });
        };

        let next = self.must_next_token()?;
        if next != Token::OpenBrace {
            return Err(ParserError::UnexpectedToken {
                found: next,
                expected: String::from("open brace"),
            });
        }
        let body = self.parse_scope()?;
        Ok(FunctionStatement { name, body })
    }

    /// `is_while` is false when the loop is an until loop, otherwise it is true.
    fn parse_while_statement(&mut self, is_while: bool) -> Result<WhileStatement, ParserError> {
        let mut condition = self.parse_condition()?;

        // Flip the condition's negation status based on what kind of loop we are parsing. For
        // example, a condition with a logical negation inside an until loop (implied negation)
        // will end up cancelling out the double negations, thus becoming just a regular while loop
        // without any negation.
        condition.0 = condition.0 == is_while;

        let mut do_token = self.must_next_token()?;
        if do_token == Token::Semicolon {
            do_token = self.must_next_token()?;
        }

        if do_token != Token::Do {
            return Err(ParserError::UnexpectedToken {
                expected: String::from("'do'"),
                found: do_token,
            });
        }

        let mut consequence = Vec::new();

        loop {
            let next = self.must_next_token()?;
            match next {
                Token::Done => break,
                _ => {
                    if let Some(stmt) = self.parse_statement(next)? {
                        consequence.push(stmt);
                    }
                }
            }
        }

        Ok(WhileStatement {
            condition,
            consequence,
        })
    }

    fn parse_statement(&mut self, start_token: Token) -> Result<Option<Statement>, ParserError> {
        Ok(match start_token {
            Token::Newline | Token::Semicolon | Token::Comment(_) => None,
            Token::If => Some(Statement::If(self.parse_if_statement()?)),
            Token::While => Some(Statement::While(self.parse_while_statement(true)?)),
            Token::Until => Some(Statement::While(self.parse_while_statement(false)?)),
            Token::Function => Some(Statement::Function(self.parse_function_statement()?)),
            Token::Value(value) => {
                if matches_command(&value) || !value.contains('=') {
                    Some(Statement::Command(self.parse_command_statement(value)?))
                } else {
                    Some(Statement::Assignment(
                        self.parse_assignment_statement(value)?,
                    ))
                }
            }
            _ => return Err(ParserError::InvalidSyntax(start_token)),
        })
    }

    pub fn parse(&mut self) -> Result<Root, ParserError> {
        let mut root = Root { statements: vec![] };

        while let Some(token) = self.lexer.next() {
            if let Some(stmt) = self.parse_statement(token)? {
                root.statements.push(stmt);
            }
        }

        Ok(root)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_assignment_statement(
        stmt: &Statement,
        name: impl Into<String>,
        value: Option<impl Into<String>>,
    ) {
        let Statement::Assignment(assignment) = stmt else {
                 panic!("not an assignment statement");
        };
        assert_eq!(assignment.name, name.into());
        assert_eq!(assignment.value, value.map(|s| s.into()));
    }

    fn assert_command_statement(
        stmt: &Statement,
        command: impl Into<String>,
        args: Vec<CommandArgument>,
    ) {
        let Statement::Command(stmt) = stmt else {
            panic!("not a command expression statement");
        };
        assert_eq!(stmt.command, command.into());
        assert_eq!(stmt.args, args);
    }

    fn assert_if_statement(
        stmt: &Statement,
        condition: Condition,
        consequence: Vec<Statement>,
        elifs: Vec<IfStatement>,
        alternative: Vec<Statement>,
    ) {
        let Statement::If(if_stmt) = stmt else {
            panic!("not an if statement");
        };
        assert_eq!(if_stmt.condition, condition);
        assert_eq!(if_stmt.consequence, consequence);
        assert_eq!(if_stmt.elifs, elifs);
        assert_eq!(if_stmt.alternative, alternative);
    }

    fn assert_while_statement(stmt: &Statement, condition: Condition, consequence: Vec<Statement>) {
        let Statement::While(while_stmt) = stmt else {
            panic!("not while statement");
        };
        assert_eq!(while_stmt.condition, condition);
        assert_eq!(while_stmt.consequence, consequence);
    }

    fn assert_function_statement(stmt: &Statement, name: impl Into<String>, body: Vec<Statement>) {
        let Statement::Function(function) = stmt else {
            panic!("not a function statement");
        };
        assert_eq!(function.name, name.into());
        assert_eq!(function.body, body);
    }

    #[test]
    fn assignment_statement() {
        let l = Lexer::new(
            r#"foo=bar
               bar="#,
        );
        let mut p = Parser::new(l);
        let root = p.parse().unwrap();
        assert!(root.statements.len() == 2);
        assert_assignment_statement(&root.statements[0], "foo", Some("bar"));
        assert_assignment_statement(&root.statements[1], "bar", None::<String>);
    }

    #[test]
    fn command_statement() {
        let mut p = Parser::new(Lexer::new(r#"[ "${grub_platform}" = "efi" ]"#));
        let root = p.parse().unwrap();
        assert!(root.statements.len() == 1);
        assert_command_statement(
            &root.statements[0],
            "test",
            vec![
                CommandArgument::Value(String::from("${grub_platform}")),
                CommandArgument::Value(String::from("=")),
                CommandArgument::Value(String::from("efi")),
            ],
        );
    }

    #[test]
    fn multiple_command_statements() {
        let mut p = Parser::new(Lexer::new("load_env; insmod foo 'bar'"));
        let root = p.parse().unwrap();
        assert!(root.statements.len() == 2);
        assert_command_statement(&root.statements[0], "load_env", vec![]);
        assert_command_statement(
            &root.statements[1],
            "insmod",
            vec![
                CommandArgument::Value(String::from("foo")),
                CommandArgument::Literal(String::from("bar")),
            ],
        );
    }

    #[test]
    fn empty_while_statement() {
        {
            let mut p = Parser::new(Lexer::new(r#"while true; do; done"#));
            let root = p.parse().unwrap();
            assert!(root.statements.len() == 1);
            assert_while_statement(
                &root.statements[0],
                Condition(
                    true,
                    CommandStatement {
                        command: "true".to_string(),
                        args: vec![],
                    },
                ),
                vec![],
            );
        }

        {
            let mut p = Parser::new(Lexer::new(r#"until true; do; done"#));
            let root = p.parse().unwrap();
            assert!(root.statements.len() == 1);
            assert_while_statement(
                &root.statements[0],
                Condition(
                    false,
                    CommandStatement {
                        command: "true".to_string(),
                        args: vec![],
                    },
                ),
                vec![],
            );
        }

        {
            let mut p = Parser::new(Lexer::new(r#"until ! true; do; done"#));
            let root = p.parse().unwrap();
            assert!(root.statements.len() == 1);
            assert_while_statement(
                &root.statements[0],
                Condition(
                    true,
                    CommandStatement {
                        command: "true".to_string(),
                        args: vec![],
                    },
                ),
                vec![],
            );
        }
    }

    #[test]
    fn full_if_statement() {
        let mut p = Parser::new(Lexer::new(
            r#"if [ "foo" ]; then; elif test "bar"; then; else; fi"#,
        ));
        let root = p.parse().unwrap();
        assert!(root.statements.len() == 1);
        assert_if_statement(
            &root.statements[0],
            Condition(
                true,
                CommandStatement {
                    command: "test".to_string(),
                    args: vec![CommandArgument::Value(String::from("foo"))],
                },
            ),
            vec![],
            vec![IfStatement {
                condition: Condition(
                    true,
                    CommandStatement {
                        command: "test".to_string(),
                        args: vec![CommandArgument::Value(String::from("bar"))],
                    },
                ),
                consequence: vec![],
                alternative: vec![],
                elifs: vec![],
            }],
            vec![],
        );
    }

    #[test]
    fn function() {
        let src = r#"
            function foobar { load_env; }
            foobar "foo" "bar"
        "#;
        let mut p = Parser::new(Lexer::new(src));
        let root = p.parse().unwrap();
        assert!(root.statements.len() == 2);
        assert_function_statement(
            &root.statements[0],
            "foobar",
            vec![Statement::Command(CommandStatement {
                command: "load_env".to_string(),
                args: vec![],
            })],
        );
        assert_command_statement(
            &root.statements[1],
            "foobar",
            vec![
                CommandArgument::Value(String::from("foo")),
                CommandArgument::Value(String::from("bar")),
            ],
        );
    }

    #[test]
    fn nixos_example() {
        let mut p = Parser::new(Lexer::new(include_str!("./testdata/grub-nixos.cfg")));
        let ast = p.parse().expect("no parsing errors");
        insta::assert_debug_snapshot!(ast);
    }

    #[test]
    fn ubuntu_iso_example() {
        let mut p = Parser::new(Lexer::new(include_str!("./testdata/grub-ubuntu.cfg")));
        let ast = p.parse().expect("no parsing errors");
        insta::assert_debug_snapshot!(ast);
    }

    #[test]
    fn alpine_iso_example() {
        let mut p = Parser::new(Lexer::new(include_str!("./testdata/grub-alpine.cfg")));
        let ast = p.parse().expect("no parsing errors");
        insta::assert_debug_snapshot!(ast);
    }
}
