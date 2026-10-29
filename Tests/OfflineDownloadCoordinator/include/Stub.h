#include <stddef.h>
#include <stdint.h>
int ppkc_install(void);
uint64_t ppkc_generation(void);
int ppkc_has_for_file_id(const uint8_t file_id[20]);
int ppkc_consume_for_file_id(const uint8_t file_id[20], uint8_t out_record[28], uint64_t *out_generation);
int ppc_decrypt_file_to_ogg(const char *encrypted_path, const char *ogg_path,
                            const void *key_record, size_t key_record_bytes);
int ppc_decode_ogg_to_wav(const char *input, const char *output);
