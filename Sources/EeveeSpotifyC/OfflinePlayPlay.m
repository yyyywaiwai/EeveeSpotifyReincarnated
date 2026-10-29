#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L

#include "include/OfflinePlayPlay.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef PPC_TESTING
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#endif

static int rename_exclusive(const char *source, const char *destination) {
#ifdef PPC_TESTING
    return rename(source, destination);
#else
    return renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, RENAME_EXCL);
#endif
}

typedef void *(*ppc_ctor)(void *, int);
typedef void (*ppc_set_key)(void *, const void *);
typedef void (*ppc_decrypt)(void *, uint64_t, void *, const void *, uint64_t);
typedef void (*ppc_dtor)(void *);

typedef struct {
    ppc_ctor ctor;
    ppc_set_key set_key;
    ppc_decrypt decrypt;
    ppc_dtor dtor;
} ppc_native;

static void wipe(void *memory, size_t length) {
    volatile uint8_t *bytes = memory;
    while (length--) *bytes++ = 0;
}

static uint32_t le32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
           (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

static uint32_t ogg_crc(uint32_t crc, uint8_t byte) {
    crc ^= (uint32_t)byte << 24;
    for (int bit = 0; bit < 8; ++bit)
        crc = crc & 0x80000000 ? crc << 1 ^ 0x04c11db7 : crc << 1;
    return crc;
}

static uint32_t page_crc(const uint8_t *header, const uint8_t *segments,
                         const uint8_t *payload, size_t payload_bytes) {
    uint32_t crc = 0;
    for (size_t i = 0; i < 27; ++i) crc = ogg_crc(crc, i >= 22 && i < 26 ? 0 : header[i]);
    for (size_t i = 0; i < header[26]; ++i) crc = ogg_crc(crc, segments[i]);
    for (size_t i = 0; i < payload_bytes; ++i) crc = ogg_crc(crc, payload[i]);
    return crc;
}

static int valid_prefix(const uint8_t *clear, size_t length) {
    // shortcut: Spotify 9.1.88 format-0 starts its real Vorbis stream at 167, revisit for other formats.
    if (length < 171 || memcmp(clear, "OggS", 4) || clear[4] ||
        (clear[5] & 6) != 6 || memcmp(clear + 167, "OggS", 4)) return 0;
    size_t count = clear[26], payload_bytes = 0;
    if (27 + count > 167) return 0;
    for (size_t i = 0; i < count; ++i) payload_bytes += clear[27 + i];
    return 27 + count + payload_bytes == 167 &&
           page_crc(clear, clear + 27, clear + 27 + count, payload_bytes) == le32(clear + 22);
}

static int complete_ogg(FILE *file, uint64_t length, uint64_t *stream_bytes) {
    if (fseek(file, 0, SEEK_SET)) return 0;
    uint64_t offset = 0;
    uint32_t serial = 0, previous_sequence = 0;
    unsigned pages = 0;
    while (length - offset >= 27) {
        uint8_t header[27], segments[255], buffer[4096];
        if (fread(header, 1, sizeof(header), file) != sizeof(header) ||
            memcmp(header, "OggS", 4) || header[4] != 0 ||
            fread(segments, 1, header[26], file) != header[26]) return 0;
        size_t payload_bytes = 0;
        for (size_t i = 0; i < header[26]; ++i) payload_bytes += segments[i];
        uint64_t next = offset + 27 + header[26] + payload_bytes;
        if (next > length) return 0;
        uint32_t page_serial = le32(header + 14), sequence = le32(header + 18);
        if (pages ? (page_serial != serial || sequence != previous_sequence + 1 || (header[5] & 2))
                  : !(header[5] & 2)) return 0;
        serial = page_serial;
        previous_sequence = sequence;
        uint32_t crc = 0;
        for (size_t i = 0; i < 27; ++i) crc = ogg_crc(crc, i >= 22 && i < 26 ? 0 : header[i]);
        for (size_t i = 0; i < header[26]; ++i) crc = ogg_crc(crc, segments[i]);
        for (size_t left = payload_bytes; left;) {
            size_t count = left < sizeof(buffer) ? left : sizeof(buffer);
            if (fread(buffer, 1, count, file) != count) return 0;
            for (size_t i = 0; i < count; ++i) crc = ogg_crc(crc, buffer[i]);
            left -= count;
        }
        if (crc != le32(header + 22)) return 0;
        ++pages;
        offset = next;
        if (header[5] & 4) {
            if (length - offset > 15) return 0;
            for (uint64_t i = offset; i < length; ++i)
                if (fgetc(file) != 0) return 0;
            *stream_bytes = offset;
            return pages > 0;
        }
    }
    return 0;
}

static int decrypt_file(const char *encrypted_path, const char *ogg_path,
                        const void *key_record, size_t key_record_bytes, ppc_native native) {
    if (!encrypted_path || !ogg_path || !key_record || key_record_bytes != 28 ||
        !native.ctor || !native.set_key || !native.decrypt || !native.dtor) return -1;
    struct stat source_stat, destination_stat;
    if (stat(encrypted_path, &source_stat) || !S_ISREG(source_stat.st_mode) ||
        source_stat.st_size < 171 || source_stat.st_size > 512LL * 1024 * 1024 ||
        stat(ogg_path, &destination_stat) == 0 || errno != ENOENT) return -1;

    FILE *source = fopen(encrypted_path, "rb");
    if (!source) return -1;
    size_t temp_length = strlen(ogg_path) + sizeof(".partial.XXXXXX");
    char *temp_path = malloc(temp_length);
    if (!temp_path) { fclose(source); return -1; }
    snprintf(temp_path, temp_length, "%s.partial.XXXXXX", ogg_path);
    int fd = mkstemp(temp_path);
    if (fd < 0) { free(temp_path); fclose(source); return -1; }
    FILE *output = fdopen(fd, "w+b");
    if (!output) { close(fd); unlink(temp_path); free(temp_path); fclose(source); return -1; }

    void *context = NULL;
    uint8_t record[28];
    memcpy(record, key_record, sizeof(record));
    int constructed = 0, success = 0;
    if (posix_memalign(&context, 16, 0x330)) goto cleanup;
    memset(context, 0, 0x330);
    if (native.ctor(context, 0) != context) goto cleanup;
    constructed = 1;
    native.set_key(context, record);

    uint8_t cipher[65536], clear[65536];
    uint64_t offset = 0;
    while (offset < (uint64_t)source_stat.st_size) {
        size_t wanted = (uint64_t)source_stat.st_size - offset < sizeof(cipher)
            ? (size_t)((uint64_t)source_stat.st_size - offset) : sizeof(cipher);
        if (fread(cipher, 1, wanted, source) != wanted) goto cleanup;
        native.decrypt(context, offset, clear, cipher, wanted);
        if (!offset && !valid_prefix(clear, wanted)) goto cleanup;
        size_t skip = offset == 0 ? 167 : 0;
        if (fwrite(clear + skip, 1, wanted - skip, output) != wanted - skip) goto cleanup;
        offset += wanted;
    }
    if (ferror(source) || fgetc(source) != EOF || !feof(source)) goto cleanup;
    if (fflush(output)) goto cleanup;
    uint64_t stream_bytes = 0;
    if (!complete_ogg(output, offset - 167, &stream_bytes) ||
        ftruncate(fileno(output), (off_t)stream_bytes) || fflush(output) || fsync(fileno(output))) goto cleanup;
    success = 1;

cleanup:
    if (constructed) native.dtor(context);
    if (context) { wipe(context, 0x330); free(context); }
    wipe(record, sizeof(record));
    if (fclose(source)) success = 0;
    if (fclose(output)) success = 0;
    if (success && !rename_exclusive(temp_path, ogg_path)) {
        char *slash = strrchr(temp_path, '/');
        if (slash) {
            *slash = 0;
            int directory = open(temp_path, O_RDONLY);
            if (directory >= 0) { (void)fsync(directory); close(directory); }
        }
    } else {
        success = 0;
        unlink(temp_path);
    }
    free(temp_path);
    return success ? 0 : -1;
}

#ifndef PPC_TESTING
static int spotify_9188(ppc_native *native) {
    static const uint8_t expected_uuid[16] = {
        0xf5, 0x1d, 0xbd, 0x93, 0x3b, 0x8f, 0x3a, 0x12,
        0x94, 0x31, 0x96, 0xc6, 0x06, 0xe3, 0xaf, 0xc2
    };
    for (uint32_t image = 0; image < _dyld_image_count(); ++image) {
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(image);
        const char *name = _dyld_get_image_name(image);
        if (!header || !name || !strstr(name, "/Spotify.app/Spotify") ||
            header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 ||
            header->filetype != MH_EXECUTE) continue;
        const uint8_t *command = (const uint8_t *)(header + 1);
        const uint8_t *end = command + header->sizeofcmds;
        for (uint32_t i = 0; i < header->ncmds; ++i) {
            if (command > end || (size_t)(end - command) < sizeof(struct load_command)) return 0;
            const struct load_command *load = (const struct load_command *)command;
            if (load->cmdsize < sizeof(*load) || load->cmdsize > (size_t)(end - command)) return 0;
            if (load->cmd == LC_UUID && load->cmdsize >= sizeof(struct uuid_command)) {
                if (memcmp(((const struct uuid_command *)load)->uuid, expected_uuid, 16)) return 0;
                uintptr_t base = (uintptr_t)header;
                native->ctor = (ppc_ctor)(base + 0x49080a8);
                native->set_key = (ppc_set_key)(base + 0x5bfed98);
                native->decrypt = (ppc_decrypt)(base + 0x7f271a4);
                native->dtor = (ppc_dtor)(base + 0x6b9aefc);
                return 1;
            }
            command += load->cmdsize;
        }
    }
    return 0;
}

int ppc_decrypt_file_to_ogg(const char *encrypted_path, const char *ogg_path,
                            const void *key_record, size_t key_record_bytes) {
    ppc_native native = {0};
    if (!spotify_9188(&native)) return -1;
    return decrypt_file(encrypted_path, ogg_path, key_record, key_record_bytes, native);
}
#endif
