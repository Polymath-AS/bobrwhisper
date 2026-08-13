/*
 * Exercises the audio library's C ABI. Run by `zig build test-audio`.
 *
 * The Zig tests cover the same functions, but only a real C translation unit
 * proves the header compiles as C and that the struct layouts agree.
 */

#include <math.h>
#include <stdio.h>
#include <string.h>

#include <bobrwhisper/audio.h>

static int failures = 0;

#define CHECK(cond, ...)                                \
    do {                                                \
        if (!(cond)) {                                  \
            failures++;                                 \
            printf("FAIL %s:%d: ", __FILE__, __LINE__); \
            printf(__VA_ARGS__);                        \
            printf("\n");                               \
        }                                               \
    } while (0)

static void test_version(void) {
    const char *runtime = bobrwhisper_audio_version();
    CHECK(runtime != NULL, "version returned NULL");
    CHECK(strcmp(runtime, BOBRWHISPER_AUDIO_VERSION_STRING) == 0,
          "runtime version %s != header %s", runtime, BOBRWHISPER_AUDIO_VERSION_STRING);
    CHECK(bobrwhisper_audio_asr_sample_rate() == 16000, "unexpected ASR sample rate");
}

static void test_error_strings(void) {
    const bobrwhisper_audio_error_e codes[] = {
        BOBRWHISPER_AUDIO_SUCCESS,
        BOBRWHISPER_AUDIO_ERROR_INVALID_ARGUMENT,
        BOBRWHISPER_AUDIO_ERROR_OUT_OF_MEMORY,
        BOBRWHISPER_AUDIO_ERROR_NOT_RIFF_WAVE,
        BOBRWHISPER_AUDIO_ERROR_MISSING_CHUNK,
        BOBRWHISPER_AUDIO_ERROR_UNSUPPORTED_FORMAT,
        BOBRWHISPER_AUDIO_ERROR_TRUNCATED_FRAME,
        BOBRWHISPER_AUDIO_ERROR_UNKNOWN,
    };
    for (size_t i = 0; i < sizeof(codes) / sizeof(codes[0]); i++) {
        const char *text = bobrwhisper_audio_error_string(codes[i]);
        CHECK(text != NULL && text[0] != '\0', "code %d has no description", (int) codes[i]);
    }
    /* Out-of-range must be described, not abort the process. */
    const char *unknown = bobrwhisper_audio_error_string((bobrwhisper_audio_error_e) 4242);
    CHECK(unknown != NULL && unknown[0] != '\0', "out-of-range code returned nothing");
}

static void test_null_tolerance(void) {
    bobrwhisper_audio_buffer_s buffer;
    buffer.ptr = (float *) 0x1;
    buffer.len = 99;

    CHECK(bobrwhisper_audio_decode_wav(NULL, 0, 0, &buffer, NULL) ==
              BOBRWHISPER_AUDIO_ERROR_INVALID_ARGUMENT,
          "NULL bytes accepted");
    CHECK(buffer.ptr == NULL && buffer.len == 0, "output not cleared on the error path");

    CHECK(bobrwhisper_audio_decode_wav(NULL, 0, 0, NULL, NULL) ==
              BOBRWHISPER_AUDIO_ERROR_INVALID_ARGUMENT,
          "NULL out_samples accepted");

    bobrwhisper_audio_level_s level = bobrwhisper_audio_measure(NULL, 0);
    CHECK(level.peak == 0.0f && level.rms == 0.0f, "NULL measured non-zero");
    CHECK(bobrwhisper_audio_peak_normalize(NULL, 0, 0.95f) == 1.0f, "NULL normalize changed gain");
    CHECK(!bobrwhisper_audio_detect_voice(NULL, 0, 0.01f), "NULL detected voice");
    CHECK(bobrwhisper_audio_noise_floor(NULL, 0) == 0.0f, "NULL noise floor non-zero");

    bobrwhisper_audio_trim_s trim = bobrwhisper_audio_trim_silence(NULL, 0, 0.01f);
    CHECK(trim.start == 0 && trim.end == 0, "NULL trim returned a range");

    bobrwhisper_audio_buffer_s empty;
    empty.ptr = NULL;
    empty.len = 0;
    bobrwhisper_audio_buffer_free(empty);
    bobrwhisper_audio_chunker_destroy(NULL);
    bobrwhisper_audio_prepare_options_init(NULL);
    bobrwhisper_audio_chunker_reset(NULL);
    CHECK(bobrwhisper_audio_chunker_ready(NULL) == 0, "NULL chunker reported chunks");
}

static void test_empty_result_is_null(void) {
    /* Resampling nothing must not hand back a non-null zero-length pointer. */
    bobrwhisper_audio_buffer_s buffer;
    buffer.ptr = (float *) 0x1;
    buffer.len = 7;
    float nothing[1] = {0.0f};
    CHECK(bobrwhisper_audio_resample(nothing, 0, 48000.0, 16000.0, &buffer) ==
              BOBRWHISPER_AUDIO_SUCCESS,
          "resampling an empty buffer failed");
    CHECK(buffer.ptr == NULL && buffer.len == 0, "empty result was not reported as NULL");
    bobrwhisper_audio_buffer_free(buffer);
}

