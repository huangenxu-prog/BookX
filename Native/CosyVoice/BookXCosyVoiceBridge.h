#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct BookXCosyVoice BookXCosyVoice;
// Returns NULL on error; error_out is malloc-owned and must be freed with bookx_cosyvoice_free.
BookXCosyVoice *bookx_cosyvoice_open(const char *model_directory, char **error_out);
// Returns 0 on success; samples_out is malloc-owned, mono 24 kHz float32.
int bookx_cosyvoice_synthesize(BookXCosyVoice *handle, const char *utf8_text,
                               float **samples_out, size_t *sample_count_out,
                               int *sample_rate_out, char **error_out);
// Call only when no synthesis is in flight. Cancel may be called concurrently.
void bookx_cosyvoice_cancel(BookXCosyVoice *handle);
void bookx_cosyvoice_close(BookXCosyVoice *handle);
void bookx_cosyvoice_free(void *ptr);
#ifdef __cplusplus
}
#endif
