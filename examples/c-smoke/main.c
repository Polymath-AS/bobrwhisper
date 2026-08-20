/*
 * Exercises the parts of the libwhisper C ABI that need no model file. Run by
 * `zig build test-libwhisper`, because the Zig tests cannot catch header/ABI
 * drift or the pointer traps that only a C caller hits.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libwhisper.h>

static int failures = 0;

#define CHECK(cond, ...)                                   \
    do {                                                   \
        if (!(cond)) {                                     \
            failures++;                                    \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);    \
            printf(__VA_ARGS__);                           \
            printf("\n");                                  \
        }                                                  \
    } while (0)

static int log_calls = 0;

static void capture_log(int level, const char *message, void *user_data) {
    (void) level;
    CHECK(message != NULL, "log handler got a NULL message");
    CHECK(user_data == &log_calls, "log handler got the wrong user_data");
    log_calls++;
}

static void test_version(void) {
    const char *runtime = libwhisper_version();
    CHECK(runtime != NULL, "libwhisper_version returned NULL");
    CHECK(strcmp(runtime, LIBWHISPER_VERSION_STRING) == 0,
          "runtime version %s != header version %s", runtime, LIBWHISPER_VERSION_STRING);
#if !LIBWHISPER_VERSION_AT_LEAST(0, 1, 0)
#error "LIBWHISPER_VERSION_AT_LEAST is broken"
#endif
}

static void test_config_defaults(void) {
    libwhisper_config_s config;
    memset(&config, 0xAB, sizeof(config));
    libwhisper_config_init(&config);
    CHECK(config.struct_size == sizeof(config),
          "struct_size %zu != sizeof %zu", config.struct_size, sizeof(config));
    CHECK(config.model_path == NULL, "model_path should start unset");
    CHECK(config.thread_count == 4, "thread_count was %u", config.thread_count);
    CHECK(config.use_gpu, "use_gpu should default on");
    libwhisper_config_init(NULL); /* must not crash */
}

static void test_error_strings(void) {
    /* Every declared code must have a description. */
    const libwhisper_error_e codes[] = {
        LIBWHISPER_SUCCESS,
        LIBWHISPER_ERROR_INVALID_ARGUMENT,
        LIBWHISPER_ERROR_OUT_OF_MEMORY,
        LIBWHISPER_ERROR_MODEL_NOT_FOUND,
        LIBWHISPER_ERROR_MODEL_LOAD_FAILED,
        LIBWHISPER_ERROR_NO_AUDIO,
        LIBWHISPER_ERROR_TRANSCRIPTION_FAILED,
        LIBWHISPER_ERROR_CANCELLED,
        LIBWHISPER_ERROR_UNKNOWN,
    };
    for (size_t i = 0; i < sizeof(codes) / sizeof(codes[0]); i++) {
        const char *text = libwhisper_error_string(codes[i]);
        CHECK(text != NULL && text[0] != '\0', "code %d has no description", (int) codes[i]);
    }

    /* The regression this guards: an exhaustive switch aborted the process for
     * any value outside the enum, which C callers can trivially produce. */
    const char *unknown = libwhisper_error_string((libwhisper_error_e) 42);
    CHECK(unknown != NULL && unknown[0] != '\0', "out-of-range code returned no description");
}

static void test_create_rejects_bad_config(void) {
    libwhisper_t *transcriber = (libwhisper_t *) 0x1;
    CHECK(libwhisper_create(NULL, &transcriber) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "NULL config was accepted");
    CHECK(transcriber == NULL, "out_transcriber must be cleared on failure");

    libwhisper_config_s config;
    libwhisper_config_init(&config);
    CHECK(libwhisper_create(&config, &transcriber) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "missing model_path was accepted");

    libwhisper_config_init(&config);
    config.model_path = "/nonexistent/libwhisper-smoke-model.bin";
    config.struct_size = sizeof(config) - 1;
    CHECK(libwhisper_create(&config, &transcriber) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "a stale struct_size was accepted");

    libwhisper_config_init(&config);
    config.model_path = "/nonexistent/libwhisper-smoke-model.bin";
    CHECK(libwhisper_create(&config, &transcriber) == LIBWHISPER_ERROR_MODEL_NOT_FOUND,
          "a missing model should report MODEL_NOT_FOUND");
    CHECK(transcriber == NULL, "out_transcriber must be cleared on failure");
}