static void test_conversion(void) {
    /* 48 kHz stereo in, 16 kHz mono out: the capture-path conversion. */
    static float interleaved[960];
    for (size_t i = 0; i < 960; i += 2) {
        interleaved[i] = 0.4f;
        interleaved[i + 1] = 0.6f;
    }

    bobrwhisper_audio_buffer_s out;
    CHECK(bobrwhisper_audio_to_asr_format(interleaved, 960, 2, 48000.0, &out) ==
              BOBRWHISPER_AUDIO_SUCCESS,
          "to_asr_format failed");
    CHECK(out.len == 160, "expected 160 samples, got %zu", out.len);
    if (out.ptr != NULL) {
        CHECK(fabsf(out.ptr[0] - 0.5f) < 0.01f, "channels were not averaged: %f", out.ptr[0]);
    }
    bobrwhisper_audio_buffer_free(out);

    CHECK(bobrwhisper_audio_to_asr_format(interleaved, 960, 0, 48000.0, &out) ==
              BOBRWHISPER_AUDIO_ERROR_INVALID_ARGUMENT,
          "zero channels accepted");
}

static void test_level_and_prepare(void) {
    static float samples[32000];
    memset(samples, 0, sizeof(samples));
    for (size_t i = 16000; i < 16800; i++) samples[i] = 0.05f;

    bobrwhisper_audio_level_s level = bobrwhisper_audio_measure(samples, 32000);
    CHECK(fabsf(level.peak - 0.05f) < 0.0001f, "peak was %f", level.peak);

    bobrwhisper_audio_prepare_options_s options;
    bobrwhisper_audio_prepare_options_init(&options);
    CHECK(options.struct_size == sizeof(options), "struct_size not stamped");
    CHECK(options.normalize, "normalize should default on");

    bobrwhisper_audio_prepared_s result;
    CHECK(bobrwhisper_audio_prepare_for_asr(samples, 32000, &options, &result) ==
              BOBRWHISPER_AUDIO_SUCCESS,
          "prepare_for_asr failed");
    CHECK(result.gain > 1.0f, "quiet input was not boosted (gain %f)", result.gain);
    CHECK(result.bounds.end > result.bounds.start, "empty speech range");
    CHECK(result.bounds.end <= 32000, "range past the end of the buffer");

    /* A caller built against a different layout must be rejected. */
    options.struct_size = sizeof(options) - 1;
    CHECK(bobrwhisper_audio_prepare_for_asr(samples, 32000, &options, &result) ==
              BOBRWHISPER_AUDIO_ERROR_INVALID_ARGUMENT,
          "stale struct_size accepted");
}

static void test_chunker(void) {
    bobrwhisper_audio_chunker_t *chunker = NULL;
    CHECK(bobrwhisper_audio_chunker_create(4, 4, &chunker) ==
              BOBRWHISPER_AUDIO_ERROR_INVALID_ARGUMENT,
          "overlap == chunk_len accepted");
    CHECK(bobrwhisper_audio_chunker_create(0, 0, &chunker) ==
              BOBRWHISPER_AUDIO_ERROR_INVALID_ARGUMENT,
          "zero chunk_len accepted");
    CHECK(bobrwhisper_audio_chunker_create(4, 2, &chunker) == BOBRWHISPER_AUDIO_SUCCESS,
          "chunker_create failed");
    if (chunker == NULL) return;

    const float samples[6] = {1, 2, 3, 4, 5, 6};
    CHECK(bobrwhisper_audio_chunker_push(chunker, samples, 6) == BOBRWHISPER_AUDIO_SUCCESS,
          "chunker_push failed");

    const size_t expected = bobrwhisper_audio_chunker_ready(chunker);
    size_t seen = 0;
    const float *chunk = NULL;
    size_t chunk_len = 0;
    while (bobrwhisper_audio_chunker_next(chunker, &chunk, &chunk_len)) {
        CHECK(chunk_len == 4, "chunk was %zu samples", chunk_len);
        seen++;
    }
    CHECK(seen == expected, "ready() said %zu, next() yielded %zu", expected, seen);

    bobrwhisper_audio_chunker_reset(chunker);
    CHECK(bobrwhisper_audio_chunker_ready(chunker) == 0, "reset left chunks behind");
    bobrwhisper_audio_chunker_destroy(chunker);
}

int main(void) {
    test_version();
    test_error_strings();
    test_null_tolerance();
    test_empty_result_is_null();
    test_conversion();
    test_level_and_prepare();
    test_chunker();

    if (failures != 0) {
        printf("%d audio ABI check(s) failed\n", failures);
        return 1;
    }
    printf("bobrwhisper-audio %s: C ABI smoke checks passed\n", bobrwhisper_audio_version());
    return 0;
}
