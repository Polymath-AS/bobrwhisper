#ifndef LIBWHISPER_H
#define LIBWHISPER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * libwhisper is BobrWhisper's embeddable, UI-independent transcription
 * library. Audio passed to this API must be mono 32-bit float PCM at 16 kHz.
 *
 * The shared library is installed as libbobrwhisper.so / libbobrwhisper.dylib
 * to avoid colliding with whisper.cpp's own libwhisper; the API keeps the
 * libwhisper_ prefix, which does not collide with whisper.cpp's whisper_.
 *
 * Threading: a single transcriber is not safe for concurrent use, except for
 * libwhisper_cancel, which may be called from any thread. Separate
 * transcribers may be used concurrently from different threads;
 * libwhisper_create serializes internally.
 */

#define LIBWHISPER_VERSION_MAJOR 0
#define LIBWHISPER_VERSION_MINOR 1
#define LIBWHISPER_VERSION_PATCH 0
#define LIBWHISPER_VERSION_STRING "0.1.0"

/** Encodes a version for comparison, e.g. LIBWHISPER_VERSION_AT_LEAST(0, 2, 0). */
#define LIBWHISPER_VERSION_NUMBER(major, minor, patch) \
    ((major) * 10000 + (minor) * 100 + (patch))
#define LIBWHISPER_VERSION_AT_LEAST(major, minor, patch)     \
    (LIBWHISPER_VERSION_NUMBER(LIBWHISPER_VERSION_MAJOR,     \
                               LIBWHISPER_VERSION_MINOR,     \
                               LIBWHISPER_VERSION_PATCH) >=  \
     LIBWHISPER_VERSION_NUMBER(major, minor, patch))

typedef struct libwhisper libwhisper_t;

typedef enum {
    LIBWHISPER_SUCCESS = 0,
    LIBWHISPER_ERROR_INVALID_ARGUMENT = 1,
    LIBWHISPER_ERROR_OUT_OF_MEMORY = 2,
    LIBWHISPER_ERROR_MODEL_NOT_FOUND = 3,
    LIBWHISPER_ERROR_MODEL_LOAD_FAILED = 4,
    LIBWHISPER_ERROR_NO_AUDIO = 5,
    LIBWHISPER_ERROR_TRANSCRIPTION_FAILED = 6,
    LIBWHISPER_ERROR_CANCELLED = 7,
    LIBWHISPER_ERROR_UNKNOWN = 255,
} libwhisper_error_e;

/** Mirrors Zig's std.log levels; the ordering is err < warn < info < debug. */
typedef enum {
    LIBWHISPER_LOG_ERROR = 0,
    LIBWHISPER_LOG_WARN = 1,
    LIBWHISPER_LOG_INFO = 2,
    LIBWHISPER_LOG_DEBUG = 3,
} libwhisper_log_level_e;

typedef struct {
    /**
     * Must equal sizeof(libwhisper_config_s). Set it by calling
     * libwhisper_config_init; do not assign it yourself. It lets a later
     * libwhisper detect a caller compiled against an older struct instead of
     * reading past the end of it.
     */
    size_t struct_size;
    const char *model_path;
    const char *language;
    uint32_t thread_count;
    bool use_gpu;
    bool vad_enabled;
    const char *vad_model_path;
    float vad_threshold;
    int32_t vad_min_speech_ms;
    int32_t vad_min_silence_ms;
    int32_t vad_speech_pad_ms;
    const char *initial_prompt;
} libwhisper_config_s;

typedef struct {
    const char *language;
    bool single_segment;
} libwhisper_transcribe_options_s;

typedef struct {
    /** NUL-terminated, or NULL when the transcript is empty. */
    char *ptr;
    /** Length excluding the NUL terminator. */
    size_t len;
} libwhisper_string_s;

/**
 * Called for messages the library would otherwise have to drop. `message` is
 * only valid for the duration of the call. The handler may be invoked from any
 * thread libwhisper is running on, and must not call back into libwhisper.
 */
typedef void (*libwhisper_log_handler_f)(
    int level,
    const char *message,
    void *user_data
);

/**
 * Fill a configuration with stable defaults and stamp struct_size. model_path
 * must still be set. Passing NULL is a no-op.
 */
void libwhisper_config_init(libwhisper_config_s *config);

/**
 * Load a model and create a transcriber. On failure *out_transcriber is set to
 * NULL and nothing needs to be released.
 */
libwhisper_error_e libwhisper_create(
    const libwhisper_config_s *config,
    libwhisper_t **out_transcriber
);

/** Releases the transcriber. Passing NULL is a no-op. */
void libwhisper_destroy(libwhisper_t *transcriber);

/**
 * Transcribe 16 kHz mono float PCM.
 *
 * On success out_text owns its buffer and must be released with
 * libwhisper_string_free, passed back exactly as it was received. The buffer is
 * NUL-terminated, so it can be used with printf("%s") and strlen. An empty
 * transcript — silence, or audio VAD rejected — is reported as success with
 * out_text->ptr == NULL and out_text->len == 0, which needs no release.
 *
 * out_text is cleared before any work starts, so it is safe to inspect after
 * any return value.
 */
libwhisper_error_e libwhisper_transcribe(
    libwhisper_t *transcriber,
    const float *samples,
    size_t sample_count,
    const libwhisper_transcribe_options_s *options,
    libwhisper_string_s *out_text
);

/**
 * Ask an in-flight libwhisper_transcribe to stop. Safe to call from another
 * thread; the transcribe call returns LIBWHISPER_ERROR_CANCELLED shortly after.
 * The flag is cleared at the start of each transcribe, so cancelling while idle
 * does not affect the next call. Passing NULL is a no-op.
 */
void libwhisper_cancel(libwhisper_t *transcriber);

libwhisper_error_e libwhisper_set_initial_prompt(
    libwhisper_t *transcriber,
    const char *prompt
);

/**
 * Install a process-wide log handler. libwhisper writes nothing to stderr on
 * its own; without a handler diagnostics are dropped. Pass NULL to uninstall.
 */
void libwhisper_set_log_handler(
    libwhisper_log_handler_f handler,
    void *user_data
);

/** Releases a buffer produced by libwhisper_transcribe. NULL ptr is a no-op. */
void libwhisper_string_free(libwhisper_string_s string);

/**
 * A human-readable description. Never returns NULL, and returns a placeholder
 * rather than faulting when given a code this build does not recognize.
 */
const char *libwhisper_error_string(libwhisper_error_e error);

/** The runtime version, which may differ from LIBWHISPER_VERSION_STRING. */
const char *libwhisper_version(void);

#ifdef __cplusplus
}
#endif

#endif /* LIBWHISPER_H */
