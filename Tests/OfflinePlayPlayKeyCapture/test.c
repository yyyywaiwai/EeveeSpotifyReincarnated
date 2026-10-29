#include <assert.h>
#include <stdint.h>
#include <string.h>

#define PPKC_TESTING 1
#include "../../Sources/EeveeSpotifyC/OfflinePlayPlayKeyCapture.m"

static int install_calls;
static int original_calls;
static ppkc_set_key_fn replacement;
static ppkc_success_fn success_replacement;
static ppkc_prefetch_cache_fn prefetch_replacement;
static const void *different_record;
static int prefetch_original_calls;
static int prefetch_fallback_calls;
static int mutate_prefetch_inputs;
static void *last_cache, *last_metadata;
static const uint8_t *last_file_id, *last_record;
static uint32_t last_mode, last_extra;
static const uintptr_t k_prefetch_result = UINT64_C(0x12345678abcdef09);

static void fake_original_set_key(void *context, const void *record) {
    assert(context != NULL && record != NULL);
    ++original_calls;
}

static void fake_original_success(void *closure, const void *record) {
    const uint8_t *capture = *(const uint8_t *const *)closure;
    const uint8_t *owner = *(const uint8_t *const *)capture;
    if (memcmp(capture + sizeof(void *), owner + 0x90, PPKC_FILE_ID_BYTES)) return;
    g_test_caller = g_playback_return;
    replacement((void *)owner, different_record ? different_record : record);
}

static uintptr_t fake_original_prefetch_cache(void *cache, void *metadata,
                                               const uint8_t *file_id,
                                               const uint8_t *record,
                                               uint32_t mode, uint32_t extra) {
    ++prefetch_original_calls;
    last_cache = cache;
    last_metadata = metadata;
    last_file_id = file_id;
    last_record = record;
    last_mode = mode;
    last_extra = extra;
    if (mutate_prefetch_inputs) {
        memset((void *)file_id, 0, PPKC_FILE_ID_BYTES);
        memset((void *)record, 0, PPKC_RECORD_BYTES);
    }
    return k_prefetch_result;
}

uintptr_t ppkc_test_prefetch_fallback(void *cache, void *metadata,
                                       const uint8_t *file_id, const uint8_t *record,
                                       uint32_t mode, uint32_t extra) {
    ++prefetch_fallback_calls;
    return fake_original_prefetch_cache(cache, metadata, file_id, record, mode, extra);
}

void ppkc_test_hook_function(void *target, void *hook, void **original) {
    ++install_calls;
    if ((uintptr_t)target == g_test_base + k_set_key_offset) {
        replacement = (ppkc_set_key_fn)hook;
        *original = (void *)fake_original_set_key;
    } else if ((uintptr_t)target == g_test_base + k_success_offset) {
        success_replacement = (ppkc_success_fn)hook;
        *original = (void *)fake_original_success;
#ifdef TEST_CALLBACK_ATTACH_FAILURE
        *original = NULL;
#endif
    } else {
        assert((uintptr_t)target == g_test_base + k_prefetch_cache_offset);
        prefetch_replacement = (ppkc_prefetch_cache_fn)hook;
        *original = (void *)fake_original_prefetch_cache;
#ifdef TEST_PREFETCH_ATTACH_FAILURE
        *original = NULL;
#endif
    }
}

static void accepted(uint8_t owner[0xb0], const uint8_t id[PPKC_FILE_ID_BYTES],
                     const uint8_t record[PPKC_RECORD_BYTES]) {
    uint8_t capture[sizeof(void *) + PPKC_FILE_ID_BYTES] = {0};
    memcpy(owner + 0x90, id, PPKC_FILE_ID_BYTES);
    memcpy(capture, &owner, sizeof(void *));
    memcpy(capture + sizeof(void *), id, PPKC_FILE_ID_BYTES);
    void *closure = capture;
    success_replacement(&closure, record);
}

