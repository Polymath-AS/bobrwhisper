/*
 * Exercises the capture library's C ABI without needing a microphone.
 *
 * Opening a device is only attempted where the platform has a backend, and a
 * failure to open is tolerated: CI has no sound card, and macOS additionally
 * requires a granted microphone permission. What is checked unconditionally is
 * everything that must hold regardless — argument validation, NULL tolerance,
 * error descriptions, and that support is reported consistently with what open
 * actually does.
 */

#include <stdio.h>
#include <string.h>

#include <bobrwhisper/capture.h>

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
    const char *runtime = bobrwhisper_capture_version();
    CHECK(runtime != NULL, "version returned NULL");
    CHECK(strcmp(runtime, BOBRWHISPER_CAPTURE_VERSION_STRING) == 0,
          "runtime version %s != header %s", runtime, BOBRWHISPER_CAPTURE_VERSION_STRING);
}

static void test_error_strings(void) {
    const bobrwhisper_capture_error_e codes[] = {
        BOBRWHISPER_CAPTURE_SUCCESS,
        BOBRWHISPER_CAPTURE_ERROR_INVALID_ARGUMENT,
        BOBRWHISPER_CAPTURE_ERROR_OUT_OF_MEMORY,
        BOBRWHISPER_CAPTURE_ERROR_UNSUPPORTED_PLATFORM,
        BOBRWHISPER_CAPTURE_ERROR_DEVICE_NOT_FOUND,
        BOBRWHISPER_CAPTURE_ERROR_OPEN_FAILED,
        BOBRWHISPER_CAPTURE_ERROR_ALREADY_RUNNING,
        BOBRWHISPER_CAPTURE_ERROR_UNKNOWN,
    };
    for (size_t i = 0; i < sizeof(codes) / sizeof(codes[0]); i++) {
        const char *text = bobrwhisper_capture_error_string(codes[i]);
        CHECK(text != NULL && text[0] != '\0', "code %d has no description", (int) codes[i]);
    }
    const char *unknown = bobrwhisper_capture_error_string((bobrwhisper_capture_error_e) 9001);
    CHECK(unknown != NULL && unknown[0] != '\0', "out-of-range code returned nothing");
}

static void test_null_tolerance(void) {
    CHECK(bobrwhisper_capture_open(NULL, NULL) == BOBRWHISPER_CAPTURE_ERROR_INVALID_ARGUMENT,
          "NULL out_stream accepted");
    CHECK(bobrwhisper_capture_start(NULL) == BOBRWHISPER_CAPTURE_ERROR_INVALID_ARGUMENT,
          "NULL stream accepted by start");
    CHECK(bobrwhisper_capture_list_devices(NULL) == BOBRWHISPER_CAPTURE_ERROR_INVALID_ARGUMENT,
          "NULL out_list accepted");
    CHECK(!bobrwhisper_capture_is_running(NULL), "NULL stream reported running");
    CHECK(bobrwhisper_capture_available(NULL) == 0, "NULL stream reported samples");
    CHECK(bobrwhisper_capture_dropped_samples(NULL) == 0, "NULL stream reported drops");
    CHECK(bobrwhisper_capture_read(NULL, NULL, 0) == 0, "NULL read returned samples");

    bobrwhisper_capture_close(NULL);
    bobrwhisper_capture_stop(NULL);
    bobrwhisper_capture_options_init(NULL);

    bobrwhisper_capture_device_list_s empty;
    empty.devices = NULL;
    empty.count = 0;
    bobrwhisper_capture_free_devices(empty);
}

