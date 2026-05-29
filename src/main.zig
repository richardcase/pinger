const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) u8 {
    return cli.run(init);
}

test {
    _ = cli;
    _ = @import("duration.zig");
    _ = @import("gofmt.zig");
    _ = @import("rfc3339.zig");
    _ = @import("config.zig");
    _ = @import("store/record.zig");
    _ = @import("store/writer.zig");
    _ = @import("store/reader.zig");
    _ = @import("report/summary.zig");
    _ = @import("report/format.zig");
    _ = @import("probe.zig");
    _ = @import("monitor/monitor.zig");
    _ = @import("monitor/reporter.zig");
    _ = @import("monitor/asciigraph.zig");
}
