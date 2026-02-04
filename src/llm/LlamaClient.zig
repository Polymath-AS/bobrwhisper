//! llama.cpp wrapper for local LLM inference

const std = @import("std");
const c = @cImport({
    @cInclude("llama.h");
});

const LlamaClient = @This();

allocator: std.mem.Allocator,
model: ?*c.llama_model,
ctx: ?*c.llama_context,
sampler: ?*c.llama_sampler,
vocab: ?*const c.llama_vocab,

pub const Config = struct {
    model_path: []const u8,
    n_ctx: u32 = 2048,
    n_threads: i32 = 4,
    n_gpu_layers: i32 = 99,
};

pub fn init(allocator: std.mem.Allocator, config: Config) !LlamaClient {
    c.llama_backend_init();

    var model_params = c.llama_model_default_params();
    model_params.n_gpu_layers = config.n_gpu_layers;

    const model_path_z = try allocator.dupeZ(u8, config.model_path);
    defer allocator.free(model_path_z);

    const model = c.llama_model_load_from_file(model_path_z.ptr, model_params);
    if (model == null) {
        return error.ModelLoadFailed;
    }

    var ctx_params = c.llama_context_default_params();
    ctx_params.n_ctx = config.n_ctx;
    ctx_params.n_threads = config.n_threads;
    ctx_params.n_threads_batch = config.n_threads;

    const ctx = c.llama_init_from_model(model, ctx_params);
    if (ctx == null) {
        c.llama_model_free(model);
        return error.ContextCreationFailed;
    }

    const vocab = c.llama_model_get_vocab(model);
    const sampler = createSampler();

    return .{
        .allocator = allocator,
        .model = model,
        .ctx = ctx,
        .sampler = sampler,
        .vocab = vocab,
    };
}

pub fn deinit(self: *LlamaClient) void {
    if (self.sampler) |s| c.llama_sampler_free(s);
    if (self.ctx) |ctx| c.llama_free(ctx);
    if (self.model) |m| c.llama_model_free(m);
    c.llama_backend_free();
}

fn createSampler() *c.llama_sampler {
    const sparams = c.llama_sampler_chain_default_params();
    const smpl = c.llama_sampler_chain_init(sparams);

    c.llama_sampler_chain_add(smpl, c.llama_sampler_init_top_k(40));
    c.llama_sampler_chain_add(smpl, c.llama_sampler_init_top_p(0.9, 1));
    c.llama_sampler_chain_add(smpl, c.llama_sampler_init_temp(0.7));
    c.llama_sampler_chain_add(smpl, c.llama_sampler_init_dist(c.LLAMA_DEFAULT_SEED));

    return smpl;
}

pub fn generate(self: *LlamaClient, prompt: []const u8, max_tokens: u32) ![]u8 {
    _ = self.model orelse return error.NoModel;
    const ctx = self.ctx orelse return error.NoContext;
    const sampler = self.sampler orelse return error.NoSampler;
    const vocab = self.vocab orelse return error.NoVocab;

    // Tokenize prompt
    const n_prompt_max: i32 = @intCast(prompt.len + 128);
    const prompt_tokens = try self.allocator.alloc(c.llama_token, @intCast(n_prompt_max));
    defer self.allocator.free(prompt_tokens);

    const prompt_z = try self.allocator.dupeZ(u8, prompt);
    defer self.allocator.free(prompt_z);

    const n_prompt = c.llama_tokenize(vocab, prompt_z.ptr, @intCast(prompt.len), prompt_tokens.ptr, n_prompt_max, true, true);
    if (n_prompt < 0) {
        return error.TokenizeFailed;
    }

    // Use llama_batch_get_one for simple single-sequence inference
    var batch = c.llama_batch_get_one(prompt_tokens.ptr, n_prompt);

    // Decode prompt
    if (c.llama_decode(ctx, batch) != 0) {
        return error.DecodeFailed;
    }

    // Generate tokens
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(self.allocator);

    var n_cur: i32 = n_prompt;
    const n_ctx: i32 = @intCast(c.llama_n_ctx(ctx));
    const n_max: i32 = @min(n_ctx, n_prompt + @as(i32, @intCast(max_tokens)));

    while (n_cur < n_max) {
        const new_token = c.llama_sampler_sample(sampler, ctx, -1);

        if (c.llama_vocab_is_eog(vocab, new_token)) {
            break;
        }

        // Convert token to text
        var buf: [256]u8 = undefined;
        const n = c.llama_token_to_piece(vocab, new_token, &buf, buf.len, 0, true);
        if (n > 0) {
            try output.appendSlice(self.allocator, buf[0..@intCast(n)]);
        }

        // Decode next token
        var token_buf = [_]c.llama_token{new_token};
        batch = c.llama_batch_get_one(&token_buf, 1);
        if (c.llama_decode(ctx, batch) != 0) {
            break;
        }

        n_cur += 1;
    }

    // Clear memory for next generation
    c.llama_memory_clear(c.llama_get_memory(ctx), true);

    return output.toOwnedSlice(self.allocator);
}

pub fn formatTranscript(self: *LlamaClient, transcript: []const u8) ![]u8 {
    const prompt = try std.fmt.allocPrint(self.allocator,
        \\Clean up this transcribed speech. Remove filler words (um, uh, like, you know).
        \\Fix grammar and punctuation. Keep the meaning intact. Output ONLY the cleaned text, nothing else.
        \\
        \\Input: {s}
        \\
        \\Output:
    , .{transcript});
    defer self.allocator.free(prompt);

    return self.generate(prompt, 256);
}
