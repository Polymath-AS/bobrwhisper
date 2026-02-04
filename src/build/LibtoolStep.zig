const std = @import("std");

pub const LibtoolStep = @This();

step: *std.Build.Step,
output: std.Build.LazyPath,

pub const Options = struct {
    name: []const u8,
    sources: []const std.Build.LazyPath,
};

pub fn create(b: *std.Build, opts: Options) *LibtoolStep {
    const self = b.allocator.create(LibtoolStep) catch @panic("OOM");

    const run = std.Build.Step.Run.create(b, b.fmt("libtool {s}", .{opts.name}));
    run.addArgs(&.{ "libtool", "-static", "-o" });

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
