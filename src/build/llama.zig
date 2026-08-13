const std = @import("std");
const AppleSdk = @import("AppleSdk.zig");

pub const LlamaLib = struct {
    lib: *std.Build.Step.Compile,
    ggml: *std.Build.Step.Compile,
    include_path: std.Build.LazyPath,
    ggml_include_path: std.Build.LazyPath,
};

pub const GgmlLib = struct {
    lib: *std.Build.Step.Compile,
    include_path: std.Build.LazyPath,
};

/// Null when llama.cpp has not been fetched yet. `lazyDependency` has already
/// queued the fetch by then, and the build runner re-runs this script once it
/// completes, so callers propagate the null and skip declaring their steps.
pub fn buildGgml(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !?GgmlLib {
    const llama_dep = b.lazyDependency("llama", .{}) orelse return null;

    // ggml
    const ggml = b.addLibrary(.{
        .name = "ggml-llama",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });

    ggml.root_module.addIncludePath(llama_dep.path("ggml/include"));
    ggml.root_module.addIncludePath(llama_dep.path("ggml/src"));

    const is_darwin = target.result.os.tag == .macos or target.result.os.tag == .ios;
    const is_ios_simulator = target.result.os.tag == .ios and target.result.abi == .simulator;
    const has_metal = is_darwin and !is_ios_simulator;

    const c_flags: []const []const u8 = if (has_metal) &.{
        "-fvisibility=hidden",
        "-D_DARWIN_C_SOURCE",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=0",
        "-DGGML_COMMIT=\"unknown\"",
        "-DGGML_USE_CPU",
        "-DGGML_USE_METAL",
        "-DGGML_USE_BLAS",
        "-DGGML_USE_ACCELERATE",
    } else if (is_darwin) &.{
        "-fvisibility=hidden",
        "-D_DARWIN_C_SOURCE",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=0",
        "-DGGML_COMMIT=\"unknown\"",
        "-DGGML_USE_CPU",
    } else &.{
        "-fvisibility=hidden",
        "-D_GNU_SOURCE",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=0",
        "-DGGML_COMMIT=\"unknown\"",
        "-DGGML_USE_CPU",
    };
    // Zig 0.16's bundled libc++ headers (LLVM 21) declare std::__hash_memory
    // as an exported dylib symbol, but macOS's system libc++ doesn't provide it.
    // Compile a shim that supplies the missing definition so the static lib
    // links against the system libc++ without undefined symbols.
    if (is_darwin) {
        ggml.root_module.addCSourceFiles(.{
            .root = b.path("src/build"),
            .files = &.{"libcxx_hash_shim.cpp"},
            .flags = &.{"-std=c++17"},
        });
    }

    const cpp_flags: []const []const u8 = if (has_metal) &.{
        "-std=c++17",
        "-fvisibility=hidden",
        "-D_DARWIN_C_SOURCE",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=0",
        "-DGGML_COMMIT=\"unknown\"",
        "-DGGML_USE_CPU",
        "-DGGML_USE_METAL",
        "-DGGML_USE_BLAS",
        "-DGGML_USE_ACCELERATE",
    } else if (is_darwin) &.{
        "-std=c++17",
        "-fvisibility=hidden",
        "-D_DARWIN_C_SOURCE",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=0",
        "-DGGML_COMMIT=\"unknown\"",
        "-DGGML_USE_CPU",
    } else &.{
        "-std=c++17",
        "-fvisibility=hidden",
        "-D_GNU_SOURCE",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=0",
        "-DGGML_COMMIT=\"unknown\"",
        "-DGGML_USE_CPU",
    };

    // Add all backend include paths first (needed for ggml-backend-reg.cpp)
    ggml.root_module.addIncludePath(llama_dep.path("ggml/src/ggml-cpu"));
    if (has_metal) {
        ggml.root_module.addIncludePath(llama_dep.path("ggml/src/ggml-metal"));
        ggml.root_module.addIncludePath(llama_dep.path("ggml/src/ggml-blas"));
    }

    // ggml core
    ggml.root_module.addCSourceFiles(.{
        .root = llama_dep.path("ggml/src"),
        .files = &.{ "ggml.c", "ggml-alloc.c", "ggml-quants.c" },
        .flags = c_flags,
    });
    ggml.root_module.addCSourceFiles(.{
        .root = llama_dep.path("ggml/src"),
        .files = &.{
            "ggml-backend.cpp",
            "ggml-backend-reg.cpp",
            "ggml-backend-meta.cpp",
            "ggml-opt.cpp",
            "ggml-threading.cpp",
            "gguf.cpp",
            "ggml-backend-dl.cpp",
        },
        .flags = cpp_flags,
    });

    // ggml-cpu
    ggml.root_module.addCSourceFiles(.{
        .root = llama_dep.path("ggml/src/ggml-cpu"),
        .files = &.{ "ggml-cpu.c", "quants.c" },
        .flags = c_flags,
    });
    ggml.root_module.addCSourceFiles(.{
        .root = llama_dep.path("ggml/src/ggml-cpu"),
        .files = &.{ "ggml-cpu.cpp", "ops.cpp", "binary-ops.cpp", "unary-ops.cpp", "vec.cpp", "repack.cpp", "hbm.cpp", "traits.cpp" },
        .flags = cpp_flags,
    });

    // aarch64
    if (target.result.cpu.arch == .aarch64) {
        ggml.root_module.addIncludePath(llama_dep.path("ggml/src/ggml-cpu/arch/arm"));
        ggml.root_module.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-cpu/arch/arm"),
            .files = &.{ "cpu-feats.cpp", "repack.cpp" },
            .flags = cpp_flags,
        });
        ggml.root_module.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-cpu/arch/arm"),
            .files = &.{"quants.c"},
            .flags = c_flags,
        });
    }

    // x86 amx. Unlike the arm branch above this omits `cpu-feats.cpp`: its only
    // contents are wrapped in GGML_BACKEND_DL_SCORE_IMPL, which expands to
    // nothing unless GGML_BACKEND_DL is defined, so it would be an empty
    // translation unit here.
    if (target.result.cpu.arch == .x86_64) {
        ggml.root_module.addIncludePath(llama_dep.path("ggml/src/ggml-cpu/amx"));
        ggml.root_module.addIncludePath(llama_dep.path("ggml/src/ggml-cpu/arch/x86"));
        ggml.root_module.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-cpu/arch/x86"),
            .files = &.{"quants.c"},
            .flags = c_flags,
        });
        ggml.root_module.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-cpu/arch/x86"),
            .files = &.{"repack.cpp"},
            .flags = cpp_flags,
        });
        ggml.root_module.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-cpu/amx"),
            .files = &.{ "amx.cpp", "mmq.cpp" },
            .flags = cpp_flags,
        });
    }

    if (is_darwin) {
        try AppleSdk.addPaths(b, ggml);
    }

    // metal
    if (has_metal) {
        ggml.root_module.addIncludePath(llama_dep.path("ggml/src/ggml-metal"));

        const metal_flags_cpp = &[_][]const u8{ "-std=c++17", "-fvisibility=hidden", "-DGGML_USE_METAL", "-DGGML_METAL_EMBED_LIBRARY" };
        const metal_flags_objc = &[_][]const u8{ "-fvisibility=hidden", "-DGGML_USE_METAL", "-DGGML_METAL_EMBED_LIBRARY", "-fno-objc-arc" };

        ggml.root_module.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-metal"),
            .files = &.{ "ggml-metal.cpp", "ggml-metal-common.cpp", "ggml-metal-ops.cpp", "ggml-metal-device.cpp" },
            .flags = metal_flags_cpp,
        });
        ggml.root_module.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-metal"),
            .files = &.{ "ggml-metal-context.m", "ggml-metal-device.m" },
            .flags = metal_flags_objc,
        });

        // Embed the Metal library source
        // Merge the metal source files - replace placeholders with actual content
        // The metal file has: __embed_ggml-common.h__ and #include "ggml-metal-impl.h"
        // that need to be replaced with actual file contents
        const merge_metal = b.addSystemCommand(&.{
            "/bin/sh", "-c",
            \\sed -e '/__embed_ggml-common.h__/{r '"$1"'' -e 'd;}' "$3" | \
            \\sed -e '/#include "ggml-metal-impl.h"/{r '"$2"'' -e 'd;}' > "$4"
            ,
            "--",
        });
        merge_metal.addFileArg(llama_dep.path("ggml/src/ggml-common.h"));
        merge_metal.addFileArg(llama_dep.path("ggml/src/ggml-metal/ggml-metal-impl.h"));
        merge_metal.addFileArg(llama_dep.path("ggml/src/ggml-metal/ggml-metal.metal"));
        const merged_metal = merge_metal.addOutputFileArg("ggml-metal-merged.metal");

        // Generate assembly that embeds the metal source using absolute path
        const gen_asm = b.addSystemCommand(&.{
            "/bin/sh", "-c",
            \\cat > "$2" <<EOF
            \\.section __DATA,__ggml_metallib
            \\.globl _ggml_metallib_start
            \\_ggml_metallib_start:
            \\.incbin "$1"
            \\.globl _ggml_metallib_end
            \\_ggml_metallib_end:
            \\EOF
            ,
            "--",
        });
        gen_asm.addFileArg(merged_metal);
        const embed_asm = gen_asm.addOutputFileArg("ggml-metal-embed.s");

        ggml.root_module.addAssemblyFile(embed_asm);

        ggml.root_module.linkFramework("Foundation", .{});
        ggml.root_module.linkFramework("Metal", .{});
        ggml.root_module.linkFramework("MetalKit", .{});
    }

    // blas (accelerate)
    if (has_metal) {
        ggml.root_module.addIncludePath(llama_dep.path("ggml/src/ggml-blas"));
        ggml.root_module.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-blas"),
            .files = &.{"ggml-blas.cpp"},
            .flags = &.{
                "-std=c++17",
                "-fvisibility=hidden",
                "-DGGML_USE_BLAS",
                "-DGGML_BLAS_USE_ACCELERATE",
                "-DACCELERATE_NEW_LAPACK",
                "-DACCELERATE_LAPACK_ILP64",
                "-DGGML_VERSION=0",
                "-DGGML_COMMIT=\"unknown\"",
            },
        });
        // Accelerate framework path already added above via sdk_path
        ggml.root_module.linkFramework("Accelerate", .{});
    }

    return .{
        .lib = ggml,
        .include_path = llama_dep.path("ggml/include"),
    };
}

