const std = @import("std");

pub const CombineArchivesStep = @This();

step: *std.Build.Step,
output: std.Build.LazyPath,

pub const Options = struct {
    name: []const u8,
    /// Object format of the *target*, which decides the archive format. Not the
    /// host: cross-compiling to Apple still needs a Mach-O archive.
    ofmt: std.Target.ObjectFormat,
    sources: []const std.Build.LazyPath,
};

/// Merge dependency archives so an installed static library is usable as a
/// single file.
///
/// Both branches deliberately avoid a bare `ar` from PATH: it is not a
/// build-graph input, so a toolchain change would not invalidate the cache, and
/// it is simply absent from a mkShellNoCC dev shell. `zig ar` ships with the
/// compiler that is already driving this build.
pub fn create(b: *std.Build, options: Options) *CombineArchivesStep {
    const self = b.allocator.create(CombineArchivesStep) catch @panic("OOM");
    const run = std.Build.Step.Run.create(b, b.fmt("combine lib{s}.a", .{options.name}));

    // Apple's `libtool -static` is the only tool that reliably produces the
    // Mach-O archives ld64 and xcodebuild expect, and it is already required by
    // the XCFramework path.
    if (options.ofmt == .macho) {
        run.addArgs(&.{ "libtool", "-static", "-o" });
    } else {
        // llvm-ar's MRI script mode is what expands input archives into the
        // output instead of nesting them as members.
        run.addArgs(&.{
            "sh",
            "-c",
            \\set -eu
            \\ar="$1"
            \\output="$2"
            \\shift 2
            \\{
            \\  printf 'CREATE %s\n' "$output"
            \\  for archive do printf 'ADDLIB %s\n' "$archive"; done
            \\  printf 'SAVE\nEND\n'
            \\} | "$ar" ar -M
            ,
            "--",
            b.graph.zig_exe,
        });
    }

    const output = run.addOutputFileArg(b.fmt("lib{s}.a", .{options.name}));
    for (options.sources) |source| run.addFileArg(source);

    self.* = .{ .step = &run.step, .output = output };
    return self;
}
