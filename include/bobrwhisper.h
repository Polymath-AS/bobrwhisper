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

typedef void (*bobrwhisper_status_cb)(void* userdata, bobrwhisper_status_e status);
typedef void (*bobrwhisper_transcript_cb)(void* userdata, bobrwhisper_string_s text, bool is_final);
typedef void (*bobrwhisper_error_cb)(void* userdata, bobrwhisper_string_s error);

typedef struct {
    void* userdata;
    bobrwhisper_status_cb on_status_change;
    bobrwhisper_transcript_cb on_transcript;
    bobrwhisper_error_cb on_error;
    const char* models_dir;
    const char* config_path;
    const char* llm_model_path;
    const char* vad_model_path;
} bobrwhisper_runtime_config_s;

typedef struct {
    const char* language;
    bobrwhisper_tone_e tone;
    bool remove_filler_words;
    bool auto_punctuate;
    bool use_llm_formatting;
} bobrwhisper_transcribe_options_s;

typedef struct {
    bobrwhisper_tone_e tone;
    bool remove_filler_words;
    bool auto_punctuate;
    bool use_llm_formatting;
} bobrwhisper_settings_s;

int bobrwhisper_init(void);
void bobrwhisper_deinit(void);

bobrwhisper_app_t bobrwhisper_app_new(const bobrwhisper_runtime_config_s* config);
void bobrwhisper_app_free(bobrwhisper_app_t app);

bool bobrwhisper_model_exists(bobrwhisper_app_t app, bobrwhisper_model_size_e size);
bobrwhisper_string_s bobrwhisper_model_path(bobrwhisper_app_t app, bobrwhisper_model_size_e size);
bool bobrwhisper_model_load(bobrwhisper_app_t app, bobrwhisper_model_size_e size);
void bobrwhisper_model_unload(bobrwhisper_app_t app);
bool bobrwhisper_settings_write(bobrwhisper_app_t app, const bobrwhisper_settings_s* settings);

bool bobrwhisper_start_recording(bobrwhisper_app_t app);
bool bobrwhisper_start_recording_live(bobrwhisper_app_t app, const char* language);
void bobrwhisper_stop_recording(bobrwhisper_app_t app);
bool bobrwhisper_stop_recording_live(bobrwhisper_app_t app, const bobrwhisper_transcribe_options_s* options);
bool bobrwhisper_is_recording(bobrwhisper_app_t app);

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

// Status
bobrwhisper_status_e bobrwhisper_get_status(bobrwhisper_app_t app);

// Audio level (RMS) - returns 0.0 when not recording
float bobrwhisper_get_audio_level(bobrwhisper_app_t app);

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
