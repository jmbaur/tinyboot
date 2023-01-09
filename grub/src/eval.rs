use std::collections::HashMap;

use crate::parser::{
    self, AssignmentStatement, CommandArgument, CommandStatement, FunctionStatement, IfStatement,
    Statement,
};

pub type GrubEnvironment = HashMap<String, String>;

pub type ExitCode = u8;

pub type CommandReturn = (GrubEnvironment, ExitCode);

pub trait GrubCommands {
    fn run(&self, command: String, args: Vec<String>, env: GrubEnvironment) -> CommandReturn;
}

#[derive(Debug)]
struct GrubScopedEnvironment {
    /// The child scopes of the current scope.
    scopes: HashMap<String, GrubEnvironment>,
    /// The mapping of a scope to its parent scope.
    relationships: HashMap<String, Option<String>>,
}

impl Default for GrubScopedEnvironment {
    fn default() -> Self {
        let mut scopes = HashMap::new();
        scopes.insert("root".to_string(), HashMap::new());
        let mut relationships = HashMap::new();
        relationships.insert("root".to_string(), None);

        Self {
            scopes,
            relationships,
        }
    }
}

impl GrubScopedEnvironment {
    pub fn add_scope(&mut self, scope: impl Into<String>, parent: String) -> Result<(), String> {
        let scope = scope.into();
        if self.scopes.contains_key(&scope) && self.relationships.contains_key(&scope) {
            return Err("scope already exists".to_string());
        }
        _ = self.scopes.insert(scope.clone(), HashMap::new());
        _ = self.relationships.insert(scope, Some(parent));
        Ok(())
    }

    /// Gets the grub environment for a given scope. The magic scope name "root" obtains the
    /// top-level grub environment.
    pub fn get_environment(&self, scope: impl Into<String>) -> Result<GrubEnvironment, String> {
        let scope = scope.into();
        let mut entire_env = HashMap::new();
        let scope_env = self
            .scopes
            .get(&scope)
            .ok_or_else(|| "scope not found".to_string())?;

        entire_env.extend(scope_env.to_owned());

        let mut current = &scope;
        loop {
            match self.relationships.get(current) {
                Some(Some(parent)) => {
                    let Some(scope) = self.scopes.get(parent) else {
                        return Err("scope not found".to_string());
                    };
                    entire_env.extend(scope.to_owned());
                    current = parent;
                }
                Some(None) => break,
                None => return Err("scope not found".to_string()),
            }
        }

        Ok(entire_env)
    }

    /// Returns the same value as HashMap's `insert()` method.
    pub fn set_environment(
        &mut self,
        scope: impl Into<String>,
        key: impl Into<String>,
        val: Option<impl Into<String>>,
    ) -> Option<String> {
        if let Some(env) = self.scopes.get_mut(&scope.into()) {
            if let Some(val) = val {
                env.insert(key.into(), val.into())
            } else {
                env.remove(&key.into())
            }
        } else {
            None
        }
    }

    /// Returns the same value as HashMap's `insert()` method.
    pub fn overwrite_environment(
        &mut self,
        scope: impl Into<String>,
        env: GrubEnvironment,
    ) -> Option<GrubEnvironment> {
        self.scopes.insert(scope.into(), env)
    }
}

pub struct GrubEvaluator<T> {
    commands: T,
    current_scope: String,
    last_exit_code: u8,
    environment: GrubScopedEnvironment,
    functions: HashMap<String, Vec<Statement>>,
}

impl<T> GrubEvaluator<T>
where
    T: GrubCommands,
{
    pub fn new(commands: T) -> Self {
        GrubEvaluator {
            commands,
            current_scope: "root".to_string(),
            last_exit_code: 0,
            environment: GrubScopedEnvironment::default(),
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
                        let Ok(env) = self.environment.get_environment(self.current_scope.clone()) else {
                            continue;
                        };
                        let Some(interpolated_value) = env
                            .get(&interpolated_identifier)
                            else { continue; };
                        final_value.push_str(interpolated_value);
                    }
                }
                _ => {
                    if interpolating {
                        interpolated_identifier.push(char);
                    } else {
                        final_value.push(char);
                    }
                }
            }
        }

        final_value
    }

    fn run_command(&mut self, command: CommandStatement) -> Result<(), String> {
        let env = self
            .environment
            .get_environment(self.current_scope.clone())?;

        let args = /*vec![]*/
            command.args.iter().map(|arg| match arg {
                CommandArgument::Value(value) => self.interpolate_value(value.to_string()),
                CommandArgument::Literal(literal) => literal.to_string(),
                CommandArgument::Scope(_scope) => todo!()
            }).collect();

        let (new_env, exit_code) = self.commands.run(command.command, args, env);

        self.environment
            .overwrite_environment(self.current_scope.clone(), new_env);

        self.last_exit_code = exit_code;

        Ok(())
    }

    fn run_variable_assignment(&mut self, assignment: AssignmentStatement) {
        self.environment.set_environment(
            self.current_scope.clone(),
            assignment.name,
            assignment.value,
        );
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
        self.environment
            .add_scope(function.name.clone(), self.current_scope.clone())?;
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

    #[test]
    fn test_grub_scoped_environment() {
        let mut env = GrubScopedEnvironment::default();

        // set variables are reflected correctly
        _ = env.set_environment("root", "hello", Some("world".to_string()));
        assert_eq!(
            env.get_environment("root").unwrap(),
            HashMap::from([("hello".to_string(), "world".to_string())])
        );

        // singly-nested scope is correctly retrieved
        env.add_scope("foo", "root".to_string()).unwrap();
        _ = env.set_environment("foo", "foohello".to_string(), Some("fooworld".to_string()));
        assert_eq!(
            env.get_environment("foo").unwrap(),
            HashMap::from([
                ("hello".to_string(), "world".to_string()),
                ("foohello".to_string(), "fooworld".to_string())
            ])
        );

        // overwriting the environment is reflected correctly
        _ = env.overwrite_environment(
            "foo",
            HashMap::from([("bar".to_string(), "baz".to_string())]),
        );
        assert_eq!(
            env.get_environment("foo").unwrap(),
            HashMap::from([
                ("hello".to_string(), "world".to_string()),
                ("bar".to_string(), "baz".to_string())
            ])
        );

        // doubly-nested scope is correctly retrieved
        env.add_scope("bar", "foo".to_string()).unwrap();
        assert_eq!(
            env.get_environment("bar").unwrap(),
            HashMap::from([
                ("hello".to_string(), "world".to_string()),
                ("bar".to_string(), "baz".to_string())
            ]),
        );

        // unset variables are reflected correctly
        _ = env.set_environment("foo", "bar".to_string(), None::<String>);
        assert_eq!(
            env.get_environment("foo").unwrap(),
            HashMap::from([("hello".to_string(), "world".to_string()),])
        );
    }

    struct NoopGrubCommands;
    impl GrubCommands for NoopGrubCommands {
        fn run(&self, _name: String, _args: Vec<String>, env: GrubEnvironment) -> CommandReturn {
            (env, 0)
        }
    }

    #[test]
    fn test_full_example() {
        let mut parser = Parser::new(Lexer::new(include_str!("../testdata/grub.cfg")));
        let ast = parser.parse().unwrap();
        let mut evaluator = GrubEvaluator::new(NoopGrubCommands {});
        evaluator.eval(ast).expect("no evaluation errors");
    }
}
