#include "BookXCosyVoiceBridge.h"
#include "tts-cpp/cosyvoice/engine.h"
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <new>
#include <string>
struct BookXCosyVoice {
    std::unique_ptr<tts_cpp::cosyvoice::Engine> engine;
};
static void set_error(char **out, const char *message) {
    if (!out) return;
    const char *text = message ? message : "Unknown CosyVoice error";
    const size_t size = std::strlen(text) + 1;
    *out = static_cast<char *>(std::malloc(size));
    if (*out) std::memcpy(*out, text, size);
}
extern "C" BookXCosyVoice *bookx_cosyvoice_open(const char *dir, char **error_out) {
    if (error_out) *error_out = nullptr;
    if (!dir || !*dir) { set_error(error_out, "CosyVoice model directory is empty"); return nullptr; }
    try {
        tts_cpp::cosyvoice::EngineOptions opts;
        opts.model_dir = dir;
        opts.n_gpu_layers = 99; // Prefer validated Metal backend on iOS.
        auto handle = std::make_unique<BookXCosyVoice>();
        handle->engine = std::make_unique<tts_cpp::cosyvoice::Engine>(opts);
        return handle.release();
    } catch (const std::exception &e) { set_error(error_out, e.what()); return nullptr; }
      catch (...) { set_error(error_out, "CosyVoice initialization failed"); return nullptr; }
}
extern "C" int bookx_cosyvoice_synthesize(BookXCosyVoice *handle, const char *text,
    float **samples_out, size_t *sample_count_out, int *sample_rate_out, char **error_out) {
    if (error_out) *error_out = nullptr;
    if (samples_out) *samples_out = nullptr;
    if (sample_count_out) *sample_count_out = 0;
    if (sample_rate_out) *sample_rate_out = 0;
    if (!handle || !handle->engine || !text || !*text || !samples_out || !sample_count_out || !sample_rate_out) {
        set_error(error_out, "Invalid CosyVoice synthesis arguments"); return -1;
    }
    try {
        auto result = handle->engine->synthesize(std::string(text));
        if (result.pcm.empty() || result.sample_rate <= 0) {
            set_error(error_out, "CosyVoice generated no audio"); return -1;
        }
        if (result.pcm.size() > SIZE_MAX / sizeof(float)) {
            set_error(error_out, "CosyVoice output too large"); return -1;
        }
        auto *copy = static_cast<float *>(std::malloc(result.pcm.size() * sizeof(float)));
        if (!copy) { set_error(error_out, "Out of memory copying CosyVoice PCM"); return -1; }
        std::memcpy(copy, result.pcm.data(), result.pcm.size() * sizeof(float));
        *samples_out = copy;
        *sample_count_out = result.pcm.size();
        *sample_rate_out = result.sample_rate;
        return 0;
    } catch (const std::exception &e) { set_error(error_out, e.what()); return -1; }
      catch (...) { set_error(error_out, "CosyVoice synthesis failed"); return -1; }
}
extern "C" void bookx_cosyvoice_cancel(BookXCosyVoice *handle) {
    if (handle && handle->engine) handle->engine->cancel();
}
extern "C" void bookx_cosyvoice_close(BookXCosyVoice *handle) { delete handle; }
extern "C" void bookx_cosyvoice_free(void *ptr) { std::free(ptr); }
