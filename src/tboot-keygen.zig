const std = @import("std");
const clap = @import("clap");
const mbedtls = @import("mbedtls");

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                  Display this help and exit.
        \\-s, --seed <STR>            Seed to use when generating keys (only set if reproducibility is needed).
        \\-n, --common-name <STR>     Common name for certificate.
        \\-o, --organization <STR>    Organization for certificate.
        \\-c, --country <STR>         Country for certificate.
        \\-v, --valid-seconds <NUM>   Number of seconds the certificate is valid for (defaults to 31536000, 1 year).
        \\-t, --time-now <NUM>        Number of seconds past the Unix epoch (defaults to current time, only set if reproducibility is needed).
        \\
    );

    const parsers = comptime .{
        .STR = clap.parsers.string,
        .NUM = clap.parsers.int(u64, 10),
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

    try mbedtls.generateKeyAndCert(
        init.io,
        init.arena.allocator(),
        std.Io.Dir.cwd(),
        res.args.@"time-now",
        res.args.@"valid-seconds",
        res.args.@"common-name" orelse {
            try clap.usageToFile(init.io, .stderr(), clap.Help, &params);
            return;
        },
        res.args.organization orelse {
            try clap.usageToFile(init.io, .stderr(), clap.Help, &params);
            return;
        },
        res.args.country orelse {
            try clap.usageToFile(init.io, .stderr(), clap.Help, &params);
            return;
        },
        res.args.seed,
    );
}
