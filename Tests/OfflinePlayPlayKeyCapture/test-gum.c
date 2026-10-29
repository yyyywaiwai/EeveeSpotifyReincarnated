#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define PPKC_TESTING 1
#define PPKC_GUM 1

typedef void GumInterceptor;
typedef void GumInvocationListener;
typedef struct { uintptr_t sp; } GumCpuContext;
typedef struct {
    GumCpuContext *cpu_context;
    const void *arguments[6];
} GumInvocationContext;
typedef void *gpointer;
typedef void (*GumInvocationCallback)(GumInvocationContext *, gpointer);
typedef int GumAttachReturn;
enum { GUM_CODE_SIGNING_REQUIRED = 1, GUM_ATTACH_OK = 0,
       GUM_ATTACH_POLICY_VIOLATION = -4 };

static GumInvocationCallback key_probe, prefetch_probe;
static int init_calls, attach_calls, required_policy, listeners_made;
static void gum_init_embedded(void) { ++init_calls; }
static void gum_deinit_embedded(void) { --init_calls; }
static void gum_process_set_code_signing_policy(int policy) { required_policy = policy; }
static GumInterceptor *gum_interceptor_obtain(void) { return (void *)1; }
static GumInvocationListener *gum_make_probe_listener(
    GumInvocationCallback callback, gpointer data, void *destroy) {
    assert(data == NULL && destroy == NULL);
    ++listeners_made;
    if (listeners_made == 1) key_probe = callback;
    else { assert(listeners_made == 2); prefetch_probe = callback; }
    return (void *)(uintptr_t)(listeners_made + 1);
}
static void *gum_invocation_context_get_nth_argument(GumInvocationContext *context,
                                                      unsigned int index) {
    assert(index < 6);
    return (void *)context->arguments[index];
}
static GumAttachReturn gum_interceptor_attach(GumInterceptor *interceptor, void *target,
                                              GumInvocationListener *listener, void *options);
static void g_object_unref(void *object) {
    assert(object == (void *)1 || object == (void *)2 || object == (void *)3);
}

int ppkc_test_graft_matches(int prefetch) {
    (void)prefetch;
#ifdef TEST_KEY_GRAFT_MISMATCH
    if (!prefetch) return 0;
#endif
#ifdef TEST_PREFETCH_GRAFT_MISMATCH
    if (prefetch) return 0;
#endif
    return 1;
}

#include "../../Sources/EeveeSpotifyC/OfflinePlayPlayKeyCapture.m"

static int prefetch_wipe_calls;
void ppkc_test_gum_prefetch_wipe(const uint8_t *file_id, const uint8_t *record) {
    for (size_t i = 0; i < PPKC_FILE_ID_BYTES; ++i) assert(file_id[i] == 0);
    for (size_t i = 0; i < PPKC_RECORD_BYTES; ++i) assert(record[i] == 0);
    ++prefetch_wipe_calls;
}

static GumAttachReturn gum_interceptor_attach(GumInterceptor *interceptor, void *target,
                                              GumInvocationListener *listener, void *options) {
    assert(interceptor == (void *)1 && options == NULL);
    ++attach_calls;
    if ((uintptr_t)target == g_test_base + k_key_call_offset) {
        assert(listener == (void *)2);
#ifdef TEST_ATTACH_FAILURE
        return GUM_ATTACH_POLICY_VIOLATION;
#endif
        return GUM_ATTACH_OK;
    }
    assert((uintptr_t)target == g_test_base + k_prefetch_cache_call_offset);
    assert(listener == (void *)3);
#ifdef TEST_PREFETCH_ATTACH_FAILURE
    return GUM_ATTACH_POLICY_VIOLATION;
#endif
    return GUM_ATTACH_OK;
}

#if !defined(TEST_ATTACH_FAILURE) && !defined(TEST_KEY_GRAFT_MISMATCH)
static void hit(uint8_t owner[0xb0], uint8_t crypto[0x100],
                const uint8_t record[PPKC_RECORD_BYTES], int valid_return, int valid_context) {
    uint8_t frame[0x40] __attribute__((aligned(16))) = {0};
    GumCpuContext cpu = { .sp = (uintptr_t)frame };
    const uint8_t *owner_pointer = owner, *crypto_pointer = crypto;
    uintptr_t return_address = valid_return ? g_callback_return : g_callback_return + 4;
    memcpy(owner + 0x78, &crypto_pointer, sizeof(crypto_pointer));
    memcpy(frame + 0x18, &owner_pointer, sizeof(owner_pointer));
    memcpy(frame + 0x28, &return_address, sizeof(return_address));
    GumInvocationContext context = {
        .cpu_context = &cpu,
        .arguments = { crypto + (valid_context ? 0x78 : 0x70), record }
    };
    key_probe(&context, NULL);
}

