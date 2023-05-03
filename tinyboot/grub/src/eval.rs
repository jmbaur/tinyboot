use crate::{
    lexer::Lexer,
    parser::{
        AssignmentStatement, CommandArgument, CommandStatement, FunctionStatement, IfStatement,
        Parser, ParserError, Statement, WhileStatement,
    },
};
use std::{collections::HashMap, io, path::Path, time::Duration};

#[derive(thiserror::Error, Debug)]
pub enum EvalError {
    #[error("not a value")]
    NotValue,
    #[error("missing value")]
    MissingValue,
    #[error("parser error")]
    Parser(ParserError),
    #[error("IO error")]
    Io(io::Error),
    #[error("{0}")]
    Eval(String),
}

fn interpolate_value(env: &impl GrubEnvironment, value: impl Into<String>) -> String {
    let mut final_value = String::new();

    let value = value.into();
    let mut peeker = value.chars().peekable();
    let mut interpolating = false;
    let mut needs_closing_brace = false;
    let mut needs_closing_paren = false;
    let mut interpolated_identifier = String::new();

    loop {
        let next = peeker.next();
        match next {
            Some('(') => {
                if peeker.peek().map(|&c| c == '$').unwrap_or_default() {
                    needs_closing_paren = true;
                } else {
                    needs_closing_paren = false;
                    final_value.push(next.expect("next is not None"));
                }
            }
            Some(')') => {
                if interpolating && needs_closing_paren {
                    interpolating = false;
                    needs_closing_paren = false;
                    let Some(interpolated_value) = env.get_env(&interpolated_identifier) else { continue; };
                    final_value.push_str(interpolated_value);
                }
            }
            Some('$') => {
                interpolating = true;
                if peeker.peek().map(|&c| c == '{').unwrap_or_default() {
                    _ = peeker.next().expect("peek is not None");
                    // look until closing brace
                    needs_closing_brace = true;
                } else {
                    // look until non ascii alphanumeric character
                    needs_closing_brace = false;
                }
            }
            Some('}') => {
                if interpolating && needs_closing_brace {
                    interpolating = false;
                    needs_closing_brace = false;
                    let Some(interpolated_value) = env.get_env(&interpolated_identifier) else { continue; };
                    final_value.push_str(interpolated_value);
                }
            }
            Some(char) => {
                if interpolating {
                    if needs_closing_brace || needs_closing_paren {
                        interpolated_identifier.push(char);
                    } else if
                    // TODO(jared): confirm grub identifiers must be ascii alphanumeric
                    // Stop interpolating if the character is not alphanumeric or is one of the
                    // special characters that cannot be in an identifier.
                    !char.is_ascii_alphanumeric() {
                        interpolating = false;
                        if let Some(interpolated_value) = env.get_env(&interpolated_identifier) {
                            final_value.push_str(interpolated_value);
                            interpolated_identifier.clear();
                        }

                        // Ensure that the consumed character makes it into the final value.
                        final_value.push(char);
                    } else {
                        interpolated_identifier.push(char);
                    }
                } else {
                    final_value.push(char);
                }
            }
            None => {
                if interpolating {
                    if let Some(interpolated_value) = env.get_env(&interpolated_identifier) {
                        final_value.push_str(interpolated_value);
                    }
                }
                break;
            }
        }
    }

    final_value
}

/// GrubEnvironment is the implementation of grub on an actual machine. It interacts with the
/// filesystem and stores state within the evaluation of a Grub configuration file.
pub trait GrubEnvironment {
    /// All grub commands documented at
    /// https://www.gnu.org/software/grub/manual/grub/grub.html#Commands should be implemented
    /// besides menuentry and submenu. The command `[` will be sent as `test` and will not include
    /// the trailing `]` character as an argument.
    fn run_command(&mut self, command: String, args: Vec<String>) -> u8;

    /// Set an environment variable
    fn set_env(&mut self, key: String, val: Option<String>);

