#ifndef BOBRWHISPER_H
#define BOBRWHISPER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* bobrwhisper_app_t;
typedef void* bobrwhisper_config_t;
typedef void* bobrwhisper_transcriber_t;

typedef struct {
    const char* ptr;
    size_t len;
} bobrwhisper_string_s;

typedef enum {
    BOBRWHISPER_MODEL_RUNTIME_WHISPER_CPP = 0,
    BOBRWHISPER_MODEL_RUNTIME_COREML = 1,
    BOBRWHISPER_MODEL_RUNTIME_ONNX = 2,
    BOBRWHISPER_MODEL_RUNTIME_SERVER = 3,
} bobrwhisper_model_runtime_e;

typedef uint64_t bobrwhisper_model_capabilities_t;

typedef struct {
    const char* id;
    const char* display_name;
    const char* family;
    bobrwhisper_model_runtime_e runtime;
    const char* local_filename;
    const char* download_url;
    uint64_t size_bytes;
    bobrwhisper_model_capabilities_t capabilities;
    bool available_on_this_device;
} bobrwhisper_model_descriptor_s;

typedef struct {
    bobrwhisper_string_s id;
    bobrwhisper_string_s name;
    bobrwhisper_string_s kind;
} bobrwhisper_audio_device_descriptor_s;

typedef enum {
    BOBRWHISPER_MODEL_TINY = 0,
    BOBRWHISPER_MODEL_BASE = 1,
    BOBRWHISPER_MODEL_SMALL = 2,
    BOBRWHISPER_MODEL_MEDIUM = 3,
    BOBRWHISPER_MODEL_LARGE = 4,
    BOBRWHISPER_MODEL_LARGE_TURBO = 5,
} bobrwhisper_model_size_e;

typedef enum {
    BOBRWHISPER_STATUS_IDLE = 0,
    BOBRWHISPER_STATUS_RECORDING = 1,
    BOBRWHISPER_STATUS_TRANSCRIBING = 2,
    BOBRWHISPER_STATUS_FORMATTING = 3,
    BOBRWHISPER_STATUS_READY = 4,
    BOBRWHISPER_STATUS_ERROR = 5,
} bobrwhisper_status_e;

typedef enum {
    BOBRWHISPER_TONE_NEUTRAL = 0,
    BOBRWHISPER_TONE_FORMAL = 1,
    BOBRWHISPER_TONE_CASUAL = 2,
    BOBRWHISPER_TONE_CODE = 3,
} bobrwhisper_tone_e;

typedef enum {
    BOBRWHISPER_POSTPROCESS_LITERAL = 0,
    BOBRWHISPER_POSTPROCESS_CONSERVATIVE = 1,
    BOBRWHISPER_POSTPROCESS_POLISH = 2,
} bobrwhisper_postprocess_mode_e;

typedef enum {
    BOBRWHISPER_TRANSCRIPT_RECOGNIZING = 0,
    BOBRWHISPER_TRANSCRIPT_CLEANING = 1,
    BOBRWHISPER_TRANSCRIPT_FINAL = 2,
} bobrwhisper_transcript_phase_e;

typedef struct {
    const char* bundle_id;
    const char* window_title;
    const char* text_before_cursor;
    const char* text_after_cursor;
    const char* selected_text;
    bool is_secure;
} bobrwhisper_recording_context_s;

typedef struct {
    const char* language;
    bobrwhisper_postprocess_mode_e postprocess_mode;
    bobrwhisper_tone_e tone;
    bool whisper_mode;
    const bobrwhisper_recording_context_s* context;
} bobrwhisper_recording_options_s;

typedef struct {
    uint64_t session_id;
    uint64_t revision;
    bobrwhisper_string_s stable_text;
    bobrwhisper_string_s unstable_text;
    bobrwhisper_transcript_phase_e phase;
} bobrwhisper_transcript_update_s;

typedef void (*bobrwhisper_status_cb)(void* userdata, bobrwhisper_status_e status);
typedef void (*bobrwhisper_transcript_cb)(void* userdata, bobrwhisper_string_s text, bool is_final);
typedef void (*bobrwhisper_transcript_update_cb)(void* userdata, bobrwhisper_transcript_update_s update);
typedef void (*bobrwhisper_error_cb)(void* userdata, bobrwhisper_string_s error);
/// Non-fatal warning channel. Runtime issues that the user should know about
/// but that do not stop work in progress (stuck microphone, suboptimal input
/// device, ...) flow through this callback instead of `on_error`. The status
/// is NOT changed to ERROR when a warning fires.
typedef void (*bobrwhisper_warning_cb)(void* userdata, bobrwhisper_string_s warning);

typedef struct {
    void* userdata;
    bobrwhisper_status_cb on_status_change;
    bobrwhisper_transcript_cb on_transcript;
    bobrwhisper_error_cb on_error;
    bobrwhisper_warning_cb on_warning;
    const char* models_dir;
    const char* config_path;
    const char* llm_model_path;
    const char* vad_model_path;
    bool whisper_mode;
    bobrwhisper_transcript_update_cb on_transcript_update;
} bobrwhisper_runtime_config_s;