static void replayed(uint8_t owner[0x700], uint8_t crypto[0x100],
                     const uint8_t id[PPKC_FILE_ID_BYTES],
                     const uint8_t record[PPKC_RECORD_BYTES],
                     uintptr_t saved_return, int valid_context, uint32_t state,
                     int provider_status) {
    uint8_t frame[0x40] __attribute__((aligned(16))) = {0};
    uint8_t provider_record[PPKC_RECORD_BYTES + sizeof(uint32_t)] = {0};
    GumCpuContext cpu = { .sp = (uintptr_t)frame };
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
    GumInvocationContext context = {
        .cpu_context = &cpu,
        .arguments = { crypto + (valid_context ? 0x78 : 0x70),
                       provider_status < 0 ? owner + 0x59c : provider_record }
    };
    key_probe(&context, NULL);
}

#if !defined(TEST_PREFETCH_ATTACH_FAILURE) && !defined(TEST_PREFETCH_GRAFT_MISMATCH)
static void prefetch_hit(const uint8_t *id, const uint8_t *record, uintptr_t mode) {
    GumInvocationContext context = { .cpu_context = NULL, .arguments = {
        (void *)0x10, (void *)0x20, id, record,
        (void *)mode, (void *)0x1234
    } };
    const void *before[6];
    memcpy(before, context.arguments, sizeof(before));
    prefetch_probe(&context, NULL);
    assert(memcmp(before, context.arguments, sizeof(before)) == 0);
}
#endif
#endif

