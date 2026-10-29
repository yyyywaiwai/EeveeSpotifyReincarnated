#define _DARWIN_C_SOURCE 1
#define PPC_TESTING 1
#include "../../Sources/EeveeSpotifyC/OfflinePlayPlay.m"

#include <assert.h>

static void *fake_ctor(void *context, int mode) {
    assert(mode == 0);
    return context;
}
static void fake_set(void *context, const void *record) { (void)context; (void)record; }
static void fake_decrypt(void *context, uint64_t offset, void *clear,
                         const void *cipher, uint64_t length) {
    (void)context; (void)offset;
    memcpy(clear, cipher, (size_t)length);
}
static void fake_dtor(void *context) { (void)context; }

static size_t make_page(uint8_t *dst, uint8_t flags, uint32_t serial,
                        uint32_t sequence, const uint8_t *payload, uint8_t payload_bytes) {
    size_t length = 28 + payload_bytes;
    memset(dst, 0, length);
    memcpy(dst, "OggS", 4);
    dst[5] = flags;
    dst[14] = (uint8_t)serial;
    dst[15] = (uint8_t)(serial >> 8);
    dst[18] = (uint8_t)sequence;
    dst[26] = 1;
    dst[27] = payload_bytes;
    memcpy(dst + 28, payload, payload_bytes);
    uint32_t crc = page_crc(dst, dst + 27, dst + 28, payload_bytes);
    for (int i = 0; i < 4; ++i) dst[22 + i] = (uint8_t)(crc >> (8 * i));
    return length;
}

static void write_bytes(const char *path, const uint8_t *bytes, size_t length) {
    FILE *file = fopen(path, "wb");
    assert(file);
    assert(fwrite(bytes, 1, length, file) == length);
    assert(fclose(file) == 0);
}

int main(void) {
    char directory[] = "/tmp/eevee-playplay-XXXXXX";
    assert(mkdtemp(directory));
    char input[256], output[256];
    snprintf(input, sizeof(input), "%s/input.encrypted", directory);
    snprintf(output, sizeof(output), "%s/output.ogg", directory);

    uint8_t bytes[512] = {0}, prefix_payload[139] = {0};
    const uint8_t first[] = {1, 'v', 'o', 'r', 'b', 'i', 's'};
    const uint8_t last[] = {0, 1, 2, 3, 4, 5};
    size_t length = make_page(bytes, 6, 1, 0, prefix_payload, sizeof(prefix_payload));
    assert(length == 167);
    length += make_page(bytes + length, 2, 2, 0, first, sizeof(first));
    length += make_page(bytes + length, 4, 2, 1, last, sizeof(last));
    size_t complete_bytes = length - 167;
    length += 3; // Spotify AES block padding is zero-filled.

    const ppc_native native = {fake_ctor, fake_set, fake_decrypt, fake_dtor};
    uint8_t record[28] = {0};
    write_bytes(input, bytes, length);
    assert(decrypt_file(input, output, record, sizeof(record), native) == 0);
    FILE *saved = fopen(output, "rb");
    assert(saved);
    uint8_t actual[512] = {0};
    assert(fread(actual, 1, sizeof(actual), saved) == complete_bytes);
    assert(memcmp(actual, bytes + 167, complete_bytes) == 0);
    assert(fclose(saved) == 0);
    assert(decrypt_file(input, output, record, sizeof(record), native) != 0); // no overwrite
    assert(unlink(output) == 0);

    bytes[167 + 28] ^= 1; // corrupt stream payload without updating CRC
    write_bytes(input, bytes, length);
    assert(decrypt_file(input, output, record, sizeof(record), native) != 0);
    assert(access(output, F_OK) != 0);
    bytes[167 + 28] ^= 1;
    bytes[length - 1] = 1; // non-zero tail cannot be stripped
    write_bytes(input, bytes, length);
    assert(decrypt_file(input, output, record, sizeof(record), native) != 0);
    assert(access(output, F_OK) != 0);
    assert(decrypt_file(input, output, record, sizeof(record) - 1, native) != 0);

    assert(unlink(input) == 0);
    assert(rmdir(directory) == 0);
    return 0;
}