static void replayed(uint8_t owner[0x700], const uint8_t id[PPKC_FILE_ID_BYTES],
                     const uint8_t record[PPKC_RECORD_BYTES],
                     uintptr_t saved_return, int valid_context, uint32_t state,
                     int provider_status) {
    uint8_t frame[0x40] __attribute__((aligned(16))) = {0};
    uint8_t crypto[0x100] = {0};
    uint8_t provider_record[PPKC_RECORD_BYTES + sizeof(uint32_t)] = {0};
    const uint8_t *owner_pointer = owner, *crypto_pointer = crypto;
    uint32_t record_status = provider_status < 0 ? 0 : (uint32_t)provider_status;
    memcpy(frame + 0x18, &owner_pointer, sizeof(owner_pointer));
    memcpy(frame + 0x28, &saved_return, sizeof(saved_return));
    memcpy(owner + 0x78, &crypto_pointer, sizeof(crypto_pointer));
    memcpy(owner + 0x160, id, PPKC_FILE_ID_BYTES);
    memcpy(owner + 0x1c0, &state, sizeof(state));
    memcpy(owner + 0x59c, record, PPKC_RECORD_BYTES);
    memcpy(provider_record, record, PPKC_RECORD_BYTES);
    memcpy(provider_record + PPKC_RECORD_BYTES, &record_status, sizeof(record_status));
    g_test_caller = g_playback_return;
    g_test_entry_sp = frame;
    replacement(crypto + (valid_context ? 0x78 : 0x70),
                provider_status < 0 ? owner + 0x59c : provider_record);
    g_test_entry_sp = NULL;
}

#if !defined(TEST_PREFETCH_SIGNATURE_FAILURE)
static void call_prefetch(void *cache, void *metadata, const uint8_t *file_id,
                          const uint8_t *record, uint32_t mode, uint32_t extra) {
    int before = prefetch_original_calls;
    uintptr_t result = prefetch_replacement(cache, metadata, file_id, record,
                                             mode, extra);
    assert(prefetch_original_calls == before + 1);
    assert(result == k_prefetch_result);
    assert(last_cache == cache && last_metadata == metadata);
    assert(last_file_id == file_id && last_record == record);
    assert(last_mode == mode && last_extra == extra);
}
#endif

