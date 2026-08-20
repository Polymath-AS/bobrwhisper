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
#define LIBWHISPER_VERSION_MINOR 2
#define LIBWHISPER_VERSION_PATCH 0
#define LIBWHISPER_VERSION_STRING "0.2.0"

/** Encodes a version for comparison, e.g. LIBWHISPER_VERSION_AT_LEAST(0, 3, 0). */
#define LIBWHISPER_VERSION_NUMBER(major, minor, patch) \
    ((major) * 10000 + (minor) * 100 + (patch))
#define LIBWHISPER_VERSION_AT_LEAST(major, minor, patch)     \
    (LIBWHISPER_VERSION_NUMBER(LIBWHISPER_VERSION_MAJOR,     \
                               LIBWHISPER_VERSION_MINOR,     \
                               LIBWHISPER_VERSION_PATCH) >=  \
     LIBWHISPER_VERSION_NUMBER(major, minor, patch))

typedef struct libwhisper libwhisper_t;

/**
 * One completed transcription: the text plus the evidence the model produced
 * while decoding it. Owned by the caller, immutable, and independent of the
 * transcriber that produced it — starting the next transcription cannot
 * invalidate it, and it may be read from a different thread than the one
 * transcribing. Release with libwhisper_result_free.
 */
typedef struct libwhisper_result libwhisper_result_t;

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
    /**
     * Must equal sizeof(libwhisper_transcribe_options_s). Set it by calling
     * libwhisper_transcribe_options_init; do not assign it yourself.
     */
    size_t struct_size;
    /** Overrides the language given at create time. NULL or "" keeps it. */
    const char *language;
    /** Decode as one segment with no cross-segment context, for live chunks. */
    bool single_segment;
    /**
     * Ask the decoder for timestamps, which fills start_ms/end_ms on each
     * segment. This is not free reporting: emitting timestamp tokens costs
     * decode time and changes where segments are split, so the transcript text
     * for the same audio differs from a run with this off. Leave it off unless
     * you need the times.
     */
    bool timestamps;
} libwhisper_transcribe_options_s;

/**
 * Values a model may or may not have produced. An absent float metric is NaN,
 * never zero: zero is a meaningful, maximally-confident value for a log
 * probability, so substituting it would silently invert a threshold test.
 *
 * NaN compares false against everything, so spell confidence tests to fail
 * toward suspicion rather than acceptance — write
 *
 *     if (!(summary.average_logprobability > threshold)) { ask_the_user(); }
 *
 * so a missing metric routes to the same branch as a bad one.
 */
#define LIBWHISPER_METRIC_IS_ABSENT(value) ((value) != (value))

/** An absent timestamp. Negative, because a real one never is. */
#define LIBWHISPER_TIME_ABSENT ((int64_t) -1)

typedef struct {
    /** Must equal sizeof(libwhisper_result_summary_s); set it before calling. */
    size_t struct_size;

    /** Length of libwhisper_result_text, excluding its NUL terminator. */
    size_t text_bytes;
    size_t segment_count;

    /**
     * Language the model reports having decoded, e.g. "en"; "" when it reported
     * none. Never NULL. Borrowed from the result. This is the decoded language,
     * not the requested one, so it is the field to read when the request left
     * the language unset.
     */
    const char *language;

    /**
     * Mean log probability over every non-special token in the transcript,
     * token-weighted. Uniformly weak decoding shows up here.
     */
    float average_logprobability;
    /**
     * The least likely single token anywhere in the transcript. This is what
     * separates one misheard word from a transcript that is weak throughout.
     */
    float minimum_token_probability;
    /**
     * The strongest no-speech evidence any segment produced, i.e. the maximum
     * over segments. Walk the segments to find out which one.
     *
     * This is the probability the model assigned to its own no-speech token,
     * and on some models it is a weak signal: measured on large-v3-turbo, three
     * seconds of digital silence and three seconds of speech both report about
     * 2e-05, while their average log probabilities differ by a factor of six.
     * Treat it as one input among several rather than a silence detector.
     */
    float no_speech_probability;
} libwhisper_result_summary_s;

