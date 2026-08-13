#ifndef BOBRWHISPER_AUDIO_H
#define BOBRWHISPER_AUDIO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Audio processing: everything between a capture device and an ASR engine.
 *
 * This library has no dependencies — no model, no platform audio API — and does
 * no I/O of its own: you hand it bytes or samples and it hands back samples.
 * It is what turns what a microphone gives you (48 kHz stereo, arbitrary buffer
 * sizes) into what libwhisper requires (16 kHz mono float, one contiguous
 * buffer).
 *
 * Every function tolerates NULL pointers by returning an error or a neutral
 * value rather than faulting. Nothing here logs or writes to stderr.
 */

#define BOBRWHISPER_AUDIO_VERSION_MAJOR 0
#define BOBRWHISPER_AUDIO_VERSION_MINOR 1
#define BOBRWHISPER_AUDIO_VERSION_PATCH 0
#define BOBRWHISPER_AUDIO_VERSION_STRING "0.1.0"

typedef enum {
    BOBRWHISPER_AUDIO_SUCCESS = 0,
    BOBRWHISPER_AUDIO_ERROR_INVALID_ARGUMENT = 1,
    BOBRWHISPER_AUDIO_ERROR_OUT_OF_MEMORY = 2,
    BOBRWHISPER_AUDIO_ERROR_NOT_RIFF_WAVE = 3,
    BOBRWHISPER_AUDIO_ERROR_MISSING_CHUNK = 4,
    BOBRWHISPER_AUDIO_ERROR_UNSUPPORTED_FORMAT = 5,
    BOBRWHISPER_AUDIO_ERROR_TRUNCATED_FRAME = 6,
    BOBRWHISPER_AUDIO_ERROR_UNKNOWN = 255,
} bobrwhisper_audio_error_e;

/**
 * An owned buffer of mono 32-bit float samples. Release with
 * bobrwhisper_audio_buffer_free, passed back exactly as received.
 *
 * `ptr == NULL` means empty and needs no release. Producing functions clear the
 * output before doing any work, so it is safe to inspect after any return value.
 */
typedef struct {
    float *ptr;
    size_t len;
} bobrwhisper_audio_buffer_s;

/** Properties of a decoded file as it was stored, before any conversion. */
typedef struct {
    uint32_t sample_rate;
    uint16_t channels;
    uint16_t bits_per_sample;
    /** Frames, not samples: a stereo frame counts once. */
    size_t frames;
} bobrwhisper_audio_wav_info_s;

typedef struct {
    float peak;
    float rms;
} bobrwhisper_audio_level_s;

/** A half-open range [start, end) of samples. */
typedef struct {
    size_t start;
    size_t end;
} bobrwhisper_audio_trim_s;

typedef struct {
    /**
     * Must equal sizeof(bobrwhisper_audio_prepare_options_s). Set it by calling
     * bobrwhisper_audio_prepare_options_init; do not assign it yourself.
     */
    size_t struct_size;
    bool normalize;
    float target_peak;
    /** Multiplier on the squared noise floor. 9 is 3x in amplitude terms. */
    float noise_multiplier;
    /** Floor for the derived threshold, so near-silent input still trims. */
    float min_threshold;
} bobrwhisper_audio_prepare_options_s;

typedef struct {
    /** Range within the buffer, which was modified in place. */
    bobrwhisper_audio_trim_s bounds;
    float gain;
    float noise_floor;
    float threshold;
} bobrwhisper_audio_prepared_s;

/** Accumulates a stream into fixed-size chunks. */
typedef struct bobrwhisper_audio_chunker bobrwhisper_audio_chunker_t;

/** The runtime version, which may differ from BOBRWHISPER_AUDIO_VERSION_STRING. */
const char *bobrwhisper_audio_version(void);

/** The sample rate every ASR path in this project expects (16000). */
uint32_t bobrwhisper_audio_asr_sample_rate(void);

/**
 * A human-readable description. Never returns NULL, and returns a placeholder
 * rather than faulting when given a code this build does not recognize.
 */
const char *bobrwhisper_audio_error_string(bobrwhisper_audio_error_e error);

/** Releases a buffer. A NULL ptr is a no-op. */
void bobrwhisper_audio_buffer_free(bobrwhisper_audio_buffer_s buffer);

/**
 * Decode a RIFF/WAVE file to mono float. Handles PCM16 and IEEE float32 at any
 * rate and channel count; WAVE_FORMAT_EXTENSIBLE, 24-bit PCM and the companded
 * formats are rejected rather than guessed at.
 *
 * `target_rate` of 0 keeps the file's own rate. `out_info` may be NULL.
 */