static void test_transcribe_options_defaults(void) {
    libwhisper_transcribe_options_s options;
    memset(&options, 0xAB, sizeof(options));
    libwhisper_transcribe_options_init(&options);
    CHECK(options.struct_size == sizeof(options),
          "struct_size %zu != sizeof %zu", options.struct_size, sizeof(options));
    CHECK(options.language == NULL, "language should start unset");
    CHECK(!options.single_segment, "single_segment should default off");
    /* Timestamps cost decode time and change the transcript, so they are opt-in. */
    CHECK(!options.timestamps, "timestamps should default off");
    libwhisper_transcribe_options_init(NULL); /* must not crash */
}

static void test_transcribe_argument_checks(void) {
    const float samples[2] = {0.0f, 0.25f};
    /* Poison the output so we can prove it is cleared before any work. */
    libwhisper_result_t *result = (libwhisper_result_t *) 0x1;

    CHECK(libwhisper_transcribe(NULL, samples, 2, NULL, &result) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "NULL transcriber was accepted");
    CHECK(result == NULL, "out_result must be cleared on the error path");

    /* NULL out_result must be rejected rather than dereferenced. */
    CHECK(libwhisper_transcribe(NULL, samples, 2, NULL, NULL) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "NULL out_result was accepted");

    /* A caller compiled against a different options layout must be rejected. */
    libwhisper_transcribe_options_s stale;
    libwhisper_transcribe_options_init(&stale);
    stale.struct_size = sizeof(stale) - 1;
    result = (libwhisper_result_t *) 0x1;
    CHECK(libwhisper_transcribe(NULL, samples, 2, &stale, &result) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "a stale options struct_size was accepted");
    CHECK(result == NULL, "out_result must be cleared on the error path");
}

/*
 * Every result accessor has to survive a handle it did not produce, because a C
 * caller reaching them after a free is the failure mode, not a hypothetical.
 * NULL is the only invalid handle that can be checked portably; a freed one is
 * undefined by contract and deliberately not exercised here.
 */
static void test_result_accessors_reject_null(void) {
    size_t bytes = 123;
    CHECK(libwhisper_result_text(NULL, &bytes) == NULL, "text of a NULL result was not NULL");
    CHECK(bytes == 0, "out_bytes must be cleared for a NULL result");
    CHECK(libwhisper_result_text(NULL, NULL) == NULL, "NULL out_bytes was not tolerated");
    CHECK(libwhisper_result_segment_count(NULL) == 0, "NULL result reported segments");

    libwhisper_result_summary_s summary;
    summary.struct_size = sizeof(summary);
    CHECK(libwhisper_result_summary(NULL, &summary) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "summary of a NULL result was accepted");
    CHECK(libwhisper_result_summary(NULL, NULL) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "NULL out_summary was accepted");

    libwhisper_segment_s segment;
    segment.struct_size = sizeof(segment);
    CHECK(libwhisper_result_segment(NULL, 0, &segment) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "segment of a NULL result was accepted");
    CHECK(libwhisper_result_segment(NULL, 0, NULL) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "NULL out_segment was accepted");
}

static void test_metric_absence_macro(void) {
    /* The header's absent-metric contract, spelled the way callers will use it.
     * A NaN threshold test must fall to the suspicious branch, not the happy
     * one, or every model that omits a metric silently reads as confident. */
    libwhisper_result_summary_s summary;
    memset(&summary, 0, sizeof(summary));
    summary.average_logprobability = 0.0f / 0.0f;
    CHECK(LIBWHISPER_METRIC_IS_ABSENT(summary.average_logprobability),
          "NaN was not detected as an absent metric");
    CHECK(!LIBWHISPER_METRIC_IS_ABSENT(-0.5f), "a real metric was reported absent");
    CHECK(!(summary.average_logprobability > -1.0f),
          "an absent metric must not satisfy a confidence threshold");
}

static void test_null_tolerance(void) {
    libwhisper_destroy(NULL);
    libwhisper_cancel(NULL);
    libwhisper_result_free(NULL);
    CHECK(libwhisper_set_initial_prompt(NULL, "x") == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "NULL transcriber was accepted by set_initial_prompt");
}