typedef struct {
    /** Must equal sizeof(libwhisper_segment_s); set it before calling. */
    size_t struct_size;

    /** Byte range of this segment inside libwhisper_result_text. */
    size_t text_offset;
    size_t text_bytes;

    /**
     * Segment bounds in milliseconds, or LIBWHISPER_TIME_ABSENT when the
     * transcription did not request timestamps. The model works in
     * centiseconds, so these are multiples of 10 — do not read millisecond
     * precision into them.
     */
    int64_t start_ms;
    int64_t end_ms;

    /** Mean log probability over this segment's non-special tokens. */
    float average_logprobability;
    /** Probability the model assigned to this segment not being speech. */
    float no_speech_probability;
} libwhisper_segment_s;

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
 * Fill transcription options with defaults and stamp struct_size. Passing NULL
 * is a no-op. Options are optional: passing NULL to libwhisper_transcribe uses
 * these same defaults.
 */
void libwhisper_transcribe_options_init(libwhisper_transcribe_options_s *options);

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
 * Transcribe 16 kHz mono float PCM. Pass NULL options for the defaults.
 *
 * On success *out_result is always non-NULL and must be released with
 * libwhisper_result_free. An empty transcript — silence, or audio VAD rejected —
 * is still a result: it has zero segments and empty text, so accessors need no
 * null check. On any failure, including cancellation, *out_result is NULL and
 * nothing needs releasing; a cancelled transcription never yields a partial
 * result.
 *
 * out_result is cleared before any work starts, so it is safe to inspect after
 * any return value.
 */
libwhisper_error_e libwhisper_transcribe(
    libwhisper_t *transcriber,
    const float *samples,
    size_t sample_count,
    const libwhisper_transcribe_options_s *options,
    libwhisper_result_t **out_result
);

/**
 * The whole transcript: every segment's text concatenated, NUL-terminated, so
 * it works with printf("%s") and strlen. Never NULL for a valid result; empty
 * transcripts return "" with *out_bytes == 0. out_bytes may be NULL.
 *
 * Borrowed from the result and valid until libwhisper_result_free.
 */
const char *libwhisper_result_text(
    const libwhisper_result_t *result,
    size_t *out_bytes
);

/** Number of segments, or 0 for NULL or an unrecognized result. */
size_t libwhisper_result_segment_count(const libwhisper_result_t *result);

/**
 * Whole-transcript metrics. out_summary->struct_size must be set to
 * sizeof(libwhisper_result_summary_s) before the call; the rest is overwritten.
 *
 * These are the model's evidence, not a verdict. libwhisper deliberately does
 * not decide whether a transcript is trustworthy: which combination of weak
 * tokens, low average probability and no-speech evidence should reject a
 * transcript, ask the user, or pass is the caller's policy, and only the caller
 * can explain that decision to whoever is affected by it.
 */
libwhisper_error_e libwhisper_result_summary(
    const libwhisper_result_t *result,
    libwhisper_result_summary_s *out_summary
);

/**
 * One segment's text range and metrics. out_segment->struct_size must be set to
 * sizeof(libwhisper_segment_s) before the call. An index at or past
 * libwhisper_result_segment_count returns INVALID_ARGUMENT rather than reading
 * out of bounds.
 */
libwhisper_error_e libwhisper_result_segment(
    const libwhisper_result_t *result,
    size_t index,
    libwhisper_segment_s *out_segment
);

/**
 * Releases a result and everything borrowed from it, including the pointers
 * returned by libwhisper_result_text and libwhisper_result_summary. NULL is a
 * no-op. Freeing twice, or passing a pointer libwhisper did not produce, is
 * undefined; the library rejects what it can recognize as invalid, but that is
 * a best-effort check and not something to rely on.
 */
void libwhisper_result_free(libwhisper_result_t *result);

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