int main(void) {
#ifdef TEST_PREFETCH_SIGNATURE_FAILURE
    g_test_bad_prefetch_fingerprint = 1;
#endif
#ifdef TEST_CALLBACK_ATTACH_FAILURE
    assert(ppkc_install() == 0 && ppkc_install() == 0);
    assert(install_calls == 2);
    return 0;
#endif
    assert(ppkc_install() == 1 && ppkc_install() == 1);
    assert(install_calls == (g_test_bad_prefetch_fingerprint ? 2 : 3));
    assert(replacement && success_replacement);
    assert(ppkc_generation() == 0);
    assert(ppkc_has_for_file_id(NULL) == 0);

    uint8_t id_a[PPKC_FILE_ID_BYTES], id_b[PPKC_FILE_ID_BYTES];
    uint8_t record_a[PPKC_RECORD_BYTES], record_b[PPKC_RECORD_BYTES];
    for (size_t i = 0; i < sizeof(id_a); ++i) {
        id_a[i] = (uint8_t)(i + 1);
        id_b[i] = (uint8_t)(i + 51);
    }
    for (size_t i = 0; i < sizeof(record_a); ++i) {
        record_a[i] = (uint8_t)(i + 1);
        record_b[i] = (uint8_t)(i + 101);
    }
    uint8_t owner[0x700] = {0};
    uint8_t consumed[PPKC_RECORD_BYTES] = {0};
    uint64_t generation = 0;

    // The old entry remains available, but an unbound setter is never ID-bound.
    g_test_caller = g_playback_return;
    replacement(owner, record_a);
    assert(ppkc_generation() == 1);
    assert(ppkc_has_for_file_id(id_a) == 0);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, &generation) == 1);
    assert(generation == 1 && memcmp(consumed, record_a, sizeof(record_a)) == 0);

    accepted(owner, id_a, record_a);
    assert(ppkc_generation() == 2);
    assert(ppkc_has_for_file_id(id_a) == 1);
    assert(ppkc_has_for_file_id(id_a) == 1 && ppkc_generation() == 2);
    assert(ppkc_has_for_file_id(id_b) == 0);
    assert(ppkc_consume_for_file_id(id_b, consumed, NULL) == 0);
    assert(ppkc_consume_for_file_id(id_a, consumed, &generation) == 1);
    assert(generation == 2 && memcmp(consumed, record_a, sizeof(record_a)) == 0);
    assert(ppkc_has_for_file_id(id_a) == 0);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);

    // A rejected callback does not reach the native setter or enter the index.
    uint8_t capture[sizeof(void *) + PPKC_FILE_ID_BYTES] = {0};
    memcpy(owner + 0x90, id_a, sizeof(id_a));
    uint8_t *owner_pointer = owner;
    memcpy(capture, &owner_pointer, sizeof(owner_pointer));
    memcpy(capture + sizeof(void *), id_b, sizeof(id_b));
    void *closure = capture;
    success_replacement(&closure, record_b);
    assert(ppkc_generation() == 2);

    accepted(owner, id_a, record_a);
    accepted(owner, id_b, record_b);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 1);
    assert(memcmp(consumed, record_a, sizeof(record_a)) == 0);
    assert(ppkc_consume_for_file_id(id_b, consumed, NULL) == 1);
    assert(memcmp(consumed, record_b, sizeof(record_b)) == 0);

    // A replayed key has no success callback/TLS scope. Spotify may use the
    // owner cache or provider status 0/1/2 at the same wrapper call.
    replayed(owner, id_a, record_a, g_replay_return, 1, 6, -1);
    assert(ppkc_consume_for_file_id(id_b, consumed, NULL) == 0);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 1);
    assert(memcmp(consumed, record_a, sizeof(record_a)) == 0);
    replayed(owner, id_b, record_b, g_replay_return, 1, 6, -1);
    assert(ppkc_consume_for_file_id(id_b, consumed, NULL) == 1);
    assert(memcmp(consumed, record_b, sizeof(record_b)) == 0);
    replayed(owner, id_a, record_a, g_replay_return, 1, 6, 2);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 1);
    assert(memcmp(consumed, record_a, sizeof(record_a)) == 0);
    replayed(owner, id_a, record_a, g_replay_return, 1, 3, 1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 1);
    assert(memcmp(consumed, record_a, sizeof(record_a)) == 0);
    replayed(owner, id_b, record_b, g_replay_return, 1, 3, 0);
    assert(ppkc_consume_for_file_id(id_b, consumed, NULL) == 1);
    assert(memcmp(consumed, record_b, sizeof(record_b)) == 0);

    // All guards fail closed. The unbound legacy record remains consumable.
    replayed(owner, id_a, record_a, g_replay_return + 4, 1, 6, -1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    replayed(owner, id_a, record_a, g_replay_return, 0, 6, -1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    replayed(owner, id_a, record_a, g_replay_return, 1, 3, -1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    replayed(owner, id_a, record_a, g_replay_return, 1, 6, 1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    replayed(owner, id_a, record_a, g_replay_return, 1, 3, 2);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    replayed(owner, id_a, record_a, g_replay_return, 1, 3, 3);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    uint8_t zero_id[PPKC_FILE_ID_BYTES] = {0};
    replayed(owner, zero_id, record_a, g_replay_return, 1, 3, 1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);

    // A setter receiving a different record pointer is not attributed.
    different_record = record_b;
    accepted(owner, id_a, record_a);
    different_record = NULL;
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    assert(memcmp(consumed, record_b, sizeof(record_b)) == 0);

    accepted(owner, id_a, record_a);
    ppkc_clear();
    assert(ppkc_has_for_file_id(id_a) == 0);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 0);
    uint8_t empty_slots[sizeof(g_slots)] = {0};
    assert(memcmp(g_slots, empty_slots, sizeof(g_slots)) == 0);

    accepted(owner, id_a, record_a);
    accepted(owner, id_a, record_b);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 1);
    assert(memcmp(consumed, record_b, sizeof(record_b)) == 0);

    uint8_t ids[PPKC_SLOTS + 1][PPKC_FILE_ID_BYTES];
    uint8_t records[PPKC_SLOTS + 1][PPKC_RECORD_BYTES];
    for (size_t i = 0; i < PPKC_SLOTS + 1; ++i) {
        memset(ids[i], (int)i + 1, sizeof(ids[i]));
        memset(records[i], (int)i + 31, sizeof(records[i]));
        accepted(owner, ids[i], records[i]);
    }
    assert(ppkc_has_for_file_id(ids[0]) == 0);
    for (size_t i = 1; i < PPKC_SLOTS + 1; ++i)
        assert(ppkc_has_for_file_id(ids[i]) == 1);
    assert(ppkc_consume_for_file_id(ids[0], consumed, NULL) == 0);
    for (size_t i = 1; i < PPKC_SLOTS + 1; ++i) {
        assert(ppkc_consume_for_file_id(ids[i], consumed, NULL) == 1);
        assert(memcmp(consumed, records[i], PPKC_RECORD_BYTES) == 0);
    }
    assert(original_calls == (int)ppkc_generation());

#if defined(TEST_PREFETCH_ATTACH_FAILURE) || defined(TEST_PREFETCH_SIGNATURE_FAILURE)
    assert(g_original_prefetch_cache == NULL);
    assert(ppkc_install() == 1); // Playback capture still works.
#ifdef TEST_PREFETCH_SIGNATURE_FAILURE
    assert(prefetch_replacement == NULL && install_calls == 2);
#else
    assert(prefetch_replacement != NULL && install_calls == 3);
    // Simulate ElleKit patching the entry but returning a NULL trampoline.
    uint8_t prefetch_id[PPKC_FILE_ID_BYTES], prefetch_record[PPKC_RECORD_BYTES];
    uint8_t prefetch_zero_id[PPKC_FILE_ID_BYTES] = {0};
    memset(prefetch_id, 0x31, sizeof(prefetch_id));
    memset(prefetch_record, 0x42, sizeof(prefetch_record));
    uint64_t before_prefetch = ppkc_generation();
    g_test_prefetch_caller = g_prefetch_cache_return + 4;
    call_prefetch(owner, &generation, prefetch_id, prefetch_record, 2, 0xa1b2c3d4);
    g_test_prefetch_caller = g_prefetch_cache_return;
    call_prefetch(owner, &generation, prefetch_id, prefetch_record, 1, 0xe5f60718);
    call_prefetch(owner, &generation, prefetch_zero_id, prefetch_record, 2, 17);
    assert(ppkc_generation() == before_prefetch);
    call_prefetch(owner, &generation, prefetch_id, prefetch_record, 2, 0xfeedbeef);
    assert(ppkc_generation() == before_prefetch + 1);
    assert(ppkc_consume_for_file_id(prefetch_id, consumed, NULL) == 1);
    assert(memcmp(consumed, prefetch_record, sizeof(prefetch_record)) == 0);
    assert(prefetch_fallback_calls == 4);
#endif
#else
    assert(prefetch_replacement && g_original_prefetch_cache);
    uint8_t prefetch_id[PPKC_FILE_ID_BYTES], prefetch_record[PPKC_RECORD_BYTES];
    uint8_t expected_id[PPKC_FILE_ID_BYTES], expected_record[PPKC_RECORD_BYTES];
    uint8_t zeros_id[PPKC_FILE_ID_BYTES] = {0};
    uint8_t zeros_record[PPKC_RECORD_BYTES] = {0};
    for (size_t i = 0; i < sizeof(prefetch_id); ++i) prefetch_id[i] = (uint8_t)(201 + i);
    for (size_t i = 0; i < sizeof(prefetch_record); ++i)
        prefetch_record[i] = (uint8_t)(121 + i);
    memcpy(expected_id, prefetch_id, sizeof(expected_id));
    memcpy(expected_record, prefetch_record, sizeof(expected_record));
    uint64_t before_prefetch = ppkc_generation();

    g_test_prefetch_caller = g_prefetch_cache_return + 4;
    call_prefetch(owner, &generation, prefetch_id, prefetch_record, 2, 0xa1b2c3d4);
    g_test_prefetch_caller = g_prefetch_cache_return;
    call_prefetch(owner, &generation, prefetch_id, prefetch_record, 1, 0xe5f60718);
    call_prefetch(owner, &generation, zeros_id, prefetch_record, 2, 17);
    call_prefetch(owner, &generation, prefetch_id, zeros_record, 2, 19);
    call_prefetch(owner, &generation, NULL, prefetch_record, 2, 23);
    call_prefetch(owner, &generation, prefetch_id, NULL, 2, 29);
    assert(ppkc_generation() == before_prefetch);
    assert(ppkc_consume_for_file_id(prefetch_id, consumed, NULL) == 0);

    mutate_prefetch_inputs = 1;
    call_prefetch(owner, &generation, prefetch_id, prefetch_record, 2, 0xfeedbeef);
    mutate_prefetch_inputs = 0;
    assert(memcmp(prefetch_id, zeros_id, sizeof(prefetch_id)) == 0);
    assert(memcmp(prefetch_record, zeros_record, sizeof(prefetch_record)) == 0);
    assert(ppkc_generation() == before_prefetch + 1);
    assert(ppkc_consume_for_file_id(expected_id, consumed, NULL) == 1);
    assert(memcmp(consumed, expected_record, sizeof(expected_record)) == 0);
    assert(ppkc_consume_for_file_id(expected_id, consumed, NULL) == 0);
    assert(g_test_prefetch_wiped == 1);

    memcpy(prefetch_id, expected_id, sizeof(prefetch_id));
    memcpy(prefetch_record, expected_record, sizeof(prefetch_record));
    prefetch_record[0] ^= 0x5a;
    call_prefetch(owner, &generation, prefetch_id, prefetch_record, 2, 31);
    call_prefetch(owner, &generation, prefetch_id, expected_record, 2, 37);
    assert(ppkc_consume_for_file_id(expected_id, consumed, NULL) == 1);
    assert(memcmp(consumed, expected_record, sizeof(expected_record)) == 0);
    assert(ppkc_consume_for_file_id(expected_id, consumed, NULL) == 0);
    assert(g_test_prefetch_wiped == 1);
#endif
    return 0;
}
