pub const ModelRuntime = enum(u8) {
    whisper_cpp = 0,
    coreml = 1,
    onnx = 2,
    server = 3,
};

pub const ModelCapability = enum(u6) {
    transcribe,
    translate,
    stream_partial,
    segment_timestamps,
    word_timestamps,
    summarize_audio,
    audio_qa,
    tool_calling,
    speaker_labels,
};

pub const ModelCapabilities = u64;

pub fn capabilityBit(capability: ModelCapability) ModelCapabilities {
    return @as(ModelCapabilities, 1) << @intFromEnum(capability);
}

pub const ModelDescriptor = struct {
    id: [:0]const u8,
    display_name: [:0]const u8,
    family: [:0]const u8,
    runtime: ModelRuntime,
    local_filename: [:0]const u8,
    download_url: ?[:0]const u8,
    size_bytes: u64,
    capabilities: ModelCapabilities,
    available_on_this_device: bool,
    legacy_storage_key: ?[:0]const u8 = null,
    preferred_live_model_id: ?[:0]const u8 = null,

    pub fn supports(self: ModelDescriptor, capability: ModelCapability) bool {
        return (self.capabilities & capabilityBit(capability)) != 0;
    }
};
