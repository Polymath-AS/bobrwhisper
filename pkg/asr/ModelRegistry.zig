const std = @import("std");
const types = @import("types.zig");

pub const ModelDescriptor = types.ModelDescriptor;
pub const ModelRuntime = types.ModelRuntime;
pub const ModelCapability = types.ModelCapability;
pub const capabilityBit = types.capabilityBit;

pub const whisper_tiny_id: [:0]const u8 = "whisper-tiny";
pub const whisper_base_id: [:0]const u8 = "whisper-base";
pub const whisper_small_id: [:0]const u8 = "whisper-small";
pub const whisper_medium_id: [:0]const u8 = "whisper-medium";
pub const whisper_large_v3_id: [:0]const u8 = "whisper-large-v3";
pub const whisper_large_v3_turbo_id: [:0]const u8 = "whisper-large-v3-turbo";

const whisper_capabilities =
    capabilityBit(.transcribe) |
    capabilityBit(.stream_partial);

const descriptors = [_]ModelDescriptor{
    .{
        .id = whisper_tiny_id,
        .display_name = "Whisper Tiny (~75 MB)",
        .family = "whisper",
        .runtime = .whisper_cpp,
        .local_filename = "ggml-tiny.bin",
        .download_url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin",
        .size_bytes = 75 * 1024 * 1024,
        .capabilities = whisper_capabilities,
        .available_on_this_device = true,
        .legacy_storage_key = "tiny",
    },
    .{
        .id = whisper_base_id,
        .display_name = "Whisper Base (~142 MB)",
        .family = "whisper",
        .runtime = .whisper_cpp,
        .local_filename = "ggml-base.bin",
        .download_url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
        .size_bytes = 142 * 1024 * 1024,
        .capabilities = whisper_capabilities,
        .available_on_this_device = true,
        .legacy_storage_key = "base",
    },
    .{
        .id = whisper_small_id,
        .display_name = "Whisper Small (~466 MB)",
        .family = "whisper",
        .runtime = .whisper_cpp,
        .local_filename = "ggml-small.bin",
        .download_url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
        .size_bytes = 466 * 1024 * 1024,
        .capabilities = whisper_capabilities,
        .available_on_this_device = true,
        .legacy_storage_key = "small",
        .preferred_live_model_id = whisper_base_id,
    },
    .{
        .id = whisper_medium_id,
        .display_name = "Whisper Medium (~1.5 GB)",
        .family = "whisper",
        .runtime = .whisper_cpp,
        .local_filename = "ggml-medium.bin",
        .download_url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin",
        .size_bytes = 1500 * 1024 * 1024,
        .capabilities = whisper_capabilities,
        .available_on_this_device = true,
        .legacy_storage_key = "medium",
        .preferred_live_model_id = whisper_base_id,
    },
    .{
        .id = whisper_large_v3_id,
        .display_name = "Whisper Large v3 (~3.1 GB)",
        .family = "whisper",
        .runtime = .whisper_cpp,
        .local_filename = "ggml-large-v3.bin",
        .download_url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin",
        .size_bytes = 3100 * 1024 * 1024,
        .capabilities = whisper_capabilities,
        .available_on_this_device = true,
        .legacy_storage_key = "large",
        .preferred_live_model_id = whisper_base_id,
    },
    .{
        .id = whisper_large_v3_turbo_id,
        .display_name = "Whisper Large Turbo (~809 MB)",
        .family = "whisper",
        .runtime = .whisper_cpp,
        .local_filename = "ggml-large-v3-turbo.bin",
        .download_url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
        .size_bytes = 809 * 1024 * 1024,
        .capabilities = whisper_capabilities,
        .available_on_this_device = true,
        .legacy_storage_key = "large_turbo",
        .preferred_live_model_id = whisper_base_id,
    },
};

pub fn count() usize {
    return descriptors.len;
}

pub fn list() []const ModelDescriptor {
    return descriptors[0..];
}

pub fn descriptorAt(index: usize) ?ModelDescriptor {
    if (index >= descriptors.len) {
        return null;
    }
    return descriptors[index];
}

pub fn findByID(id: []const u8) ?ModelDescriptor {
    for (descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.id, id)) {
            return descriptor;
        }
    }
    return null;
}

pub fn findByLegacyStorageKey(key: []const u8) ?ModelDescriptor {
    for (descriptors) |descriptor| {
        if (descriptor.legacy_storage_key) |legacy_storage_key| {
            if (std.mem.eql(u8, legacy_storage_key, key)) {
                return descriptor;
            }
        }
    }
    return null;
}

pub fn resolveStoredID(value: []const u8) ?[:0]const u8 {
    if (findByID(value)) |descriptor| {
        return descriptor.id;
    }
    if (findByLegacyStorageKey(value)) |descriptor| {
        return descriptor.id;
    }
    return null;
}

pub fn defaultModelID() [:0]const u8 {
    return whisper_small_id;
}

pub fn preferredLiveModel(descriptor: ModelDescriptor) ?ModelDescriptor {
    const live_model_id = descriptor.preferred_live_model_id orelse return null;
    return findByID(live_model_id);
}