typedef struct {
    const char* language;
    bobrwhisper_tone_e tone;
    bool remove_filler_words;
    bool auto_punctuate;
    bool use_llm_formatting;
    bool whisper_mode;
} bobrwhisper_transcribe_options_s;

typedef struct {
    bobrwhisper_tone_e tone;
    bool remove_filler_words;
    bool auto_punctuate;
    bool use_llm_formatting;
    const char* custom_prompt;
    bool whisper_mode;
} bobrwhisper_settings_s;

int bobrwhisper_init(void);
void bobrwhisper_deinit(void);

bobrwhisper_app_t bobrwhisper_app_new(const bobrwhisper_runtime_config_s* config);
void bobrwhisper_app_free(bobrwhisper_app_t app);

size_t bobrwhisper_model_count(bobrwhisper_app_t app);
bool bobrwhisper_model_descriptor_at(
    bobrwhisper_app_t app,
    size_t index,
    bobrwhisper_model_descriptor_s* out_descriptor
);

bool bobrwhisper_model_exists_id(bobrwhisper_app_t app, const char* model_id);
bobrwhisper_string_s bobrwhisper_model_path_id(bobrwhisper_app_t app, const char* model_id);
bool bobrwhisper_model_load_id(bobrwhisper_app_t app, const char* model_id);

bool bobrwhisper_model_exists(bobrwhisper_app_t app, bobrwhisper_model_size_e size);
bobrwhisper_string_s bobrwhisper_model_path(bobrwhisper_app_t app, bobrwhisper_model_size_e size);
bool bobrwhisper_model_load(bobrwhisper_app_t app, bobrwhisper_model_size_e size);
void bobrwhisper_model_unload(bobrwhisper_app_t app);
/** Select an installed local GGUF for cleanup. The path is copied by the core. */
bool bobrwhisper_llm_model_set_path(bobrwhisper_app_t app, const char* model_path);
bool bobrwhisper_settings_write(bobrwhisper_app_t app, const bobrwhisper_settings_s* settings);

bool bobrwhisper_start_recording(bobrwhisper_app_t app);
bool bobrwhisper_start_recording_live(bobrwhisper_app_t app, const char* language);
void bobrwhisper_stop_recording(bobrwhisper_app_t app);
bool bobrwhisper_stop_recording_live(bobrwhisper_app_t app, const bobrwhisper_transcribe_options_s* options);
bool bobrwhisper_is_recording(bobrwhisper_app_t app);

/** Start a session. Returns a non-zero monotonic session id on success. */
uint64_t bobrwhisper_recording_start(
    bobrwhisper_app_t app,
    const bobrwhisper_recording_options_s* options
);
/** Drain and finalize the matching session. */
bool bobrwhisper_recording_stop(bobrwhisper_app_t app, uint64_t session_id);
/** Cancel the matching session; late updates are ignored. */
void bobrwhisper_recording_cancel(bobrwhisper_app_t app, uint64_t session_id);

bool bobrwhisper_transcribe(
    bobrwhisper_app_t app,
    const bobrwhisper_transcribe_options_s* options
);

bool bobrwhisper_format_text(
    bobrwhisper_app_t app,
    bobrwhisper_string_s input,
    bobrwhisper_tone_e tone,
    bobrwhisper_transcript_cb callback,
    void* userdata
);

bool bobrwhisper_log_transcript(
    bobrwhisper_app_t app,
    bobrwhisper_string_s transcript
);
bobrwhisper_string_s bobrwhisper_log_recent_json(
    bobrwhisper_app_t app,
    size_t limit
);
bool bobrwhisper_log_clear(bobrwhisper_app_t app);

// Status
bobrwhisper_status_e bobrwhisper_get_status(bobrwhisper_app_t app);

// Audio level (RMS) - returns 0.0 when not recording
float bobrwhisper_get_audio_level(bobrwhisper_app_t app);

size_t bobrwhisper_audio_device_count(bobrwhisper_app_t app);
bool bobrwhisper_audio_device_at(
    bobrwhisper_app_t app,
    size_t index,
    bobrwhisper_audio_device_descriptor_s* out_device
);
void bobrwhisper_audio_device_descriptor_free(bobrwhisper_audio_device_descriptor_s* device);
/** Select the app's recording device without changing the system default.
 * Pass an empty string to follow the system default input device. */
bool bobrwhisper_set_input_device(bobrwhisper_app_t app, const char* device_id);

// =============================================================================
// Utility
// =============================================================================

// Get version info
bobrwhisper_string_s bobrwhisper_version(void);

// Free a string returned by the library
void bobrwhisper_string_free(bobrwhisper_string_s str);

#ifdef __cplusplus
}
#endif

#endif // BOBRWHISPER_H