/// Null under the same conditions as `buildGgml`.
pub fn buildWithGgml(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ggml_dep: GgmlLib,
) !?LlamaLib {
    const llama_dep = b.lazyDependency("llama", .{}) orelse return null;
    const ggml = ggml_dep.lib;
    const is_darwin = target.result.os.tag == .macos or target.result.os.tag == .ios;
    const is_ios_simulator = target.result.os.tag == .ios and target.result.abi == .simulator;
    const has_metal = is_darwin and !is_ios_simulator;

    // llama
    const llama_lib = b.addLibrary(.{
        .name = "llama",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });

    llama_lib.root_module.addIncludePath(llama_dep.path("include"));
    llama_lib.root_module.addIncludePath(llama_dep.path("src"));
    llama_lib.root_module.addIncludePath(llama_dep.path("ggml/include"));
    llama_lib.root_module.addIncludePath(llama_dep.path("ggml/src"));

    // LLAMA_VERSION is required: llama_version() returns it directly, so without
    // the define the library does not compile. Upstream's build derives it from
    // git describe; nothing here surfaces llama_version(), so a placeholder is
    // honest rather than a fabricated version number. Same reasoning as the
    // GGML_VERSION/GGML_COMMIT placeholders above.
    const llama_flags = if (has_metal) &[_][]const u8{
        "-std=c++17",
        "-fvisibility=hidden",
        "-D_DARWIN_C_SOURCE",
        "-DLLAMA_VERSION=\"unknown\"",
        "-DGGML_USE_METAL",
        "-DGGML_USE_BLAS",
        "-DGGML_USE_CPU",
        "-DGGML_USE_ACCELERATE",
    } else &[_][]const u8{
        "-std=c++17",
        "-fvisibility=hidden",
        "-D_GNU_SOURCE",
        "-DLLAMA_VERSION=\"unknown\"",
        "-DGGML_USE_CPU",
    };

    // llama.cpp reorganizes src/ and especially src/models/ freely between
    // releases: b10405 renamed llama-sampling.cpp to llama-sampler.cpp, dropped
    // the whole `-iswa` model family and added a dozen models. A hardcoded list
    // therefore breaks on every bump, and breaks late — at the C compiler rather
    // than at configure time. Compile whatever is actually present, which is
    // what upstream's own build does.
    llama_lib.root_module.addCSourceFiles(.{
        .root = llama_dep.path("src"),
        .files = try cppSourcesIn(b, llama_dep, "src"),
        .flags = llama_flags,
    });

    // models
    llama_lib.root_module.addIncludePath(llama_dep.path("src/models"));
    llama_lib.root_module.addCSourceFiles(.{
        .root = llama_dep.path("src/models"),
        .files = try cppSourcesIn(b, llama_dep, "src/models"),
        .flags = llama_flags,
    });
    llama_lib.root_module.linkLibrary(ggml);

    if (target.result.os.tag.isDarwin()) {
        try AppleSdk.addPaths(b, llama_lib);
    }

    return .{
        .lib = llama_lib,
        .ggml = ggml,
        .include_path = llama_dep.path("include"),
        .ggml_include_path = llama_dep.path("ggml/include"),
    };
}

/// Every `.cpp` directly inside `sub_path` of a fetched dependency. Sorted, so
/// the build hash does not depend on directory iteration order. Subdirectories
/// are skipped: callers list them separately when they need different flags.
fn cppSourcesIn(
    b: *std.Build,
    dep: *std.Build.Dependency,
    sub_path: []const u8,
) ![]const []const u8 {
    const io = b.graph.io;
    var dir = try dep.builder.build_root.handle.openDir(io, sub_path, .{ .iterate = true });
    defer dir.close(io);

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".cpp")) continue;
        try files.append(b.graph.arena, b.dupe(entry.name));
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.order(u8, a, c) == .lt;
        }
    }.lessThan);
    return files.items;
}

pub fn link(compile: *std.Build.Step.Compile, llama: LlamaLib) void {
    compile.root_module.linkLibrary(llama.lib);
    compile.root_module.addIncludePath(llama.include_path);
    compile.root_module.addIncludePath(llama.ggml_include_path);
}
