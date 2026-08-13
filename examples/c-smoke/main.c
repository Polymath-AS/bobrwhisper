/*
 * Exercises the parts of the libwhisper C ABI that need no model file. Run by
 * `zig build test-libwhisper`, because the Zig tests cannot catch header/ABI
 * drift or the pointer traps that only a C caller hits.
 */

#include <stdio.h>
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

static void test_transcribe_argument_checks(void) {
    const float samples[2] = {0.0f, 0.25f};
    /* Poison the output so we can prove it is cleared before any work. */
    libwhisper_string_s text;
    text.ptr = (char *) 0x1;
    text.len = 123;

    CHECK(libwhisper_transcribe(NULL, samples, 2, NULL, &text) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "NULL transcriber was accepted");
    CHECK(text.ptr == NULL && text.len == 0, "out_text must be cleared on the error path");

    /* NULL out_text must be rejected rather than dereferenced. */
    CHECK(libwhisper_transcribe(NULL, samples, 2, NULL, NULL) == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "NULL out_text was accepted");
}

static void test_null_tolerance(void) {
    libwhisper_destroy(NULL);
    libwhisper_cancel(NULL);
    libwhisper_string_s empty;
    empty.ptr = NULL;
    empty.len = 0;
    libwhisper_string_free(empty);
    CHECK(libwhisper_set_initial_prompt(NULL, "x") == LIBWHISPER_ERROR_INVALID_ARGUMENT,
          "NULL transcriber was accepted by set_initial_prompt");
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
    test_transcribe_argument_checks();
    test_null_tolerance();

    CHECK(log_calls > 0, "a failing libwhisper_create logged nothing to the handler");
    libwhisper_set_log_handler(NULL, NULL);

    if (failures != 0) {
        printf("%d libwhisper C ABI check(s) failed\n", failures);
        return 1;
    }
    printf("libwhisper %s: C ABI smoke checks passed\n", libwhisper_version());
    return 0;
}
