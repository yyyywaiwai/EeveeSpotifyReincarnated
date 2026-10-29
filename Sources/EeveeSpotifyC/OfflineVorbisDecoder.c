#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wtautological-compare"
#include "vendor/stb_vorbis.h"
#pragma clang diagnostic pop

static int le16(FILE *file, uint16_t value) {
    const unsigned char b[2] = {(unsigned char)value, (unsigned char)(value >> 8)};
    return fwrite(b, 1, 2, file) == 2;
}

static int le32(FILE *file, uint32_t value) {
    const unsigned char b[4] = {
        (unsigned char)value, (unsigned char)(value >> 8),
        (unsigned char)(value >> 16), (unsigned char)(value >> 24)
    };
    return fwrite(b, 1, 4, file) == 4;
}

static int wav_header(FILE *file, uint32_t size, int channels, int rate) {
    return fwrite("RIFF", 1, 4, file) == 4 && le32(file, size + 36) &&
           fwrite("WAVEfmt ", 1, 8, file) == 8 && le32(file, 16) &&
           le16(file, 1) && le16(file, (uint16_t)channels) &&
           le32(file, (uint32_t)rate) && le32(file, (uint32_t)(rate * channels * 2)) &&
           le16(file, (uint16_t)(channels * 2)) && le16(file, 16) &&
           fwrite("data", 1, 4, file) == 4 && le32(file, size);
}

static uint32_t ogg_crc_byte(uint32_t crc, unsigned char byte) {
    crc ^= (uint32_t)byte << 24;
    for (int bit = 0; bit < 8; bit++) crc = (crc & 0x80000000) ? (crc << 1) ^ 0x04c11db7 : crc << 1;
    return crc;
}

static int complete_ogg(const char *input) {
    FILE *file = fopen(input, "rb");
    if (!file) return 0;
    int valid = 0;
    if (fseek(file, 0, SEEK_END) != 0) goto done;
    long length = ftell(file);
    if (length < 27 || length > 512L * 1024 * 1024 || fseek(file, 0, SEEK_SET) != 0) goto done;
    long offset = 0;
    int last_flags = 0, pages = 0;
    uint32_t serial = 0, previous_sequence = 0;
    while (offset < length) {
        unsigned char header[27], segments[255];
        if (length - offset < 27 || fread(header, 1, 27, file) != 27 ||
            memcmp(header, "OggS", 4) || header[4] != 0) goto done;
        unsigned count = header[26], payload = 0;
        if (fread(segments, 1, count, file) != count) goto done;
        for (unsigned i = 0; i < count; i++) payload += segments[i];
        long next = offset + 27 + (long)count + payload;
        if (next > length) goto done;
        uint32_t page_serial = (uint32_t)header[14] | (uint32_t)header[15] << 8 |
            (uint32_t)header[16] << 16 | (uint32_t)header[17] << 24;
        uint32_t sequence = (uint32_t)header[18] | (uint32_t)header[19] << 8 |
            (uint32_t)header[20] << 16 | (uint32_t)header[21] << 24;
        if (pages ? (page_serial != serial || sequence != previous_sequence + 1 || (header[5] & 2))
                  : (!(header[5] & 2))) goto done;
        serial = page_serial;
        previous_sequence = sequence;
        uint32_t expected_crc = (uint32_t)header[22] | (uint32_t)header[23] << 8 |
            (uint32_t)header[24] << 16 | (uint32_t)header[25] << 24;
        uint32_t actual_crc = 0;
        for (unsigned i = 0; i < 27; i++) actual_crc = ogg_crc_byte(actual_crc, i >= 22 && i < 26 ? 0 : header[i]);
        for (unsigned i = 0; i < count; i++) actual_crc = ogg_crc_byte(actual_crc, segments[i]);
        unsigned char bytes[4096];
        for (unsigned left = payload; left;) {
            size_t n = left < sizeof(bytes) ? left : sizeof(bytes);
            if (fread(bytes, 1, n, file) != n) goto done;
            for (size_t i = 0; i < n; i++) actual_crc = ogg_crc_byte(actual_crc, bytes[i]);
            left -= (unsigned)n;
        }
        if (actual_crc != expected_crc) goto done;
        offset = next;
        last_flags = header[5];
        pages++;
        if ((last_flags & 4) && offset != length) goto done;
    }
    valid = pages > 0 && offset == length && (last_flags & 4) != 0;
done:
    fclose(file);
    return valid;
}

int ppc_decode_ogg_to_wav(const char *input, const char *output) {
    if (!complete_ogg(input)) return -1;
    int error = 0, result = -1;
    stb_vorbis *decoder = stb_vorbis_open_filename(input, &error, NULL);
    if (!decoder) return error ? error : -1;
    stb_vorbis_info info = stb_vorbis_get_info(decoder);
    int channels = info.channels;
    if (channels < 1 || channels > 2 || info.sample_rate < 8000 || info.sample_rate > 192000) goto done;
    FILE *file = fopen(output, "wb");
    if (!file) goto done;
    if (!wav_header(file, 0, channels, info.sample_rate)) goto close_file;
    short buffer[8192];
    uint64_t bytes = 0;
    unsigned expected_frames = stb_vorbis_stream_length_in_samples(decoder);
    if (!expected_frames) goto close_file;
    for (;;) {
        int frames = stb_vorbis_get_samples_short_interleaved(decoder, channels, buffer, 8192);
        if (frames < 0) goto close_file;
        if (!frames) break;
        size_t count = (size_t)frames * channels * sizeof(short);
        if (bytes + count > UINT32_MAX - 36 || fwrite(buffer, 1, count, file) != count) goto close_file;
        bytes += count;
    }
    if (bytes != (uint64_t)expected_frames * channels * sizeof(short) ||
        stb_vorbis_get_error(decoder) != VORBIS__no_error ||
        fseek(file, 0, SEEK_SET) != 0 ||
        !wav_header(file, (uint32_t)bytes, channels, info.sample_rate)) goto close_file;
    result = 0;
close_file:
    if (fclose(file) != 0) result = -1;
    if (result) remove(output);
done:
    stb_vorbis_close(decoder);
    return result;
}

#ifdef PPC_DECODER_MAIN
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    return ppc_decode_ogg_to_wav(argv[1], argv[2]) == 0 ? 0 : 1;
}
#endif