bobrwhisper_audio_error_e bobrwhisper_audio_decode_wav(
    const uint8_t *bytes,
    size_t len,
    uint32_t target_rate,
    bobrwhisper_audio_buffer_s *out_samples,
    bobrwhisper_audio_wav_info_s *out_info
);

/**
 * Downmix interleaved channels and resample to the ASR rate in one step — the
 * conversion a capture backend needs. `len` counts samples, not frames.
 */
bobrwhisper_audio_error_e bobrwhisper_audio_to_asr_format(
    const float *interleaved,
    size_t len,
    uint16_t channels,
    double from_rate,
    bobrwhisper_audio_buffer_s *out_samples
);

/** Linear resampling between two rates. */
bobrwhisper_audio_error_e bobrwhisper_audio_resample(
    const float *samples,
    size_t len,
    double from_rate,
    double to_rate,
    bobrwhisper_audio_buffer_s *out_samples
);

/** Peak and RMS amplitude. A NULL buffer measures as zero. */
bobrwhisper_audio_level_s bobrwhisper_audio_measure(const float *samples, size_t len);

/**
 * Scale in place so the loudest sample reaches `target_peak`, returning the gain
 * applied. Only ever scales up: already-loud and near-silent buffers are left
 * alone and return 1.0.
 */
float bobrwhisper_audio_peak_normalize(float *samples, size_t len, float target_peak);

/**
 * Whether mean energy exceeds `threshold`. The threshold is in mean-square
 * units, so it compares against the square of an amplitude: 0.01 is roughly a
 * 0.1 amplitude floor.
 */
bool bobrwhisper_audio_detect_voice(const float *samples, size_t len, float threshold);

/** RMS of a leading window, for deriving an adaptive trim threshold. */
float bobrwhisper_audio_noise_floor(const float *samples, size_t len);

/** Locate speech within the buffer, keeping context on both sides. */
bobrwhisper_audio_trim_s bobrwhisper_audio_trim_silence(
    const float *samples,
    size_t len,
    float threshold
);

/** Fill options with defaults and stamp struct_size. NULL is a no-op. */
void bobrwhisper_audio_prepare_options_init(bobrwhisper_audio_prepare_options_s *options);

/**
 * Normalize, measure the noise floor and locate the speech, modifying `samples`
 * in place. Pass NULL options for the defaults. The returned bounds index into
 * `samples`; nothing is allocated.
 */
bobrwhisper_audio_error_e bobrwhisper_audio_prepare_for_asr(
    float *samples,
    size_t len,
    const bobrwhisper_audio_prepare_options_s *options,
    bobrwhisper_audio_prepared_s *out_result
);

/**
 * Create a chunker emitting `chunk_len` samples at a time, each repeating
 * `overlap_len` samples of the previous chunk. Overlap must be less than
 * chunk_len. Overlap exists because a word split across a boundary is usually
 * lost by both chunks; reconciling the duplicated text is the caller's job.
 */
bobrwhisper_audio_error_e bobrwhisper_audio_chunker_create(
    size_t chunk_len,
    size_t overlap_len,
    bobrwhisper_audio_chunker_t **out_chunker
);

void bobrwhisper_audio_chunker_destroy(bobrwhisper_audio_chunker_t *chunker);

/** Append samples. Invalidates any chunk previously borrowed. */
bobrwhisper_audio_error_e bobrwhisper_audio_chunker_push(
    bobrwhisper_audio_chunker_t *chunker,
    const float *samples,
    size_t len
);

/**
 * Borrow the next chunk, returning false when one is not complete yet. The
 * samples stay valid until the next push or reset. Out parameters may be NULL.
 */
bool bobrwhisper_audio_chunker_next(
    bobrwhisper_audio_chunker_t *chunker,
    const float **out_samples,
    size_t *out_len
);

/**
 * Borrow the samples that do not fill a chunk, for end of stream. Returns the
 * length, and follows the same lifetime rules as chunker_next.
 */
size_t bobrwhisper_audio_chunker_flush(
    bobrwhisper_audio_chunker_t *chunker,
    const float **out_samples,
    size_t *out_len
);

/** How many whole chunks chunker_next will yield before returning false. */
size_t bobrwhisper_audio_chunker_ready(bobrwhisper_audio_chunker_t *chunker);

void bobrwhisper_audio_chunker_reset(bobrwhisper_audio_chunker_t *chunker);

#ifdef __cplusplus
}
#endif

#endif /* BOBRWHISPER_AUDIO_H */
