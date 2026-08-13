#ifndef BOBRWHISPER_CAPTURE_H
#define BOBRWHISPER_CAPTURE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Microphone capture, with one interface over per-OS backends: CoreAudio on
 * macOS and iOS, ALSA on Linux. Hosts without a backend yet — Windows — link and
 * load fine and report BOBRWHISPER_CAPTURE_ERROR_UNSUPPORTED_PLATFORM from open,
 * so a consumer gets a diagnosable error rather than a missing symbol. Check
 * bobrwhisper_capture_is_supported to find out up front.
 *
 * The API is polled, not callback-driven, and that is deliberate. A callback
 * would run on the audio thread, where an embedder that blocks, allocates or
 * takes a lock causes dropouts — and across a C ABI there is no way to prevent
 * one from doing exactly that. Instead the backend fills a fixed-size ring and
 * you drain it with bobrwhisper_capture_read whenever it suits you. Falling
 * behind costs you the oldest audio, reported by
 * bobrwhisper_capture_dropped_samples, rather than glitching the recording.
 *
 * Samples are mono 32-bit float at the requested rate, which is what
 * libwhisper consumes. Every function tolerates NULL.
 */

#define BOBRWHISPER_CAPTURE_VERSION_MAJOR 0
#define BOBRWHISPER_CAPTURE_VERSION_MINOR 1
#define BOBRWHISPER_CAPTURE_VERSION_PATCH 0
#define BOBRWHISPER_CAPTURE_VERSION_STRING "0.1.0"

typedef enum {
    BOBRWHISPER_CAPTURE_SUCCESS = 0,
    BOBRWHISPER_CAPTURE_ERROR_INVALID_ARGUMENT = 1,
    BOBRWHISPER_CAPTURE_ERROR_OUT_OF_MEMORY = 2,
    BOBRWHISPER_CAPTURE_ERROR_UNSUPPORTED_PLATFORM = 3,
    BOBRWHISPER_CAPTURE_ERROR_DEVICE_NOT_FOUND = 4,
    BOBRWHISPER_CAPTURE_ERROR_OPEN_FAILED = 5,
    BOBRWHISPER_CAPTURE_ERROR_ALREADY_RUNNING = 6,
    BOBRWHISPER_CAPTURE_ERROR_UNKNOWN = 255,
} bobrwhisper_capture_error_e;

typedef struct {
    /**
     * Must equal sizeof(bobrwhisper_capture_options_s). Set it by calling
     * bobrwhisper_capture_options_init; do not assign it yourself.
     */
    size_t struct_size;
    uint32_t sample_rate;
    uint16_t channels;
    /**
     * How much audio the ring holds. Beyond this the oldest samples are dropped,
     * which is the right failure for live capture: a stalled consumer should lose
     * old audio rather than accumulate unbounded memory.
     */
    uint32_t buffer_ms;
    /** Backend-specific; NULL selects the default input. */
    const char *device_id;
} bobrwhisper_capture_options_s;

typedef struct {
    /** Pass back through bobrwhisper_capture_options_s.device_id. */
    const char *id;
    const char *name;
    bool is_default;
} bobrwhisper_capture_device_s;

typedef struct {
    bobrwhisper_capture_device_s *devices;
    size_t count;
} bobrwhisper_capture_device_list_s;

typedef struct bobrwhisper_capture_stream bobrwhisper_capture_stream_t;

/** The runtime version, which may differ from BOBRWHISPER_CAPTURE_VERSION_STRING. */
const char *bobrwhisper_capture_version(void);

/**
 * A human-readable description. Never returns NULL, and returns a placeholder
 * rather than faulting when given a code this build does not recognize.
 */
const char *bobrwhisper_capture_error_string(bobrwhisper_capture_error_e error);

/** Whether this build has a real backend for the running platform. */
bool bobrwhisper_capture_is_supported(void);

/** Fill options with defaults and stamp struct_size. NULL is a no-op. */
void bobrwhisper_capture_options_init(bobrwhisper_capture_options_s *options);

/**
 * Open the device without starting it. Pass NULL options for the defaults
 * (16 kHz mono, 5 s of buffer, default input).
 */
bobrwhisper_capture_error_e bobrwhisper_capture_open(
    const bobrwhisper_capture_options_s *options,
    bobrwhisper_capture_stream_t **out_stream
);

/** Stops the stream if running, then releases it. NULL is a no-op. */
void bobrwhisper_capture_close(bobrwhisper_capture_stream_t *stream);

/** Begin capturing. Discards anything buffered by a previous run. */
bobrwhisper_capture_error_e bobrwhisper_capture_start(bobrwhisper_capture_stream_t *stream);

/** Stop capturing. Idempotent. */
void bobrwhisper_capture_stop(bobrwhisper_capture_stream_t *stream);

bool bobrwhisper_capture_is_running(bobrwhisper_capture_stream_t *stream);

/**
 * Copy out up to max_samples captured samples, oldest first. Returns how many
 * were written; 0 means nothing has arrived yet, which is not an error.
 */
size_t bobrwhisper_capture_read(
    bobrwhisper_capture_stream_t *stream,
    float *out_samples,
    size_t max_samples
);

/** Samples ready to read. */
size_t bobrwhisper_capture_available(bobrwhisper_capture_stream_t *stream);

/**
 * Samples lost because the consumer did not keep up. Non-zero means read is
 * being called too slowly, or buffer_ms is too small.
 */
uint64_t bobrwhisper_capture_dropped_samples(bobrwhisper_capture_stream_t *stream);

/** Enumerate input devices. Release with bobrwhisper_capture_free_devices. */
bobrwhisper_capture_error_e bobrwhisper_capture_list_devices(
    bobrwhisper_capture_device_list_s *out_list
);

void bobrwhisper_capture_free_devices(bobrwhisper_capture_device_list_s list);

#ifdef __cplusplus
}
#endif

#endif /* BOBRWHISPER_CAPTURE_H */
