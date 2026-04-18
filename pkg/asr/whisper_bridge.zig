pub const Context = opaque {};

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
    vad_enabled: bool,
    vad_model_path: ?[*:0]const u8,
    vad_threshold: f32,
    vad_min_speech_ms: i32,
    vad_min_silence_ms: i32,
    vad_speech_pad_ms: i32,
) c_int;
pub extern fn bobrwhisper_whisper_segment_count(ctx: *Context) i32;
pub extern fn bobrwhisper_whisper_segment_text(ctx: *Context, segment_index: i32) ?[*:0]const u8;