int main(void) {
    uint32_t key_words[4] = {0x9101e280, 0xaa1303e1, 0x158663b9, 0x94624f91};
    uint32_t prefetch_words[5] = {
        0xaa1503e2, 0xaa1403e3, 0x52800044, 0x15f9af2d, 0x381883bf
    };
    assert(ppkc_graft_words_match(key_words, 0));
    key_words[2] = 0x158663ae; // Previously distributed key-only graft.
    assert(ppkc_graft_words_match(key_words, 0));
    key_words[2] = 0x94000000;
    assert(!ppkc_graft_words_match(key_words, 0));
    assert(ppkc_graft_words_match(prefetch_words, 1));
    prefetch_words[0] ^= 1;
    assert(!ppkc_graft_words_match(prefetch_words, 1));
    prefetch_words[0] ^= 1;
    prefetch_words[3] ^= 1;
    assert(!ppkc_graft_words_match(prefetch_words, 1));
#if defined(TEST_ATTACH_FAILURE) || defined(TEST_KEY_GRAFT_MISMATCH)
    assert(ppkc_install() == 0);
    assert(g_key_listener == NULL && g_interceptor == NULL);
    assert(init_calls == 0);
#ifdef TEST_KEY_GRAFT_MISMATCH
    assert(attach_calls == 0);
#else
    assert(attach_calls == 1);
#endif
#else
    assert(ppkc_install() == 1);
    assert(init_calls == 1 && key_probe != NULL);
#if defined(TEST_PREFETCH_ATTACH_FAILURE) || defined(TEST_PREFETCH_GRAFT_MISMATCH)
    assert(prefetch_probe == NULL || g_prefetch_listener == NULL);
    assert(g_prefetch_listener == NULL);
#else
    assert(prefetch_probe != NULL && g_prefetch_listener != NULL);
#endif
    uint8_t id_a[PPKC_FILE_ID_BYTES], id_b[PPKC_FILE_ID_BYTES];
    uint8_t record_a[PPKC_RECORD_BYTES], record_b[PPKC_RECORD_BYTES];
    for (size_t i = 0; i < sizeof(id_a); ++i) {
        id_a[i] = (uint8_t)(i + 1);
        id_b[i] = (uint8_t)(i + 31);
    }
    for (size_t i = 0; i < sizeof(record_a); ++i) {
        record_a[i] = (uint8_t)(i + 1);
        record_b[i] = (uint8_t)(i + 51);
    }
    uint8_t owner[0x700] = {0}, crypto[0x100] = {0};
    uint8_t consumed[PPKC_RECORD_BYTES] = {0};
    memcpy(owner + 0x90, id_a, sizeof(id_a));
    hit(owner, crypto, record_a, 1, 1);
    memcpy(owner + 0x90, id_b, sizeof(id_b));
    hit(owner, crypto, record_b, 1, 1);
    assert(ppkc_generation() == 2);
    assert(ppkc_has_for_file_id(NULL) == 0);
    assert(ppkc_has_for_file_id(id_a) == 1 && ppkc_has_for_file_id(id_b) == 1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 1);
    assert(memcmp(consumed, record_a, sizeof(record_a)) == 0);
    assert(ppkc_consume_for_file_id(id_b, consumed, NULL) == 1);
    assert(memcmp(consumed, record_b, sizeof(record_b)) == 0);
    assert(ppkc_has_for_file_id(id_a) == 0 && ppkc_has_for_file_id(id_b) == 0);

    // Cached-key replay has no success callback and owner+0x90 was cleared.
    memset(owner + 0x90, 0, PPKC_FILE_ID_BYTES);
    replayed(owner, crypto, id_a, record_a, g_replay_return, 1, 6, -1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 1);
    assert(memcmp(consumed, record_a, sizeof(record_a)) == 0);
    replayed(owner, crypto, id_b, record_b, g_replay_return, 1, 6, -1);
    assert(ppkc_consume_for_file_id(id_b, consumed, NULL) == 1);
    assert(memcmp(consumed, record_b, sizeof(record_b)) == 0);
    replayed(owner, crypto, id_a, record_a, g_replay_return, 1, 6, 2);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 1);
    assert(memcmp(consumed, record_a, sizeof(record_a)) == 0);
    replayed(owner, crypto, id_a, record_a, g_replay_return, 1, 3, 1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 1);
    assert(memcmp(consumed, record_a, sizeof(record_a)) == 0);
    replayed(owner, crypto, id_b, record_b, g_replay_return, 1, 3, 0);
    assert(ppkc_consume_for_file_id(id_b, consumed, NULL) == 1);
    assert(memcmp(consumed, record_b, sizeof(record_b)) == 0);

    replayed(owner, crypto, id_a, record_a, g_replay_return + 4, 1, 6, -1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    replayed(owner, crypto, id_a, record_a, g_replay_return, 0, 6, -1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    replayed(owner, crypto, id_a, record_a, g_replay_return, 1, 3, -1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    replayed(owner, crypto, id_a, record_a, g_replay_return, 1, 6, 1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    replayed(owner, crypto, id_a, record_a, g_replay_return, 1, 3, 2);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    replayed(owner, crypto, id_a, record_a, g_replay_return, 1, 3, 3);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    uint8_t zero_id[PPKC_FILE_ID_BYTES] = {0};
    replayed(owner, crypto, zero_id, record_a, g_replay_return, 1, 3, 1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);

    memcpy(owner + 0x90, id_a, sizeof(id_a));
    hit(owner, crypto, record_a, 0, 1);
    assert(ppkc_has_for_file_id(id_a) == 0);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    hit(owner, crypto, record_a, 1, 0);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    memset(owner + 0x90, 0, PPKC_FILE_ID_BYTES);
    hit(owner, crypto, record_a, 1, 1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 1);
    memcpy(owner + 0x90, id_a, sizeof(id_a));
    hit(owner, crypto, record_a, 1, 1);
    ppkc_clear();
    assert(ppkc_has_for_file_id(id_a) == 0);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_after(0, consumed, NULL) == 0);

#if !defined(TEST_PREFETCH_ATTACH_FAILURE) && !defined(TEST_PREFETCH_GRAFT_MISMATCH)
    uint8_t prefetch_id[PPKC_FILE_ID_BYTES];
    uint8_t prefetch_record[PPKC_RECORD_BYTES];
    uint8_t prefetch_zero_id[PPKC_FILE_ID_BYTES] = {0};
    uint8_t zero_record[PPKC_RECORD_BYTES] = {0};
    for (size_t i = 0; i < sizeof(prefetch_id); ++i) prefetch_id[i] = (uint8_t)(i + 81);
    for (size_t i = 0; i < sizeof(prefetch_record); ++i) prefetch_record[i] = (uint8_t)(i + 141);
    uint64_t start = ppkc_generation();
    prefetch_hit(prefetch_id, prefetch_record, 1);
    prefetch_hit(NULL, prefetch_record, 2);
    prefetch_hit(prefetch_id, NULL, 2);
    prefetch_hit(prefetch_zero_id, prefetch_record, 2);
    prefetch_hit(prefetch_id, zero_record, 2);
    assert(ppkc_generation() == start && prefetch_wipe_calls == 2);
    prefetch_hit(prefetch_id, prefetch_record, 2);
    assert(ppkc_generation() == start + 1 && prefetch_wipe_calls == 3);
    assert(ppkc_has_for_file_id(prefetch_id) == 1);
    assert(ppkc_consume_for_file_id(id_a, consumed, NULL) == 0);
    assert(ppkc_consume_for_file_id(prefetch_id, consumed, NULL) == 1);
    assert(memcmp(consumed, prefetch_record, sizeof(prefetch_record)) == 0);
    assert(ppkc_has_for_file_id(prefetch_id) == 0);
    assert(ppkc_consume_for_file_id(prefetch_id, consumed, NULL) == 0);
#endif
#endif
    assert(ppkc_install() == (init_calls == 1));
#if defined(TEST_ATTACH_FAILURE) || defined(TEST_KEY_GRAFT_MISMATCH)
    assert(attach_calls ==
#ifdef TEST_KEY_GRAFT_MISMATCH
           0
#else
           1
#endif
    );
#elif defined(TEST_PREFETCH_GRAFT_MISMATCH)
    assert(attach_calls == 1);
#else
    assert(attach_calls == 2);
#endif
    if (init_calls != 0) assert(required_policy == GUM_CODE_SIGNING_REQUIRED);
    return 0;
}
