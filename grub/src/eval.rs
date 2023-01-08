use std::collections::HashMap;

use crate::parser::{
    self, AssignmentStatement, CommandStatement, FunctionStatement, IfStatement, Statement,
};

pub type GrubEnvironment = HashMap<String, String>;

pub type ExitCode = u8;

pub type CommandReturn = (GrubEnvironment, ExitCode);

pub trait GrubCommands {
    /// Load ACPI tables
    fn acpi(&self, env: GrubEnvironment) -> CommandReturn;
    /// Check whether user is in user list
    fn authenticate(&self, env: GrubEnvironment) -> CommandReturn;
    /// Set background color for active terminal
    fn background_color(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load background image for active terminal
    fn background_image(&self, env: GrubEnvironment) -> CommandReturn;
    /// Filter out bad regions of RAM
    fn badram(&self, env: GrubEnvironment) -> CommandReturn;
    /// Print a block list
    fn blocklist(&self, env: GrubEnvironment) -> CommandReturn;
    /// Start up your operating system
    fn boot(&self, env: GrubEnvironment) -> CommandReturn;
    /// Show the contents of a file
    fn cat(&self, env: GrubEnvironment) -> CommandReturn;
    /// Chain-load another boot loader
    fn chainloader(&self, env: GrubEnvironment) -> CommandReturn;
    /// Clear the screen
    fn clear(&self, env: GrubEnvironment) -> CommandReturn;
    /// Clear bit in CMOS
    fn cmosclean(&self, env: GrubEnvironment) -> CommandReturn;
    /// Dump CMOS contents
    fn cmosdump(&self, env: GrubEnvironment) -> CommandReturn;
    /// Test bit in CMOS
    fn cmostest(&self, env: GrubEnvironment) -> CommandReturn;
    /// Compare two files
    fn cmp(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load a configuration file
    fn configfile(&self, env: GrubEnvironment) -> CommandReturn;
    /// Check for CPU features
    fn cpuid(&self, env: GrubEnvironment) -> CommandReturn;
    /// Compute or check CRC32 checksums
    fn crc(&self, env: GrubEnvironment) -> CommandReturn;
    /// Mount a crypto device
    fn cryptomount(&self, env: GrubEnvironment) -> CommandReturn;
    /// Remove memory regions
    fn cutmem(&self, env: GrubEnvironment) -> CommandReturn;
    /// Display or set current date and time
    fn date(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load a device tree blob
    fn devicetree(&self, env: GrubEnvironment) -> CommandReturn;
    /// Remove a pubkey from trusted keys
    fn distrust(&self, env: GrubEnvironment) -> CommandReturn;
    /// Map a drive to another
    fn drivemap(&self, env: GrubEnvironment) -> CommandReturn;
    /// Display a line of text
    fn echo(&self, env: GrubEnvironment) -> CommandReturn;
    /// Evaluate agruments as GRUB commands
    fn eval(&self, env: GrubEnvironment) -> CommandReturn;
    /// Export an environment variable
    fn export(&self, env: GrubEnvironment) -> CommandReturn;
    /// Do nothing, unsuccessfully
    fn r#false(&self, env: GrubEnvironment) -> CommandReturn;
    /// Translate a string
    fn gettext(&self, env: GrubEnvironment) -> CommandReturn;
    /// Fill an MBR based on GPT entries
    fn gptsync(&self, env: GrubEnvironment) -> CommandReturn;
    /// Shut down your computer
    fn halt(&self, env: GrubEnvironment) -> CommandReturn;
    /// Compute or check hash checksum
    fn hashsum(&self, env: GrubEnvironment) -> CommandReturn;
    /// Show help messages
    fn help(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load a Linux initrd
    fn initrd(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load a Linux initrd (16-bit mode)
    fn initrd16(&self, env: GrubEnvironment) -> CommandReturn;
    /// Insert a module
    fn insmod(&self, env: GrubEnvironment) -> CommandReturn;
    /// Check key modifier status
    fn keystatus(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load a Linux kernel
    fn linux(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load a Linux kernel (16-bit mode)
    fn linux16(&self, env: GrubEnvironment) -> CommandReturn;
    /// List variables in environment block
    fn list_env(&self, env: GrubEnvironment) -> CommandReturn;
    /// List trusted public keys
    fn list_trusted(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load variables from environment block
    fn load_env(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load font files
    fn loadfont(&self, env: GrubEnvironment) -> CommandReturn;
    /// Make a device from a filesystem image
    fn loopback(&self, env: GrubEnvironment) -> CommandReturn;
    /// List devices or files
    fn ls(&self, env: GrubEnvironment) -> CommandReturn;
    /// List loaded fonts
    fn lsfonts(&self, env: GrubEnvironment) -> CommandReturn;
    /// Show loaded modules
    fn lsmod(&self, env: GrubEnvironment) -> CommandReturn;
    /// Compute or check MD5 hash
    fn md5sum(&self, env: GrubEnvironment) -> CommandReturn;
    /// Start a menu entry
    fn menuentry(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load module for multiboot kernel
    fn module(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load multiboot compliant kernel
    fn multiboot(&self, env: GrubEnvironment) -> CommandReturn;
    /// Switch to native disk drivers
    fn nativedisk(&self, env: GrubEnvironment) -> CommandReturn;
    /// Enter normal mode
    fn normal(&self, env: GrubEnvironment) -> CommandReturn;
    /// Exit from normal mode
    fn normal_exit(&self, env: GrubEnvironment) -> CommandReturn;
    /// Modify partition table entries
    fn parttool(&self, env: GrubEnvironment) -> CommandReturn;
    /// Set a clear-text password
    fn password(&self, env: GrubEnvironment) -> CommandReturn;
    /// Set a hashed password
    fn password_pbkdf2(&self, env: GrubEnvironment) -> CommandReturn;
    /// Play a tune
    fn play(&self, env: GrubEnvironment) -> CommandReturn;
    /// Retrieve device info
    fn probe(&self, env: GrubEnvironment) -> CommandReturn;
    /// Read values from model-specific registers
    fn rdmsr(&self, env: GrubEnvironment) -> CommandReturn;
    /// Read user input
    fn read(&self, env: GrubEnvironment) -> CommandReturn;
    /// Reboot your computer
    fn reboot(&self, env: GrubEnvironment) -> CommandReturn;
    /// Test if regular expression matches string
    fn regexp(&self, env: GrubEnvironment) -> CommandReturn;
    /// Remove a module
    fn rmmod(&self, env: GrubEnvironment) -> CommandReturn;
    /// Save variables to environment block
    fn save_env(&self, env: GrubEnvironment) -> CommandReturn;
    /// Search devices by file, label, or UUID
    fn search(&self, env: GrubEnvironment) -> CommandReturn;
    /// Emulate keystrokes
    fn sendkey(&self, env: GrubEnvironment) -> CommandReturn;
    /// Set up a serial device
    fn serial(&self, env: GrubEnvironment) -> CommandReturn;
    /// Set an environment variable
    fn set(&self, env: GrubEnvironment) -> CommandReturn;
    /// Compute or check SHA1 hash
    fn sha1sum(&self, env: GrubEnvironment) -> CommandReturn;
    /// Compute or check SHA256 hash
    fn sha256sum(&self, env: GrubEnvironment) -> CommandReturn;
    /// Compute or check SHA512 hash
    fn sha512sum(&self, env: GrubEnvironment) -> CommandReturn;
    /// Wait for a specified number of seconds
    fn sleep(&self, env: GrubEnvironment) -> CommandReturn;
    /// Retrieve SMBIOS information
    fn smbios(&self, env: GrubEnvironment) -> CommandReturn;
    /// Read a configuration file in same context
    fn source(&self, env: GrubEnvironment) -> CommandReturn;
    /// Group menu entries
    fn submenu(&self, env: GrubEnvironment) -> CommandReturn;
    /// Manage input terminals
    fn terminal_input(&self, env: GrubEnvironment) -> CommandReturn;
    /// Manage output terminals
    fn terminal_output(&self, env: GrubEnvironment) -> CommandReturn;
    /// Define terminal type
    fn terminfo(&self, env: GrubEnvironment) -> CommandReturn;
    /// Check file types and compare values
    fn test(&self, env: GrubEnvironment) -> CommandReturn;
    /// Do nothing, successfully
    fn r#true(&self, env: GrubEnvironment) -> CommandReturn;
    /// Add public key to list of trusted keys
    fn trust(&self, env: GrubEnvironment) -> CommandReturn;
    /// Unset an environment variable
    fn unset(&self, env: GrubEnvironment) -> CommandReturn;
    /// Verify detached digital signature
    fn verify_detached(&self, env: GrubEnvironment) -> CommandReturn;
    /// List available video modes
    fn videoinfo(&self, env: GrubEnvironment) -> CommandReturn;
    /// Write values to model-specific registers
    fn wrmsr(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load xen hypervisor binary (only on AArch64)
    fn xen_hypervisor(&self, env: GrubEnvironment) -> CommandReturn;
    /// Load xen modules for xen hypervisor (only on AArch64)
    fn xen_module(&self, env: GrubEnvironment) -> CommandReturn;
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

    fn run_command(&mut self, command: CommandStatement) -> Result<(), String> {
        let env = self
            .environment
            .get_environment(self.current_scope.clone())?;
        let (new_env, exit_code) = match command.command.as_str() {
            "acpi" => self.commands.acpi(env),
            "authenticate" => self.commands.authenticate(env),
            "background_color" => self.commands.background_color(env),
            "background_image" => self.commands.background_image(env),
            "badram" => self.commands.badram(env),
            "blocklist" => self.commands.blocklist(env),
            "boot" => self.commands.boot(env),
            "cat" => self.commands.cat(env),
            "chainloader" => self.commands.chainloader(env),
            "clear" => self.commands.clear(env),
            "cmosclean" => self.commands.cmosclean(env),
            "cmosdump" => self.commands.cmosdump(env),
            "cmostest" => self.commands.cmostest(env),
            "cmp" => self.commands.cmp(env),
            "configfile" => self.commands.configfile(env),
            "cpuid" => self.commands.cpuid(env),
            "crc" => self.commands.crc(env),
            "cryptomount" => self.commands.cryptomount(env),
            "cutmem" => self.commands.cutmem(env),
            "date" => self.commands.date(env),
            "devicetree" => self.commands.devicetree(env),
            "distrust" => self.commands.distrust(env),
            "drivemap" => self.commands.drivemap(env),
            "echo" => self.commands.echo(env),
            "eval" => self.commands.eval(env),
            "export" => self.commands.export(env),
            "false" => self.commands.r#false(env),
            "gettext" => self.commands.gettext(env),
            "gptsync" => self.commands.gptsync(env),
            "halt" => self.commands.halt(env),
            "hashsum" => self.commands.hashsum(env),
            "help" => self.commands.help(env),
            "initrd" => self.commands.initrd(env),
            "initrd16" => self.commands.initrd16(env),
            "insmod" => self.commands.insmod(env),
            "keystatus" => self.commands.keystatus(env),
            "linux" => self.commands.linux(env),
            "linux16" => self.commands.linux16(env),
            "list_env" => self.commands.list_env(env),
            "list_trusted" => self.commands.list_trusted(env),
            "load_env" => self.commands.load_env(env),
            "loadfont" => self.commands.loadfont(env),
            "loopback" => self.commands.loopback(env),
            "ls" => self.commands.ls(env),
            "lsfonts" => self.commands.lsfonts(env),
            "lsmod" => self.commands.lsmod(env),
            "md5sum" => self.commands.md5sum(env),
            "menuentry" => self.commands.menuentry(env),
            "module" => self.commands.module(env),
            "multiboot" => self.commands.multiboot(env),
            "nativedisk" => self.commands.nativedisk(env),
            "normal" => self.commands.normal(env),
            "normal_exit" => self.commands.normal_exit(env),
            "parttool" => self.commands.parttool(env),
            "password" => self.commands.password(env),
            "password_pbkdf2" => self.commands.password_pbkdf2(env),
            "play" => self.commands.play(env),
            "probe" => self.commands.probe(env),
            "rdmsr" => self.commands.rdmsr(env),
            "read" => self.commands.read(env),
            "reboot" => self.commands.reboot(env),
            "regexp" => self.commands.regexp(env),
            "rmmod" => self.commands.rmmod(env),
            "save_env" => self.commands.save_env(env),
            "search" => self.commands.search(env),
            "sendkey" => self.commands.sendkey(env),
            "serial" => self.commands.serial(env),
            "set" => self.commands.set(env),
            "sha1sum" => self.commands.sha1sum(env),
            "sha256sum" => self.commands.sha256sum(env),
            "sha512sum" => self.commands.sha512sum(env),
            "sleep" => self.commands.sleep(env),
            "smbios" => self.commands.smbios(env),
            "source" => self.commands.source(env),
            "submenu" => self.commands.submenu(env),
            "terminal_input" => self.commands.terminal_input(env),
            "terminal_output" => self.commands.terminal_output(env),
            "terminfo" => self.commands.terminfo(env),
            "test" => self.commands.test(env),
            "true" => self.commands.r#true(env),
            "trust" => self.commands.trust(env),
            "unset" => self.commands.unset(env),
            "verify_detached" => self.commands.verify_detached(env),
            "videoinfo" => self.commands.videoinfo(env),
            "wrmsr" => self.commands.wrmsr(env),
            "xen_hypervisor" => self.commands.xen_hypervisor(env),
            "xen_module" => self.commands.xen_module(env),
            _ => {
                if let Some(function) = self.functions.get(&command.command) {
                    let last_scope = self.current_scope.clone();
                    self.current_scope = command.command;
                    self.eval_statements(function.to_owned())?;
                    self.current_scope = last_scope;
                    (HashMap::new(), 0)
                } else {
                    return Err(format!("unknown command or function '{}'", command.command));
                }
            }
        };

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
        fn acpi(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn authenticate(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn background_color(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn background_image(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn badram(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn blocklist(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn boot(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn cat(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn chainloader(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn clear(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn cmosclean(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn cmosdump(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn cmostest(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn cmp(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn configfile(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn cpuid(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn crc(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn cryptomount(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn cutmem(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn date(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn devicetree(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn distrust(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn drivemap(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn echo(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn eval(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn export(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn r#false(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn gettext(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn gptsync(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn halt(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn hashsum(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn help(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn initrd(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn initrd16(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn insmod(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn keystatus(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn linux(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn linux16(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn list_env(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn list_trusted(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn load_env(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn loadfont(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn loopback(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn ls(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn lsfonts(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn lsmod(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn md5sum(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn menuentry(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn module(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn multiboot(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn nativedisk(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn normal(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn normal_exit(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn parttool(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn password(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn password_pbkdf2(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn play(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn probe(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn rdmsr(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn read(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn reboot(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn regexp(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn rmmod(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn save_env(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn search(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn sendkey(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn serial(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn set(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn sha1sum(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn sha256sum(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn sha512sum(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn sleep(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn smbios(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn source(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn submenu(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn terminal_input(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn terminal_output(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn terminfo(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn test(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn r#true(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn trust(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn unset(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn verify_detached(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn videoinfo(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn wrmsr(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn xen_hypervisor(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }

        fn xen_module(&self, _env: GrubEnvironment) -> CommandReturn {
            todo!()
        }
    }

    #[test]
    #[ignore]
    fn test_full_example() {
        let config = r#"
        "#;
        let mut parser = Parser::new(Lexer::new(config));
        let ast = parser.parse().unwrap();
        let mut evaluator = GrubEvaluator::new(NoopGrubCommands {});
        evaluator.eval(ast).expect("no evaluation errors");
    }
}