    /// Get an enviroment variable (Mostly for being able to expand interpolated values).
    fn get_env(&self, key: &str) -> Option<&String>;
}

/// MenuEntry is a target that can be selected by a user to boot into or expand into more entries
/// (i.e. a submenu).
/// Menuentry docs: https://www.gnu.org/software/grub/manual/grub/html_node/menuentry.html
/// Submenu docs: https://www.gnu.org/software/grub/manual/grub/html_node/submenu.html#submenu
#[derive(Debug, Default, Clone)]
pub struct GrubEntry {
    pub title: String,
    pub id: Option<String>,
    pub class: Option<String>,
    pub users: Option<String>,
    pub unrestricted: Option<bool>,
    pub hotkey: Option<String>,

    /// Only valid for `menuentry` commands. Will be `None` for submenus.
    pub consequence: Option<Vec<Statement>>,
    /// Only valid for `menuentry` commands. Will be `None` for submenus.
    pub extra_args: Option<Vec<String>>,

    /// Only valid for `submenu` commands. Will be `None` for menuentries.
    pub menuentries: Option<Vec<GrubEntry>>,
}

#[derive(Debug)]
pub struct GrubEvaluator<T: GrubEnvironment> {
    env: T,
    functions: HashMap<String, Vec<Statement>>,
    pub last_exit_code: u8,
    pub menu: Vec<GrubEntry>,
}

