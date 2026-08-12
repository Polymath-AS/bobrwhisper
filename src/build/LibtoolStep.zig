const std = @import("std");

pub const LibtoolStep = @This();

step: *std.Build.Step,
output: std.Build.LazyPath,

pub const Options = struct {
    name: []const u8,
    target: std.Build.ResolvedTarget,
    sources: []const std.Build.LazyPath,
};

pub fn create(b: *std.Build, opts: Options) *LibtoolStep {
    const self = b.allocator.create(LibtoolStep) catch @panic("OOM");

    const run = std.Build.Step.Run.create(b, b.fmt("archive {s}", .{opts.name}));
    run.addArgs(&.{ b.graph.zig_exe, "ar" });
    if (opts.target.result.os.tag.isDarwin()) {
        run.addArg("--format=darwin");
    }
    // qL flattens input archives; c creates the output and s writes its index.
    run.addArg("qcsL");

    const output = run.addOutputFileArg(b.fmt("lib{s}.a", .{opts.name}));

    for (opts.sources) |source| {
        run.addFileArg(source);
    }

    self.* = .{
        .step = &run.step,
        .output = output,
    };

    return self;
}
