/// Message that can be sent to the server
pub const ClientMsg = union(enum) {
    /// Request to the server that the system should be powered off.
    Poweroff,

    /// Request to the server that the system should be rebooted.
    Reboot,

    /// Empty message
    None,
};

/// Message that can be sent to a client
pub const ServerMsg = union(enum) {
    /// Spawn a shell prompt, even if the user is not present
    ForceShell,
    /// Empty message
    None,
};
