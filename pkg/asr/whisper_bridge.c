#include <stdbool.h>
#include <stdint.h>

#include "whisper.h"

static void bobrwhisper_whisper_null_log_callback(enum ggml_log_level level, const char * text, void * user_data) {
    (void) level;
    (void) text;
    (void) user_data;
}

void bobrwhisper_whisper_disable_logging(void) {
    whisper_log_set(bobrwhisper_whisper_null_log_callback, NULL);
}

struct whisper_context * bobrwhisper_whisper_init(const char * model_path, bool use_gpu) {
    struct whisper_context_params params = whisper_context_default_params();
    params.use_gpu = use_gpu;
    return whisper_init_from_file_with_params(model_path, params);
}

void bobrwhisper_whisper_free(struct whisper_context * ctx) {
    whisper_free(ctx);
}

int bobrwhisper_whisper_transcribe(
    struct whisper_context * ctx,
    const float * samples,
    int32_t sample_count,
    const char * language,
    int32_t n_threads,
    bool live,
    bool vad_enabled,
    const char * vad_model_path,
    float vad_threshold,
    int32_t vad_min_speech_ms,
    int32_t vad_min_silence_ms,
    int32_t vad_speech_pad_ms
) {
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.no_timestamps = true;
    params.n_threads = n_threads;

    if (live) {
        params.single_segment = true;
        params.no_context = true;
    }

    params.vad = vad_enabled;
    params.vad_model_path = vad_model_path;
    params.vad_params.threshold = vad_threshold;
    params.vad_params.min_speech_duration_ms = vad_min_speech_ms;
    params.vad_params.min_silence_duration_ms = vad_min_silence_ms;
    params.vad_params.speech_pad_ms = vad_speech_pad_ms;

    if (language != NULL && language[0] != '\0') {
        params.language = language;
    }

    return whisper_full(ctx, params, samples, sample_count);
}

int32_t bobrwhisper_whisper_segment_count(struct whisper_context * ctx) {
    return whisper_full_n_segments(ctx);
}

const char * bobrwhisper_whisper_segment_text(struct whisper_context * ctx, int32_t segment_index) {
    return whisper_full_get_segment_text(ctx, segment_index);
}
