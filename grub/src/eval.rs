use std::collections::HashMap;

use crate::parser::{
    self, AssignmentStatement, CommandArgument, CommandStatement, FunctionStatement, IfStatement,
    Statement,
};

pub type GrubEnvironment = HashMap<String, Option<String>>;

pub type ExitCode = u8;

pub type CommandReturn = (GrubEnvironment, ExitCode);

pub trait Grub {
    fn run_command(
        &self,
        command: String,
        args: Vec<String>,
        env: GrubEnvironment,
    ) -> CommandReturn;

    /// Selects a single entry to boot into from a map of menu/submenu names to the list of entries
    /// in that menu. The special menu name "default" in the `menus` HashMap is the top-level menu.
    /// All other entries in the HashMap are submenus.
    fn select_menuentry(&self, menus: HashMap<String, Vec<MenuEntry>>) -> MenuEntry;
}

#[derive(Debug, PartialEq, Eq)]
pub enum MenuType {
    /// Menuentry contains statements to execute along with arguments to those statements.
    Menuentry((Vec<Statement>, Vec<String>)),
    Submenu(Vec<MenuEntry>),
}

impl Default for MenuType {
    fn default() -> Self {
        Self::Submenu(Vec::new())
    }
}

/// MenuEntry is a target that can be selected by a user to boot into or expand into more entries
/// (i.e. a submenu).
/// Menuentry docs: https://www.gnu.org/software/grub/manual/grub/html_node/menuentry.html
/// Submenu docs: https://www.gnu.org/software/grub/manual/grub/html_node/submenu.html#submenu
#[derive(Debug, PartialEq, Eq, Default)]
pub struct MenuEntry {
    title: String,
    consequence: MenuType,
    id: Option<String>,
    class: Option<String>,
    users: Option<String>,
    unrestricted: Option<bool>,
    hotkey: Option<String>,
}

pub struct GrubEvaluator<T> {
    commands: T,
    last_exit_code: u8,
    environment: GrubEnvironment,
    functions: HashMap<String, Vec<Statement>>,
    menus: HashMap<String, Vec<MenuEntry>>,
}

impl<T> GrubEvaluator<T>
where
    T: Grub,
{
    pub fn new(commands: T) -> Self {
        GrubEvaluator {
            commands,
            last_exit_code: 0,
            environment: HashMap::new(),
            functions: HashMap::new(),
            menus: HashMap::new(),
        }
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
                        let Some(Some(interpolated_value)) = self.environment
                            .get(&interpolated_identifier)
                            else { continue; };
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
                            let Some(Some(interpolated_value)) = self.environment
                                .get(&interpolated_identifier)
                                else { continue; };
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

    fn get_menuentry(&self, menuentry: &CommandStatement) -> Result<MenuEntry, String> {
        let mut entry = MenuEntry::default();

        let CommandArgument::Value(title) = menuentry
                .args
                .get(0)
                .ok_or_else(|| "menuentry title not present".to_string())? else {
                    return Err("menuentry title is not a CommandArgument::Value".to_string());
                };
        entry.title = self.interpolate_value(title.to_string());

        // only valid with menuentry
        let mut menuentry_consequence = (Vec::new(), Vec::new());
        let mut submenu_consequence = Vec::new();
        for arg in &menuentry.args[1..] {
            match arg {
                CommandArgument::Value(value) => {
                    match value.split_once('=') {
                        Some(("--class", class)) => entry.class = Some(class.to_string()),
                        Some(("--users", users)) => entry.users = Some(users.to_string()),
                        Some(("--hotkey", hotkey)) => entry.hotkey = Some(hotkey.to_string()),
                        Some(("--id", id)) => entry.id = Some(id.to_string()),
                        _ => {
                            if value.as_str() == "--unrestricted" {
                                entry.unrestricted = Some(true);
                            } else if menuentry.command.as_str() == "menuentry" {
                                menuentry_consequence
                                    .1
                                    .push(self.interpolate_value(value.to_string()));
                            }
                        }
                    };
                    if menuentry.command.as_str() == "menuentry" {
                        menuentry_consequence
                            .1
                            .push(self.interpolate_value(value.to_string()));
                    }
                }
                CommandArgument::Literal(literal) => {
                    if menuentry.command.as_str() == "menuentry" {
                        menuentry_consequence.1.push(literal.to_string());
                    }
                }
                CommandArgument::Block(block) => {
                    if menuentry.command.as_str() == "menuentry" {
                        menuentry_consequence.0.extend(block.to_vec());
                    } else if menuentry.command.as_str() == "submenu" {
                        let entries = block
                            .iter()
                            .filter_map(|stmt| {
                                let Statement::Command(cmd) = stmt else { return None; };
                                if cmd.command != "menuentry" {
                                    return None;
                                }
                                self.get_menuentry(cmd).ok()
                            })
                            .collect::<Vec<MenuEntry>>();
                        submenu_consequence.extend(entries);
                    }
                }
            };
        }

        if menuentry.command.as_str() == "menuentry" {
            entry.consequence = MenuType::Menuentry(menuentry_consequence);
        } else if menuentry.command.as_str() == "submenu" {
            entry.consequence = MenuType::Submenu(submenu_consequence);
        }

        Ok(entry)
    }

    fn add_menuentry(
        &mut self,
        menuentry: CommandStatement,
        submenu_name: Option<&str>,
    ) -> Result<(), String> {
        let entry = self.get_menuentry(&menuentry)?;

        let submenu_name = submenu_name.unwrap_or("default");
        if !self.menus.contains_key(submenu_name) {
            self.menus.insert(submenu_name.to_string(), vec![]);
        }

        let menu = self
            .menus
            .get_mut(submenu_name)
            .ok_or_else(|| "menu does not exist".to_string())?;

        menu.push(entry);
        Ok(())
    }

    fn run_command(&mut self, command: CommandStatement) -> Result<(), String> {
        match command.command.as_str() {
            "menuentry" => self.add_menuentry(command, None)?,
            "submenu" => self.add_menuentry(command, None)?,
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

                let (new_env, exit_code) =
                    self.commands
                        .run_command(command.command, args, self.environment.clone());

                self.environment = new_env;

                self.last_exit_code = exit_code;
            }
        }

        Ok(())
    }

    fn run_variable_assignment(&mut self, assignment: AssignmentStatement) {
        self.environment.insert(assignment.name, assignment.value);
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

    pub fn eval(&mut self, ast: parser::Root) -> Result<(), String> {
        self.eval_statements(ast.statements)
    }
}

#[cfg(test)]
mod tests {
    use crate::{lexer::Lexer, parser::Parser};

    use super::*;

    struct SimpleGrubCommands;
    impl Grub for SimpleGrubCommands {
        fn run_command(
            &self,
            _name: String,
            _args: Vec<String>,
            env: GrubEnvironment,
        ) -> CommandReturn {
            (env, 0)
        }

        fn select_menuentry(&self, _menus: HashMap<String, Vec<MenuEntry>>) -> MenuEntry {
            todo!()
        }
    }

    #[test]
    fn test_full_example() {
        let mut parser = Parser::new(Lexer::new(include_str!("../testdata/grub.cfg")));
        let ast = parser.parse().unwrap();
        let mut evaluator = GrubEvaluator::new(SimpleGrubCommands {});
        evaluator.eval(ast).expect("no evaluation errors");
    }
}
