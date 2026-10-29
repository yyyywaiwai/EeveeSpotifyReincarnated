#ifndef EEVEE_OFFLINE_PLAYPLAY_KEY_CAPTURE_H
#define EEVEE_OFFLINE_PLAYPLAY_KEY_CAPTURE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { PPKC_FILE_ID_BYTES = 20, PPKC_RECORD_BYTES = 28 };

// Installs once in Spotify 9.1.88 (918802209) with the exact supported Mach-O
// UUID. Returns 1 only when a compatible function-hook backend is available.
// Missing backend/version leaves normal playback untouched.
int ppkc_install(void);

// A later playback or accepted native prefetch record has a greater
// generation. Zero means no record has been captured in this process.
uint64_t ppkc_generation(void);

// Moves one newly captured in-process record to the caller and erases the
// internal copy. Returns 1 only for a record newer than `after_generation`.
// This legacy entry does not filter by file ID; callers must validate the
// chosen ciphertext independently. Prefer ppkc_consume_for_file_id below.
int ppkc_consume_after(uint64_t after_generation,
                       uint8_t out_record[PPKC_RECORD_BYTES],
                       uint64_t *out_generation);

// Moves the newest record attributed to this exact audio file ID through
// Spotify's playback callback, cached-key replay setter, or accepted native
// prefetch cache path. A missing or mismatched ID leaves other records intact.
int ppkc_consume_for_file_id(const uint8_t file_id[PPKC_FILE_ID_BYTES],
                             uint8_t out_record[PPKC_RECORD_BYTES],
                             uint64_t *out_generation);

// A non-consuming snapshot of an attributed, unconsumed record for this exact
// audio file ID. Capture, consume, or eviction may change the answer afterward.
int ppkc_has_for_file_id(const uint8_t file_id[PPKC_FILE_ID_BYTES]);

// Erases any unconsumed record; does not reset the monotonic generation.
void ppkc_clear(void);

#ifdef __cplusplus
}
#endif

#endif
