#ifndef EEVEE_OFFLINE_PLAYPLAY_H
#define EEVEE_OFFLINE_PLAYPLAY_H

#include <stddef.h>

// Returns zero only after a complete normalized Ogg is atomically saved.
// key_record is the 28-byte in-process record for the same audio file ID.
int ppc_decrypt_file_to_ogg(const char *encrypted_path, const char *ogg_path,
                            const void *key_record, size_t key_record_bytes);

#endif