impl<T> GrubEvaluator<T>
where
    T: GrubEnvironment,
{
    pub fn new(config_file: impl io::Read, env: T) -> Result<Self, EvalError> {
        let source = io::read_to_string(config_file).map_err(EvalError::Io)?;
        Self::new_from_source(source, env)
    }

    pub fn new_from_source(source: String, env: T) -> Result<Self, EvalError> {
        let mut s = Self {
            last_exit_code: 0,
            env,
            functions: HashMap::new(),
            menu: Vec::new(),
        };

        let mut parser = Parser::new(Lexer::new(&source));

        let ast = parser.parse().map_err(EvalError::Parser)?;

        s.eval(ast.statements)?;

        Ok(s)
    }

    pub fn timeout(&self) -> Duration {
        let Some(timeout) = self.env.get_env("timeout") else {
            return Duration::from_secs(10);
        };
        let timeout: u64 = timeout.parse().unwrap_or(10);
        Duration::from_secs(timeout)
    }

    fn interpolate_value(&self, value: String) -> String {
        interpolate_value(&self.env, value)
    }

    fn get_entry(&self, command: &CommandStatement) -> Result<GrubEntry, EvalError> {
        let mut entry = GrubEntry::default();

        let mut args = command.args.iter().peekable();

        let destructure_value = |cmd_arg: Option<&CommandArgument>| -> Result<String, EvalError> {
            let CommandArgument::Value(val) = cmd_arg
                    .ok_or_else(|| EvalError::NotValue)? else {
                        return Err(EvalError::MissingValue);
                    };
            Ok(val.to_string())
        };

        entry.title = self.interpolate_value(destructure_value(args.next())?);

        let mut menuentry_consequence = Vec::new();
        let mut menuentry_extra_args = Vec::new();

        let mut submenu_entries = Vec::new();

        while let Some(arg) = args.next() {
            match arg {
                CommandArgument::Value(value) => {
                    match value.as_str() {
                        "--class" => entry.class = Some(destructure_value(args.next())?),
                        "--users" => entry.users = Some(destructure_value(args.next())?),
                        "--hotkey" => entry.hotkey = Some(destructure_value(args.next())?),
                        "--id" => entry.id = Some(destructure_value(args.next())?),
                        "--unrestricted" => entry.unrestricted = Some(true),
                        _ => {
                            // menuentry can have extra args that are passed to the consequence
                            // commands
                            if command.command == "menuentry" {
                                menuentry_extra_args
                                    .push(self.interpolate_value(value.to_string()));
                            }
                        }
                    }
                }
                CommandArgument::Literal(literal) => {
                    if command.command == "menuentry" {
                        menuentry_extra_args.push(literal.to_string());
                    }
                }
                CommandArgument::Block(block) => match command.command.as_str() {
                    "menuentry" => {
                        menuentry_consequence.extend(block.to_vec());
                    }
                    "submenu" => {
                        let entries = block
                            .iter()
                            .filter_map(|stmt| {
                                let Statement::Command(cmd) = stmt else { return None; };
                                if cmd.command != "menuentry" {
                                    return None;
                                }
                                self.get_entry(cmd).ok()
                            })
                            .collect::<Vec<GrubEntry>>();
                        submenu_entries.extend(entries);
                    }
                    _ => {}
                },
            };
        }

        match command.command.as_str() {
            "menuentry" => {
                entry.consequence = Some(menuentry_consequence);
                entry.extra_args = Some(menuentry_extra_args);
            }
            "submenu" => entry.menuentries = Some(submenu_entries),
            _ => {}
        };

        Ok(entry)
    }

    fn add_entry(&mut self, command: CommandStatement) -> Result<(), EvalError> {
        let entry = self.get_entry(&command)?;
        self.menu.push(entry);
        Ok(())
    }

    fn run_command(&mut self, command: CommandStatement) -> Result<(), EvalError> {
        if let "menuentry" | "submenu" = command.command.as_str() {
            self.add_entry(command)?
        } else {
            let command_name = command.command.as_str();
            let args = command
                .args
                .iter()
                .filter_map(|arg| match arg {
                    // block arguments are only valid when calling `menuentry` or `submenu`.
                    CommandArgument::Block(_) => None,
                    CommandArgument::Literal(literal) => Some(literal.to_string()),
                    CommandArgument::Value(value) => {
                        Some(self.interpolate_value(value.to_string()))
                    }
                })
                .collect::<Vec<String>>();
            let args_len = args.len();

            if let Some(function) = self.functions.get(&command.command) {
                // The arguments to the function need to be valid for the entire duration of the
                // function call.
                let statements = function.to_vec();
                for stmt in statements {
                    // setup command-scoped environment variables
                    {
                        self.env
                            .set_env("#".to_string(), Some(args_len.to_string()));
                        self.env.set_env("*".to_string(), Some(args.join(" ")));
                        self.env.set_env("@".to_string(), Some(args.join(" ")));
                        self.env
                            .set_env(0.to_string(), Some(command_name.to_string()));
                        for (i, arg) in args.iter().enumerate() {
                            self.env.set_env((i + 1).to_string(), Some(arg.to_string()));
                        }
                    }

                    self.eval(vec![stmt])?;
                    // teardown command-scoped environment variables
                    {
                        self.env.set_env("#".to_string(), None);
                        self.env.set_env("*".to_string(), None);
                        self.env.set_env("@".to_string(), None);
                        for i in 0..args_len {
                            self.env.set_env(i.to_string(), None);
                        }
                    }
                }
            } else {
                let exit_code = self.env.run_command(command.command, args);
                self.last_exit_code = exit_code;
                self.env
                    .set_env("?".to_string(), Some(self.last_exit_code.to_string()));
            }
        }

        Ok(())
    }

    fn run_variable_assignment(&mut self, assignment: AssignmentStatement) {
        self.env.set_env(assignment.name, assignment.value);
    }

    fn run_if_statement(&mut self, stmt: IfStatement) -> Result<(), EvalError> {
        self.run_command(stmt.condition.1)?;
        let success = if stmt.condition.0 {
            self.last_exit_code == 0
        } else {
            self.last_exit_code > 0
        };

        if success {
            self.eval(stmt.consequence)?;
        } else {
            // should be empty for elifs
            for if_statement in stmt.elifs {
                self.run_if_statement(if_statement)?;
            }
            // should be empty for elifs
            self.eval(stmt.alternative)?;
        }

        Ok(())
    }

    fn run_while_statement(&mut self, stmt: WhileStatement) -> Result<(), EvalError> {
        loop {
            self.run_command(stmt.condition.1.clone())?;

            if self.last_exit_code == 0 && !stmt.condition.0 {
                break;
            }

            self.eval(stmt.consequence.to_vec())?;
        }

        Ok(())
    }

    fn add_function(&mut self, function: FunctionStatement) -> Result<(), EvalError> {
        _ = self.functions.insert(function.name, function.body);
        Ok(())
    }

    fn eval(&mut self, statements: Vec<Statement>) -> Result<(), EvalError> {
        for stmt in statements {
            match stmt {
                Statement::Assignment(assignment) => self.run_variable_assignment(assignment),
                Statement::Command(command) => self.run_command(command)?,
                Statement::Function(function) => self.add_function(function)?,
                Statement::If(stmt) => self.run_if_statement(stmt)?,
                Statement::While(stmt) => self.run_while_statement(stmt)?,
            };
        }

        Ok(())
    }

    pub fn eval_boot_entry(
        &mut self,
        entry: &GrubEntry,
    ) -> Result<(&Path, &Path, &str), EvalError> {
        let Some(consequence) = &entry.consequence else {
            return Err(EvalError::Eval("not a boot entry".to_string()));
        };
        self.eval(consequence.to_vec())?;
        let linux = self
            .env
            .get_env("linux")
            .ok_or_else(|| EvalError::Eval("no linux found".to_string()))?;
        let initrd = self
            .env
            .get_env("initrd")
            .ok_or_else(|| EvalError::Eval("no initrd found".to_string()))?;
        let cmdline = self
            .env
            .get_env("linux_cmdline")
            .ok_or_else(|| EvalError::Eval("no cmdline found".to_string()))?;
        Ok((Path::new(linux), Path::new(initrd), cmdline.as_str()))
    }

    pub fn get_env(&self, key: &str) -> Option<&String> {
        self.env.get_env(key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Default)]
    struct SimpleGrubEnvironment {
        env: HashMap<String, String>,
    }
    impl GrubEnvironment for SimpleGrubEnvironment {
        fn run_command(&mut self, _name: String, _args: Vec<String>) -> u8 {
            0
        }

        fn set_env(&mut self, key: String, val: Option<String>) {
            if let Some(val) = val {
                self.env.insert(key, val);
            } else {
                self.env.remove(&key);
            }
        }

        fn get_env(&self, _key: &str) -> Option<&String> {
            self.env.get(_key)
        }
    }

    #[test]
    fn interpolate_value() {
        let env = SimpleGrubEnvironment {
            env: HashMap::from([
                ("foo".to_string(), "bar".to_string()),
                ("prefix".to_string(), "/mnt/boot/grub".to_string()),
                ("root".to_string(), "/dev/vda".to_string()),
            ]),
        };

        assert_eq!(super::interpolate_value(&env, "$foo"), "bar".to_string());
        assert_eq!(
            super::interpolate_value(&env, "${prefix}/grubenv"),
            "/mnt/boot/grub/grubenv".to_string()
        );
        assert_eq!(
            super::interpolate_value(
                &env,
                "($root)//kernels/1pzgainlvg5hcdf8ngjficg3x39j63gv-linux-6.0.15-bzImage"
            ),
            "/dev/vda//kernels/1pzgainlvg5hcdf8ngjficg3x39j63gv-linux-6.0.15-bzImage".to_string()
        );
        assert_eq!(super::interpolate_value(&env, "($drive1)"), "".to_string());
    }

    #[test]
    fn full_example() {
        let grub_env = SimpleGrubEnvironment::default();
        GrubEvaluator::new_from_source(include_str!("./testdata/grub.cfg").to_string(), grub_env)
            .expect("no evaluation errors");
    }
}
