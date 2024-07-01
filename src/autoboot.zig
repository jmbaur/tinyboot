const Autoboot = @This();

pub fn init() Autoboot {
    return .{};
}

pub fn deinit(self: *Autoboot) void {
    _ = self;
}