static void test_options(void) {
    bobrwhisper_capture_options_s options;
    memset(&options, 0xAB, sizeof(options));
    bobrwhisper_capture_options_init(&options);

    CHECK(options.struct_size == sizeof(options), "struct_size not stamped");
    CHECK(options.sample_rate == 16000, "sample_rate was %u", options.sample_rate);
    CHECK(options.channels == 1, "channels was %u", options.channels);
    CHECK(options.device_id == NULL, "device_id should default to NULL");

    bobrwhisper_capture_stream_t *stream = NULL;

    /* A caller built against a different layout must be rejected. */
    options.struct_size = sizeof(options) - 1;
    CHECK(bobrwhisper_capture_open(&options, &stream) ==
              BOBRWHISPER_CAPTURE_ERROR_INVALID_ARGUMENT,
          "stale struct_size accepted");
    CHECK(stream == NULL, "out_stream not cleared on the error path");

    bobrwhisper_capture_options_init(&options);
    options.sample_rate = 0;
    CHECK(bobrwhisper_capture_open(&options, &stream) ==
              BOBRWHISPER_CAPTURE_ERROR_INVALID_ARGUMENT,
          "zero sample_rate accepted");

    bobrwhisper_capture_options_init(&options);
    options.channels = 0;
    CHECK(bobrwhisper_capture_open(&options, &stream) ==
              BOBRWHISPER_CAPTURE_ERROR_INVALID_ARGUMENT,
          "zero channels accepted");
}

static void test_devices(void) {
    bobrwhisper_capture_device_list_s list;
    list.devices = NULL;
    list.count = 12345;
    CHECK(bobrwhisper_capture_list_devices(&list) == BOBRWHISPER_CAPTURE_SUCCESS,
          "list_devices failed");

    for (size_t i = 0; i < list.count; i++) {
        CHECK(list.devices[i].id != NULL, "device %zu has a NULL id", i);
        CHECK(list.devices[i].name != NULL && list.devices[i].name[0] != '\0',
              "device %zu has no name", i);
    }
    if (bobrwhisper_capture_is_supported()) {
        CHECK(list.count >= 1, "a supported platform reported no devices");
    }
    bobrwhisper_capture_free_devices(list);
}

static void test_open_matches_support(void) {
    bobrwhisper_capture_stream_t *stream = NULL;
    const bobrwhisper_capture_error_e err = bobrwhisper_capture_open(NULL, &stream);

    if (!bobrwhisper_capture_is_supported()) {
        CHECK(err == BOBRWHISPER_CAPTURE_ERROR_UNSUPPORTED_PLATFORM,
              "unsupported platform did not say so: %s", bobrwhisper_capture_error_string(err));
        CHECK(stream == NULL, "unsupported open produced a stream");
        return;
    }

    /* Supported: opening may still fail for want of a device, but it must not
     * claim the platform is unsupported. */
    CHECK(err != BOBRWHISPER_CAPTURE_ERROR_UNSUPPORTED_PLATFORM,
          "supported platform reported UNSUPPORTED_PLATFORM");
    if (err != BOBRWHISPER_CAPTURE_SUCCESS) {
        printf("note: no capture device available here (%s); lifecycle checks skipped\n",
               bobrwhisper_capture_error_string(err));
        return;
    }

    CHECK(!bobrwhisper_capture_is_running(stream), "a freshly opened stream is running");
    CHECK(bobrwhisper_capture_available(stream) == 0, "a freshly opened stream has samples");

    if (bobrwhisper_capture_start(stream) == BOBRWHISPER_CAPTURE_SUCCESS) {
        CHECK(bobrwhisper_capture_is_running(stream), "start did not mark the stream running");
        CHECK(bobrwhisper_capture_start(stream) == BOBRWHISPER_CAPTURE_ERROR_ALREADY_RUNNING,
              "starting twice was allowed");

        float samples[256];
        /* May legitimately be 0 this soon; the point is that it does not fault. */
        (void) bobrwhisper_capture_read(stream, samples, 256);

        bobrwhisper_capture_stop(stream);
        CHECK(!bobrwhisper_capture_is_running(stream), "stop did not clear running");
    }
    bobrwhisper_capture_close(stream);
}

int main(void) {
    test_version();
    test_error_strings();
    test_null_tolerance();
    test_options();
    test_devices();
    test_open_matches_support();

    if (failures != 0) {
        printf("%d capture ABI check(s) failed\n", failures);
        return 1;
    }
    printf("bobrwhisper-capture %s: C ABI smoke checks passed (backend %s)\n",
           bobrwhisper_capture_version(),
           bobrwhisper_capture_is_supported() ? "available" : "unsupported on this platform");
    return 0;
}
