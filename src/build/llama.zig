const std = @import("std");
const AppleSdk = @import("AppleSdk.zig");

pub const LlamaLib = struct {
    lib: *std.Build.Step.Compile,
    ggml: *std.Build.Step.Compile,
    include_path: std.Build.LazyPath,
    ggml_include_path: std.Build.LazyPath,
};

pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !LlamaLib {
    const llama_dep = b.dependency("llama", .{});

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

    ggml.addIncludePath(llama_dep.path("ggml/include"));
    ggml.addIncludePath(llama_dep.path("ggml/src"));

    const is_darwin = target.result.os.tag == .macos or target.result.os.tag == .ios;
    const is_ios_simulator = target.result.os.tag == .ios and target.result.abi == .simulator;
    const has_metal = is_darwin and !is_ios_simulator;
    
    const c_flags: []const []const u8 = if (has_metal) &.{
        "-D_DARWIN_C_SOURCE",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=0",
        "-DGGML_COMMIT=\"unknown\"",
        "-DGGML_USE_CPU",
        "-DGGML_USE_METAL",
        "-DGGML_USE_BLAS",
        "-DGGML_USE_ACCELERATE",
    } else if (is_darwin) &.{
        "-D_DARWIN_C_SOURCE",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=0",
        "-DGGML_COMMIT=\"unknown\"",
        "-DGGML_USE_CPU",
    } else &.{
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=0",
        "-DGGML_COMMIT=\"unknown\"",
        "-DGGML_USE_CPU",
    };
    const cpp_flags: []const []const u8 = if (has_metal) &.{
        "-std=c++17",
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
        "-D_DARWIN_C_SOURCE",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=0",
        "-DGGML_COMMIT=\"unknown\"",
        "-DGGML_USE_CPU",
    } else &.{
        "-std=c++17",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=0",
        "-DGGML_COMMIT=\"unknown\"",
        "-DGGML_USE_CPU",
    };

    // Add all backend include paths first (needed for ggml-backend-reg.cpp)
    ggml.addIncludePath(llama_dep.path("ggml/src/ggml-cpu"));
    if (has_metal) {
        ggml.addIncludePath(llama_dep.path("ggml/src/ggml-metal"));
        ggml.addIncludePath(llama_dep.path("ggml/src/ggml-blas"));
    }

    // ggml core
    ggml.addCSourceFiles(.{
        .root = llama_dep.path("ggml/src"),
        .files = &.{ "ggml.c", "ggml-alloc.c", "ggml-quants.c" },
        .flags = c_flags,
    });
    ggml.addCSourceFiles(.{
        .root = llama_dep.path("ggml/src"),
        .files = &.{ "ggml-backend.cpp", "ggml-backend-reg.cpp", "ggml-opt.cpp", "ggml-threading.cpp", "gguf.cpp", "ggml-backend-dl.cpp" },
        .flags = cpp_flags,
    });

    // ggml-cpu
    ggml.addCSourceFiles(.{
        .root = llama_dep.path("ggml/src/ggml-cpu"),
        .files = &.{ "ggml-cpu.c", "quants.c" },
        .flags = c_flags,
    });
    ggml.addCSourceFiles(.{
        .root = llama_dep.path("ggml/src/ggml-cpu"),
        .files = &.{ "ggml-cpu.cpp", "ops.cpp", "binary-ops.cpp", "unary-ops.cpp", "vec.cpp", "repack.cpp", "hbm.cpp", "traits.cpp" },
        .flags = cpp_flags,
    });

    // aarch64
    if (target.result.cpu.arch == .aarch64) {
        ggml.addIncludePath(llama_dep.path("ggml/src/ggml-cpu/arch/arm"));
        ggml.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-cpu/arch/arm"),
            .files = &.{ "cpu-feats.cpp", "repack.cpp" },
            .flags = cpp_flags,
        });
        ggml.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-cpu/arch/arm"),
            .files = &.{"quants.c"},
            .flags = c_flags,
        });
    }

    // x86 amx
    if (target.result.cpu.arch == .x86_64) {
        ggml.addIncludePath(llama_dep.path("ggml/src/ggml-cpu/amx"));
        ggml.addCSourceFiles(.{
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
        ggml.addIncludePath(llama_dep.path("ggml/src/ggml-metal"));

        const metal_flags_cpp = &[_][]const u8{ "-std=c++17", "-DGGML_USE_METAL", "-DGGML_METAL_EMBED_LIBRARY" };
        const metal_flags_objc = &[_][]const u8{ "-DGGML_USE_METAL", "-DGGML_METAL_EMBED_LIBRARY", "-fno-objc-arc" };

        ggml.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-metal"),
            .files = &.{ "ggml-metal.cpp", "ggml-metal-common.cpp", "ggml-metal-ops.cpp", "ggml-metal-device.cpp" },
            .flags = metal_flags_cpp,
        });
        ggml.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-metal"),
            .files = &.{ "ggml-metal-context.m", "ggml-metal-device.m" },
            .flags = metal_flags_objc,
        });

        // Embed the Metal library source
        // Merge the metal source files - replace placeholders with actual content
        // The metal file has: __embed_ggml-common.h__ and #include "ggml-metal-impl.h"
        // that need to be replaced with actual file contents
        const merge_metal = b.addSystemCommand(&.{ "/bin/sh", "-c",
            \\sed -e '/__embed_ggml-common.h__/{r '"$1"'' -e 'd;}' "$3" | \
            \\sed -e '/#include "ggml-metal-impl.h"/{r '"$2"'' -e 'd;}' > "$4"
        , "--" });
        merge_metal.addFileArg(llama_dep.path("ggml/src/ggml-common.h"));
        merge_metal.addFileArg(llama_dep.path("ggml/src/ggml-metal/ggml-metal-impl.h"));
        merge_metal.addFileArg(llama_dep.path("ggml/src/ggml-metal/ggml-metal.metal"));
        const merged_metal = merge_metal.addOutputFileArg("ggml-metal-merged.metal");

        // Generate assembly that embeds the metal source using absolute path
        const gen_asm = b.addSystemCommand(&.{ "/bin/sh", "-c",
            \\cat > "$2" <<EOF
            \\.section __DATA,__ggml_metallib
            \\.globl _ggml_metallib_start
            \\_ggml_metallib_start:
            \\.incbin "$1"
            \\.globl _ggml_metallib_end
            \\_ggml_metallib_end:
            \\EOF
        , "--" });
        gen_asm.addFileArg(merged_metal);
        const embed_asm = gen_asm.addOutputFileArg("ggml-metal-embed.s");

        ggml.addAssemblyFile(embed_asm);

        ggml.linkFramework("Foundation");
        ggml.linkFramework("Metal");
        ggml.linkFramework("MetalKit");
    }

    // blas (accelerate)
    if (has_metal) {
        ggml.addIncludePath(llama_dep.path("ggml/src/ggml-blas"));
        ggml.addCSourceFiles(.{
            .root = llama_dep.path("ggml/src/ggml-blas"),
            .files = &.{"ggml-blas.cpp"},
            .flags = &.{
                "-std=c++17",
                "-DGGML_USE_BLAS",
                "-DGGML_BLAS_USE_ACCELERATE",
                "-DACCELERATE_NEW_LAPACK",
                "-DACCELERATE_LAPACK_ILP64",
                "-DGGML_VERSION=0",
                "-DGGML_COMMIT=\"unknown\"",
            },
        });
        // Accelerate framework path already added above via sdk_path
        ggml.linkFramework("Accelerate");
    }

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

    llama_lib.addIncludePath(llama_dep.path("include"));
    llama_lib.addIncludePath(llama_dep.path("src"));
    llama_lib.addIncludePath(llama_dep.path("ggml/include"));
    llama_lib.addIncludePath(llama_dep.path("ggml/src"));

    const llama_flags = if (has_metal) &[_][]const u8{
        "-std=c++17",
        "-D_DARWIN_C_SOURCE",
        "-DGGML_USE_METAL",
        "-DGGML_USE_BLAS",
        "-DGGML_USE_CPU",
        "-DGGML_USE_ACCELERATE",
    } else &[_][]const u8{
        "-std=c++17",
        "-DGGML_USE_CPU",
    };

    llama_lib.addCSourceFiles(.{
        .root = llama_dep.path("src"),
        .files = &.{
            "llama.cpp",             "llama-adapter.cpp",       "llama-arch.cpp",
            "llama-batch.cpp",       "llama-chat.cpp",          "llama-context.cpp",
            "llama-cparams.cpp",     "llama-grammar.cpp",       "llama-graph.cpp",
            "llama-hparams.cpp",     "llama-impl.cpp",          "llama-io.cpp",
            "llama-kv-cache.cpp",    "llama-kv-cache-iswa.cpp", "llama-memory.cpp",
            "llama-memory-hybrid.cpp", "llama-memory-hybrid-iswa.cpp", "llama-memory-recurrent.cpp",
            "llama-mmap.cpp",        "llama-model.cpp",         "llama-model-loader.cpp",
            "llama-model-saver.cpp", "llama-quant.cpp",         "llama-sampling.cpp",
            "llama-vocab.cpp",       "unicode.cpp",             "unicode-data.cpp",
        },
        .flags = llama_flags,
    });

    // models
    llama_lib.addIncludePath(llama_dep.path("src/models"));
    llama_lib.addCSourceFiles(.{
        .root = llama_dep.path("src/models"),
        .files = &.{
            "afmoe.cpp",          "apertus.cpp",        "arcee.cpp",          "arctic.cpp",
            "arwkv7.cpp",         "baichuan.cpp",       "bailingmoe.cpp",     "bailingmoe2.cpp",
            "bert.cpp",           "bitnet.cpp",         "bloom.cpp",          "chameleon.cpp",
            "chatglm.cpp",        "codeshell.cpp",      "cogvlm.cpp",         "cohere2-iswa.cpp",
            "command-r.cpp",      "dbrx.cpp",           "deci.cpp",           "deepseek.cpp",
            "deepseek2.cpp",      "dots1.cpp",          "dream.cpp",          "ernie4-5-moe.cpp",
            "ernie4-5.cpp",       "exaone-moe.cpp",     "exaone.cpp",         "exaone4.cpp",
            "falcon-h1.cpp",      "falcon.cpp",         "gemma-embedding.cpp", "gemma.cpp",
            "gemma2-iswa.cpp",    "gemma3.cpp",         "gemma3n-iswa.cpp",   "glm4-moe.cpp",
            "glm4.cpp",           "gpt2.cpp",           "gptneox.cpp",        "granite-hybrid.cpp",
            "granite.cpp",        "graph-context-mamba.cpp", "grok.cpp",       "grovemoe.cpp",
            "hunyuan-dense.cpp",  "hunyuan-moe.cpp",    "internlm2.cpp",      "jais.cpp",
            "jamba.cpp",          "lfm2.cpp",           "llada-moe.cpp",      "llada.cpp",
            "llama-iswa.cpp",     "llama.cpp",          "maincoder.cpp",      "mamba.cpp",
            "mimo2-iswa.cpp",     "minicpm3.cpp",       "minimax-m2.cpp",     "mistral3.cpp",
            "modern-bert.cpp",    "mpt.cpp",            "nemotron-h.cpp",     "nemotron.cpp",
            "neo-bert.cpp",       "olmo.cpp",           "olmo2.cpp",          "olmoe.cpp",
            "openai-moe-iswa.cpp", "openelm.cpp",       "orion.cpp",          "pangu-embedded.cpp",
            "phi2.cpp",           "phi3.cpp",           "plamo.cpp",          "plamo2.cpp",
            "plamo3.cpp",         "plm.cpp",            "qwen.cpp",           "qwen2.cpp",
            "qwen2moe.cpp",       "qwen2vl.cpp",        "qwen3.cpp",          "qwen3moe.cpp",
            "qwen3next.cpp",      "qwen3vl-moe.cpp",    "qwen3vl.cpp",        "refact.cpp",
            "rnd1.cpp",           "rwkv6-base.cpp",     "rwkv6.cpp",          "rwkv6qwen2.cpp",
            "rwkv7-base.cpp",     "rwkv7.cpp",          "seed-oss.cpp",       "smallthinker.cpp",
            "smollm3.cpp",        "stablelm.cpp",       "starcoder.cpp",      "starcoder2.cpp",
            "t5-dec.cpp",         "t5-enc.cpp",         "wavtokenizer-dec.cpp", "xverse.cpp",
        },
        .flags = llama_flags,
    });

    llama_lib.linkLibrary(ggml);

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

pub fn link(compile: *std.Build.Step.Compile, llama: LlamaLib) void {
    compile.linkLibrary(llama.lib);
    compile.addIncludePath(llama.include_path);
    compile.addIncludePath(llama.ggml_include_path);
}
