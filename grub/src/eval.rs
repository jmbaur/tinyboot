use crate::parser::{
    AssignmentStatement, CommandArgument, CommandStatement, FunctionStatement, IfStatement,
    Statement,
};
use std::collections::HashMap;

pub trait GrubEnvironment {
    fn run_command(&mut self, command: String, args: Vec<String>) -> u8;

    fn add_entry(&mut self, menu_name: &str, entry: MenuEntry) -> Result<(), String>;

    /// Set an environment variable
    fn set_env(&mut self, key: String, val: Option<String>);

    /// Get an enviroment variable (Mostly for being able to expand interpolated values).
    fn get_env(&self, key: &str) -> Option<&String>;
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
    pub title: String,
    pub consequence: MenuType,
    pub id: Option<String>,
    pub class: Option<String>,
    pub users: Option<String>,
    pub unrestricted: Option<bool>,
    pub hotkey: Option<String>,
}

pub struct GrubEvaluation<'a, T: GrubEnvironment> {
    evaluator: &'a mut T,
    last_exit_code: u8,
    functions: HashMap<String, Vec<Statement>>,
}

impl<'a, T> GrubEvaluation<'a, T>
where
    T: GrubEnvironment,
{
    pub fn new(evaluator: &'a mut T) -> Self {
        GrubEvaluation {
            evaluator,
            last_exit_code: 0,
            functions: HashMap::new(),
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
                        let Some(interpolated_value) = self.evaluator.get_env(&interpolated_identifier) else { continue; };
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
                            let Some(interpolated_value) = self.evaluator.get_env(&interpolated_identifier) else { continue; };
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
        self.evaluator
            .add_entry(submenu_name.unwrap_or("default"), entry)
    }

    fn run_command(&mut self, command: CommandStatement) -> Result<(), String> {
        match command.command.as_str() {
            "menuentry" | "submenu" => self.add_menuentry(command, None)?,
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

                let exit_code = self.evaluator.run_command(command.command, args);

                self.last_exit_code = exit_code;
            }
        }

        Ok(())
    }

    fn run_variable_assignment(&mut self, assignment: AssignmentStatement) {
        self.evaluator.set_env(assignment.name, assignment.value);
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

    pub fn eval_statements(&mut self, statements: Vec<Statement>) -> Result<(), String> {
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{lexer::Lexer, parser::Parser};

    struct SimpleGrubCommands;
    impl GrubEnvironment for SimpleGrubCommands {
        fn run_command(&mut self, _name: String, _args: Vec<String>) -> u8 {
            0
        }

        fn set_env(&mut self, _key: String, _val: Option<String>) {}

        fn get_env(&self, _key: &str) -> Option<&String> {
            None
        }

        fn add_entry(&mut self, _menu_name: &str, _entry: MenuEntry) -> Result<(), String> {
            Ok(())
        }
    }

    #[test]
    fn full_example() {
        let mut parser = Parser::new(Lexer::new(include_str!("../testdata/grub.cfg")));
        let ast = parser.parse().unwrap();
        let mut evaluator = SimpleGrubCommands {};
        let mut evaluation = GrubEvaluation::new(&mut evaluator);
        evaluation
            .eval_statements(ast.statements)
            .expect("no evaluation errors");
    }
}
