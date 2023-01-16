use crate::{
    lexer::Lexer,
    parser::{
        AssignmentStatement, CommandArgument, CommandStatement, FunctionStatement, IfStatement,
        Parser, Statement,
    },
};
use std::{collections::HashMap, io, path::Path, time::Duration};

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
    pub fn new(config_file: impl io::Read, env: T) -> Result<Self, String> {
        let source = io::read_to_string(config_file).map_err(|e| e.to_string())?;
        Self::new_from_source(source, env)
    }

    pub fn new_from_source(source: String, env: T) -> Result<Self, String> {
        let mut s = Self {
            last_exit_code: 0,
            env,
            functions: HashMap::new(),
            menu: Vec::new(),
        };

        let mut parser = Parser::new(Lexer::new(&source));
        let ast = parser.parse()?;
        s.eval_statements(ast.statements)?;

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
        let mut final_value = String::new();

        let mut peeker = value.chars().peekable();
        let mut interpolating = false;
        let mut needs_closing_brace = false;
        let mut interpolated_identifier = String::new();
        while let Some(char) = peeker.next() {
            match char {
                '$' => {
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
                '}' => {
                    if interpolating && needs_closing_brace {
                        interpolating = false;
                        needs_closing_brace = false;
                        let Some(interpolated_value) = self.env.get_env(&interpolated_identifier) else { continue; };
                        final_value.push_str(interpolated_value);
                    }
                }
                _ => {
                    if interpolating {
                        if needs_closing_brace {
                            interpolated_identifier.push(char);
                        } else if
                        // Stop interpolating if the character is not alphanumeric or is one of the
                        // special characters that cannot be in an identifier.
                        // TODO(jared): The `matches!()` args are just ones that work with
                        // ../testdata/grub.cfg. Fill in further when more examples are discovered.
                        matches!(char, '/') || !char.is_ascii_alphanumeric() {
                            interpolating = false;
                            let Some(interpolated_value) = self.env.get_env(&interpolated_identifier) else { continue; };
                            final_value.push_str(interpolated_value);
                        }
                    } else {
                        final_value.push(char);
                    }
                }
            }
        }

        final_value
    }

    fn get_entry(&self, command: &CommandStatement) -> Result<GrubEntry, String> {
        let mut entry = GrubEntry::default();

        let mut args = command.args.iter().peekable();

        let destructure_value = |cmd_arg: Option<&CommandArgument>| -> Result<String, String> {
            let CommandArgument::Value(val) = cmd_arg
                    .ok_or_else(|| "command argument is None".to_string())? else {
                        return Err("not a CommandArgument::Value".to_string());
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

    fn add_entry(&mut self, command: CommandStatement) -> Result<(), String> {
        self.menu.push(self.get_entry(&command)?);
        Ok(())
    }

    fn run_command(&mut self, command: CommandStatement) -> Result<(), String> {
        match command.command.as_str() {
            "menuentry" | "submenu" => self.add_entry(command)?,
            _ => {
                let args = command
                    .args
                    .iter()
                    .filter_map(|arg| match arg {
                        CommandArgument::Value(value) => {
                            Some(self.interpolate_value(value.to_string()))
                        }
                        CommandArgument::Literal(literal) => Some(literal.to_string()),
                        CommandArgument::Block(_) => {
                            // TODO(jared): blocks are invalid here, return an error?
                            None
                        }
                    })
                    .collect();

                let exit_code = self.env.run_command(command.command, args);

                self.last_exit_code = exit_code;
            }
        }

        Ok(())
    }

    fn run_variable_assignment(&mut self, assignment: AssignmentStatement) {
        self.env.set_env(assignment.name, assignment.value);
    }

    fn run_if_statement(&mut self, stmt: IfStatement) -> Result<(), String> {
        self.run_command(stmt.condition)?;
        let success = if stmt.not {
            self.last_exit_code > 0
        } else {
            self.last_exit_code == 0
        };

        if success {
            self.eval_statements(stmt.consequence)?;
        } else {
            // should be empty for elifs
            for if_statement in stmt.elifs {
                self.run_if_statement(if_statement)?;
            }
            // should be empty for elifs
            self.eval_statements(stmt.alternative)?;
        }

        Ok(())
    }

    fn add_function(&mut self, function: FunctionStatement) -> Result<(), String> {
        _ = self.functions.insert(function.name, function.body);
        Ok(())
    }

    fn eval_statements(&mut self, statements: Vec<Statement>) -> Result<(), String> {
        for stmt in statements {
            match stmt {
                Statement::Assignment(assignment) => self.run_variable_assignment(assignment),
                Statement::Command(command) => self.run_command(command)?,
                Statement::Function(function) => self.add_function(function)?,
                Statement::If(stmt) => self.run_if_statement(stmt)?,
                Statement::While(_) => todo!(),
            };
        }

        Ok(())
    }

    pub fn eval_boot_entry(
        &mut self,
        entry: &GrubEntry,
    ) -> Result<(&Path, &Path, &str, Option<&Path>), String> {
        let Some(consequence) = &entry.consequence else {
            return Err("not a boot entry".to_string());
        };
        self.eval_statements(consequence.to_vec())?;
        let linux = self
            .env
            .get_env("linux")
            .ok_or_else(|| "no linux found".to_string())?;
        let initrd = self
            .env
            .get_env("initrd")
            .ok_or_else(|| "no initrd found".to_string())?;
        let cmdline = self
            .env
            .get_env("cmdline")
            .ok_or_else(|| "no cmdline found".to_string())?;
        Ok((Path::new(linux), Path::new(initrd), cmdline.as_str(), None))
    }

    pub fn get_env(&self, key: &str) -> Option<&String> {
        self.env.get_env(key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct SimpleGrubEnvironment;
    impl GrubEnvironment for SimpleGrubEnvironment {
        fn run_command(&mut self, _name: String, _args: Vec<String>) -> u8 {
            0
        }

        fn set_env(&mut self, _key: String, _val: Option<String>) {}

        fn get_env(&self, _key: &str) -> Option<&String> {
            None
        }
    }

    #[test]
    fn full_example() {
        let grub_env = SimpleGrubEnvironment {};
        GrubEvaluator::new_from_source(include_str!("../testdata/grub.cfg").to_string(), grub_env)
            .expect("no evaluation errors");
    }
}
