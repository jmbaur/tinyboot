use crate::lexer::Lexer;
use crate::token::Token;
use std::iter::Peekable;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AssignmentStatement {
    pub name: String,
    pub value: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IfStatement {
    pub not: bool,
    pub condition: CommandStatement,
    pub consequence: Vec<Statement>,
    pub elifs: Vec<IfStatement>,
    pub alternative: Vec<Statement>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WhileStatement {
    /// Make the boolean expression evaluate to false in order for the `consequence` to execute.
    pub until: bool,
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
    #[allow(dead_code)]
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

    fn must_next_token(&mut self) -> Result<Token, String> {
        self.lexer
            .next()
            .ok_or_else(|| "next token is None".to_string())
    }

    /// Consume newline or semicolon if the peeked token is one of those.
    #[allow(dead_code)]
    fn eat_end(&mut self) -> Result<(), String> {
        if matches!(
            self.lexer.peek(),
            Some(Token::Newline) | Some(Token::Semicolon)
        ) {
            _ = self.must_next_token()?;
        }
        Ok(())
    }

    fn parse_assignment_statement(&mut self, value: String) -> Result<AssignmentStatement, String> {
        let split = value
            .split_once('=')
            .ok_or_else(|| "missing equals in assignment statement".to_string())?;

        let name = split.0.to_string();
        let value = split.1.to_string();
        let value = if value.is_empty() { None } else { Some(value) };

        Ok(AssignmentStatement { name, value })
    }

    fn parse_scope(&mut self) -> Result<Vec<Statement>, String> {
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

    fn parse_command_statement(&mut self, command: String) -> Result<CommandStatement, String> {
        let mut args = Vec::new();

        let mut seen_close_bracket = false;
        while let Some(peek_token) = self.lexer.peek() {
            if matches!(peek_token, &Token::Newline | &Token::Semicolon) {
                if command.as_str() == "[" && !seen_close_bracket {
                    return Err(
                        "opening bracket does not have matching closing bracket".to_string()
                    );
                }
                break;
            }

            let token = self.must_next_token()?;
            match token {
                Token::Value(value) => args.push(CommandArgument::Value(value)),
                Token::Literal(literal) => args.push(CommandArgument::Literal(literal)),
                Token::CloseBracket => {
                    if command.as_str() != "[" {
                        return Err(
                            "closing bracket does not have matching opening bracket".to_string()
                        );
                    } else {
                        seen_close_bracket = true;
                        continue;
                    }
                }
                Token::OpenBrace => args.push(CommandArgument::Block(self.parse_scope()?)),
                _ => return Err(format!("invalid syntax: {:?}", token)),
            };
        }

        let command = if command.as_str() == "[" {
            "test".to_string()
        } else {
            command
        };

        Ok(CommandStatement { command, args })
    }

    fn parse_if_statement(&mut self) -> Result<IfStatement, String> {
        self.parse_if_statement_if_or_elif()
    }

    fn parse_if_statement_if_or_elif(&mut self) -> Result<IfStatement, String> {
        let (not, condition) = {
            let next = self.must_next_token()?;
            let not = next == Token::ExclamationPoint;
            let start_condition_token = if not { self.must_next_token()? } else { next };
            let Token::Value(value) = start_condition_token else {
                return Err("if statement missing value token as start of condition".to_string());
            };
            if !matches_command(&value) {
                return Err("if statement condition must be a command statement".to_string());
            }
            (not, self.parse_command_statement(value)?)
        };

        let next = self.must_next_token()?;
        if !matches!(next, Token::Newline | Token::Semicolon) {
            return Err("missing end of condition (newline or semicolon)".to_string());
        }

        let next = self.must_next_token()?;
        if next != Token::Then {
            return Err("missing then in if statement".to_string());
        }

        let mut alternative = Vec::new();
        let mut consequence = Vec::new();
        let mut elifs = Vec::new();

        while let Some(token) = self.lexer.next() {
            match token {
                Token::Elif => elifs.push(self.parse_if_statement_if_or_elif()?),
                Token::Else => alternative = self.parse_if_statement_else()?,
                Token::Fi => break,
                _ => {
                    if let Some(stmt) = self.parse_statement(token)? {
                        consequence.push(stmt);
                    }
                }
            }
        }

        Ok(IfStatement {
            not,
            condition,
            consequence,
            elifs,
            alternative,
        })
    }

    fn parse_if_statement_else(&mut self) -> Result<Vec<Statement>, String> {
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

    fn parse_function_statement(&mut self) -> Result<FunctionStatement, String> {
        let Token::Value(name) = self.must_next_token()? else {
            return Err("function does not have a name".to_string());
        };
        if self.must_next_token()? != Token::OpenBrace {
            return Err("function does not have opening brace".to_string());
        }
        let body = self.parse_scope()?;
        Ok(FunctionStatement { name, body })
    }

    fn parse_statement(&mut self, start_token: Token) -> Result<Option<Statement>, String> {
        Ok(match start_token {
            Token::Newline | Token::Semicolon | Token::Comment(_) => None,
            Token::If => Some(Statement::If(self.parse_if_statement()?)),
            Token::While | Token::Until => todo!(),
            Token::Function => Some(Statement::Function(self.parse_function_statement()?)),
            Token::Value(value) => {
                if matches_command(&value) {
                    Some(Statement::Command(self.parse_command_statement(value)?))
                } else {
                    Some(Statement::Assignment(
                        self.parse_assignment_statement(value)?,
                    ))
                }
            }
            _ => return Err(format!("invalid syntax: {:?}", start_token)),
        })
    }

    pub fn parse(&mut self) -> Result<Root, String> {
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
        not: bool,
        condition: CommandStatement,
        consequence: Vec<Statement>,
        elifs: Vec<IfStatement>,
        alternative: Vec<Statement>,
    ) {
        let Statement::If(if_stmt) = stmt else {
            panic!("not an if statement");
        };
        assert_eq!(if_stmt.not, not);
        assert_eq!(if_stmt.condition, condition);
        assert_eq!(if_stmt.consequence, consequence);
        assert_eq!(if_stmt.elifs, elifs);
        assert_eq!(if_stmt.alternative, alternative);
    }

    fn assert_function_statement(stmt: &Statement, name: impl Into<String>, body: Vec<Statement>) {
        let Statement::Function(function) = stmt else {
            panic!("not a function statement");
        };
        assert_eq!(function.name, name.into());
        assert_eq!(function.body, body);
    }

    #[test]
    fn test_assignment_statement() {
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
    fn test_command_statement() {
        let mut p = Parser::new(Lexer::new(r#"[ "${grub_platform}" = "efi" ]"#));
        let root = p.parse().unwrap();
        assert!(root.statements.len() == 1);
        assert_command_statement(
            &root.statements[0],
            "test",
            vec![
                CommandArgument::Value("${grub_platform}".to_string()),
                CommandArgument::Value("=".to_string()),
                CommandArgument::Value("efi".to_string()),
            ],
        );
    }

    #[test]
    fn test_multiple_command_statements() {
        let mut p = Parser::new(Lexer::new("load_env; insmod foo 'bar'"));
        let root = p.parse().unwrap();
        assert!(root.statements.len() == 2);
        assert_command_statement(&root.statements[0], "load_env", vec![]);
        assert_command_statement(
            &root.statements[1],
            "insmod",
            vec![
                CommandArgument::Value("foo".to_string()),
                CommandArgument::Literal("bar".to_string()),
            ],
        );
    }

    #[test]
    fn test_full_if_statement() {
        let mut p = Parser::new(Lexer::new(
            r#"if [ "foo" ]; then; elif test "bar"; then; else; fi"#,
        ));
        let root = p.parse().unwrap();
        assert!(root.statements.len() == 1);
        assert_if_statement(
            &root.statements[0],
            false,
            CommandStatement {
                command: "test".to_string(),
                args: vec![CommandArgument::Value("foo".to_string())],
            },
            vec![],
            vec![IfStatement {
                not: false,
                condition: CommandStatement {
                    command: "test".to_string(),
                    args: vec![CommandArgument::Value("bar".to_string())],
                },
                consequence: vec![],
                alternative: vec![],
                elifs: vec![],
            }],
            vec![],
        );
    }

    #[test]
    fn test_function() {
        // TODO(jared): implement function calls
        let src = r#"
            function foobar { load_env; }
            # foobar "foo" "bar"
        "#;
        let mut p = Parser::new(Lexer::new(src));
        let root = p.parse().unwrap();
        assert!(root.statements.len() == 1);
        assert_function_statement(
            &root.statements[0],
            "foobar",
            vec![Statement::Command(CommandStatement {
                command: "load_env".to_string(),
                args: vec![],
            })],
        );
    }

    #[test]
    fn test_full_example() {
        let mut p = Parser::new(Lexer::new(include_str!("../testdata/grub.cfg")));
        p.parse().expect("no parsing errors");
    }
}
