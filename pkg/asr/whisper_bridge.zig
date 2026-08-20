pub const Context = opaque {};

/// Mirrors `bobrwhisper_token_s`. Written through an out-pointer so the C ABI
/// never has to classify a small struct return.
pub const TokenData = extern struct {
    identifier: i32,
    probability: f32,
    log_probability: f32,
};

pub extern fn bobrwhisper_whisper_disable_logging() void;
pub extern fn bobrwhisper_whisper_init(model_path: [*:0]const u8, use_gpu: bool) ?*Context;
pub extern fn bobrwhisper_whisper_free(ctx: *Context) void;
pub extern fn bobrwhisper_whisper_transcribe(
    ctx: *Context,
    samples: [*]const f32,
    sample_count: i32,
    language: [*:0]const u8,
    n_threads: i32,
    live: bool,
    /// Let the decoder emit timestamp tokens. Costs decode time and changes
    /// where segments split — and therefore the concatenated text — so the
    /// caller opts in.
    timestamps: bool,
    vad_enabled: bool,
    vad_model_path: ?[*:0]const u8,
    vad_threshold: f32,
    vad_min_speech_ms: i32,
    vad_min_silence_ms: i32,
    vad_speech_pad_ms: i32,
    initial_prompt: ?[*:0]const u8,
    /// Cooperative cancellation. Polled between compute steps; pass null to
    /// make the call uninterruptible.
    abort_flag: ?*const bool,
) c_int;

pub extern fn bobrwhisper_whisper_segment_count(ctx: *Context) i32;
pub extern fn bobrwhisper_whisper_segment_text(ctx: *Context, segment_index: i32) ?[*:0]const u8;
/// Centiseconds. Only meaningful when `timestamps` was set on the call.
pub extern fn bobrwhisper_whisper_segment_start_cs(ctx: *Context, segment_index: i32) i64;
pub extern fn bobrwhisper_whisper_segment_end_cs(ctx: *Context, segment_index: i32) i64;
pub extern fn bobrwhisper_whisper_segment_no_speech_probability(ctx: *Context, segment_index: i32) f32;
pub extern fn bobrwhisper_whisper_segment_token_count(ctx: *Context, segment_index: i32) i32;
pub extern fn bobrwhisper_whisper_segment_token(
    ctx: *Context,
    segment_index: i32,
    token_index: i32,
    out: *TokenData,
) void;
/// Token ids at or above this are special and must be excluded from aggregates.
pub extern fn bobrwhisper_whisper_special_token_floor(ctx: *Context) i32;
/// Borrowed from whisper.cpp's static language table; valid for the process
/// lifetime. Null when no language was resolved.
pub extern fn bobrwhisper_whisper_detected_language(ctx: *Context) ?[*:0]const u8;