/*
 * Everything above reaches libwhisper_create only on paths that fail before
 * whisper.cpp is entered, which left a real gap: a ReleaseSafe build used to
 * trap inside ggml the moment a model was actually loaded, and every check here
 * still passed. Set LIBWHISPER_TEST_MODEL to a model file to cover it.
 */
static void test_real_model(const char *model_path) {
    libwhisper_config_s config;
    libwhisper_config_init(&config);
    config.model_path = model_path;
    config.use_gpu = false;

    libwhisper_t *transcriber = NULL;
    const libwhisper_error_e create_error = libwhisper_create(&config, &transcriber);
    CHECK(create_error == LIBWHISPER_SUCCESS, "libwhisper_create(%s) failed: %s", model_path,
          libwhisper_error_string(create_error));
    if (create_error != LIBWHISPER_SUCCESS) return;

    /* One second of silence: enough to build and run a ggml graph, and the case
     * where the evidence matters most — whatever text comes back, the model
     * should not be reporting confident speech. */
    static float samples[16000];
    const size_t sample_count = sizeof(samples) / sizeof(samples[0]);

    libwhisper_result_t *result = NULL;
    const libwhisper_error_e error =
        libwhisper_transcribe(transcriber, samples, sample_count, NULL, &result);
    CHECK(error == LIBWHISPER_SUCCESS, "libwhisper_transcribe failed: %s",
          libwhisper_error_string(error));
    if (error != LIBWHISPER_SUCCESS) {
        CHECK(result == NULL, "a failed transcribe must not hand back a result");
        libwhisper_destroy(transcriber);
        return;
    }

    /* Success always yields a result, even for silence. That is the whole point
     * of the ownership rule: no null check before reading a transcript. */
    CHECK(result != NULL, "a successful transcribe must always yield a result");
    if (result == NULL) {
        libwhisper_destroy(transcriber);
        return;
    }

    size_t text_bytes = 0;
    const char *text = libwhisper_result_text(result, &text_bytes);
    CHECK(text != NULL, "result text must never be NULL");
    CHECK(text != NULL && text[text_bytes] == '\0', "transcript is not NUL-terminated at len");
    CHECK(text != NULL && strlen(text) == text_bytes,
          "strlen %zu disagrees with reported %zu", text != NULL ? strlen(text) : 0, text_bytes);

    libwhisper_result_summary_s summary;
    summary.struct_size = sizeof(summary);
    const libwhisper_error_e summary_error = libwhisper_result_summary(result, &summary);
    CHECK(summary_error == LIBWHISPER_SUCCESS, "libwhisper_result_summary failed: %s",
          libwhisper_error_string(summary_error));
    CHECK(summary.text_bytes == text_bytes, "summary text_bytes %zu != %zu",
          summary.text_bytes, text_bytes);
    CHECK(summary.segment_count == libwhisper_result_segment_count(result),
          "summary and accessor disagree on segment count");
    CHECK(summary.language != NULL, "summary language must never be NULL");

    /* A stale out-struct is rejected rather than partially filled. */
    libwhisper_result_summary_s stale_summary;
    stale_summary.struct_size = sizeof(stale_summary) - 1;
    CHECK(libwhisper_result_summary(result, &stale_summary) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "a stale summary struct_size was accepted");

    /* Segment ranges must stay inside the text buffer and tile it in order. */
    size_t covered = 0;
    for (size_t i = 0; i < summary.segment_count; i++) {
        libwhisper_segment_s segment;
        segment.struct_size = sizeof(segment);
        const libwhisper_error_e segment_error = libwhisper_result_segment(result, i, &segment);
        CHECK(segment_error == LIBWHISPER_SUCCESS, "segment %zu failed: %s", i,
              libwhisper_error_string(segment_error));
        if (segment_error != LIBWHISPER_SUCCESS) continue;
        CHECK(segment.text_offset == covered,
              "segment %zu starts at %zu, expected %zu", i, segment.text_offset, covered);
        CHECK(segment.text_offset + segment.text_bytes <= text_bytes,
              "segment %zu range runs past the transcript", i);
        /* Timestamps were not requested, so they must say absent rather than
         * hand back the decode window and pass it off as speech bounds. */
        CHECK(segment.start_ms == LIBWHISPER_TIME_ABSENT && segment.end_ms == LIBWHISPER_TIME_ABSENT,
              "segment %zu reported timestamps that were never requested", i);
        covered = segment.text_offset + segment.text_bytes;
    }
    CHECK(covered == text_bytes, "segments cover %zu of %zu transcript bytes", covered, text_bytes);

    /* One past the end is an error, not a read of adjacent memory. */
    libwhisper_segment_s out_of_range;
    out_of_range.struct_size = sizeof(out_of_range);
    CHECK(libwhisper_result_segment(result, summary.segment_count, &out_of_range) ==
              LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "an out-of-range segment index was accepted");
    out_of_range.struct_size = sizeof(out_of_range);
    CHECK(libwhisper_result_segment(result, (size_t) -1, &out_of_range) ==
              LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "SIZE_MAX as a segment index was accepted");

    libwhisper_result_free(result);

    /* Asking for timestamps must fill them in. Same audio, so this also shows
     * the option reaching the decoder rather than being ignored. */
    libwhisper_transcribe_options_s timed;
    libwhisper_transcribe_options_init(&timed);
    timed.timestamps = true;
    libwhisper_result_t *timed_result = NULL;
    const libwhisper_error_e timed_error =
        libwhisper_transcribe(transcriber, samples, sample_count, &timed, &timed_result);
    CHECK(timed_error == LIBWHISPER_SUCCESS, "timestamped transcribe failed: %s",
          libwhisper_error_string(timed_error));
    if (timed_error == LIBWHISPER_SUCCESS) {
        const size_t segment_count = libwhisper_result_segment_count(timed_result);
        for (size_t i = 0; i < segment_count; i++) {
            libwhisper_segment_s segment;
            segment.struct_size = sizeof(segment);
            if (libwhisper_result_segment(timed_result, i, &segment) != LIBWHISPER_SUCCESS) continue;
            CHECK(segment.start_ms != LIBWHISPER_TIME_ABSENT,
                  "segment %zu has no start time despite timestamps being requested", i);
            CHECK(segment.end_ms >= segment.start_ms,
                  "segment %zu ends (%lld) before it starts (%lld)", i,
                  (long long) segment.end_ms, (long long) segment.start_ms);
        }
        libwhisper_result_free(timed_result);
    }

    /* Cancelling while idle must not affect the next call, and must never leave
     * a partial result behind. */
    libwhisper_cancel(transcriber);
    libwhisper_result_t *after_cancel = NULL;
    const libwhisper_error_e cancel_error =
        libwhisper_transcribe(transcriber, samples, sample_count, NULL, &after_cancel);
    CHECK(cancel_error == LIBWHISPER_SUCCESS || cancel_error == LIBWHISPER_ERROR_CANCELLED,
          "unexpected error after an idle cancel: %s", libwhisper_error_string(cancel_error));
    CHECK(cancel_error == LIBWHISPER_SUCCESS || after_cancel == NULL,
          "a cancelled transcribe must not hand back a partial result");
    libwhisper_result_free(after_cancel);

    libwhisper_destroy(transcriber);
}

int main(void) {
    /* Installed first so the failing-create tests below double as proof that
     * diagnostics reach the handler instead of the embedder's stderr. This can
     * only be checked from a C caller: std_options applies to the shipped
     * library, where libwhisper.zig is the compilation root, not to `zig test`. */
    libwhisper_set_log_handler(capture_log, &log_calls);

    test_version();
    test_config_defaults();
    test_error_strings();
    test_create_rejects_bad_config();
    test_transcribe_options_defaults();
    test_transcribe_argument_checks();
    test_result_accessors_reject_null();
    test_metric_absence_macro();
    test_null_tolerance();

    CHECK(log_calls > 0, "a failing libwhisper_create logged nothing to the handler");

    const char *model_path = getenv("LIBWHISPER_TEST_MODEL");
    if (model_path != NULL && model_path[0] != '\0') {
        test_real_model(model_path);
    } else {
        printf("note: set LIBWHISPER_TEST_MODEL to also load a model and transcribe\n");
    }

    libwhisper_set_log_handler(NULL, NULL);

    if (failures != 0) {
        printf("%d libwhisper C ABI check(s) failed\n", failures);
        return 1;
    }
    printf("libwhisper %s: C ABI smoke checks passed\n", libwhisper_version());
    return 0;
}
