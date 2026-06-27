const std = @import("std");
const clap = @import("clap");
const mbedtls = @import("mbedtls");

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Display this help and exit.
        \\--private-key <FILE>    Private key to sign with.
        \\--certificate <FILE>    X509 certificate to sign with.
        \\<FILE>                  Input file.
        \\<FILE>                  Output file.
        \\
    );

    const parsers = comptime .{
        .FILE = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, &parsers, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = init.arena.allocator(),
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        try clap.usageToFile(init.io, .stderr(), clap.Help, &params);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});
    }

    if (res.positionals[0] == null or
        res.positionals[1] == null or
        res.args.@"private-key" == null or
        res.args.certificate == null)
    {
        try diag.reportToFile(init.io, .stderr(), error.InvalidArgument);
        try clap.usageToFile(init.io, .stderr(), clap.Help, &params);
        return;
    }

    const in_file = res.positionals[0].?;
    const out_file = res.positionals[1].?;
    const private_key_filepath = res.args.@"private-key".?;
    const certificate_filepath = res.args.certificate.?;

    return mbedtls.signFile(
        init.io,
        init.arena.allocator(),
        in_file,
        out_file,
        private_key_filepath,
        certificate_filepath,
    );
}
