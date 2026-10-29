#include "include/OfflinePlayPlayKeyCapture.h"

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifndef PPKC_TESTING
#include <CoreFoundation/CoreFoundation.h>
#ifndef PPKC_GUM
#include <dlfcn.h>
#endif
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#endif
#if defined(PPKC_GUM) && !defined(PPKC_TESTING)
#include <frida-gum.h>
#endif

#ifndef PPKC_GUM
// Native setter: Spotify+0x5BFED98(ctx, keyRecord). The observed active
// playback caller returns to Spotify+0x865F14C; a second unrelated call site
// exists, so only the active-playback caller is captured.
typedef void (*ppkc_set_key_fn)(void *, const void *);
typedef void (*ppkc_success_fn)(void *, const void *);
typedef uintptr_t (*ppkc_prefetch_cache_fn)(void *, void *, const uint8_t *,
                                            const uint8_t *, uint32_t, uint32_t);
typedef void (*ppkc_hook_function_fn)(void *, void *, void **);

static const uintptr_t k_set_key_offset = 0x5bfed98;
static const uintptr_t k_playback_return_offset = 0x865f14c;
// The successful callback's closure points to {owner, 20-byte file ID, ...}.
// It directly calls the playback setter only after Spotify's stale-ID check.
static const uintptr_t k_success_offset = 0x146ce34;
// Accepted prefetch success invokes the six-argument cache helper only after
// its stale-ID and nonzero-record checks.
static const uintptr_t k_prefetch_cache_offset = 0x8532120;
static const uintptr_t k_prefetch_cache_return_offset = 0x698c350;
#else
// The IPA is grafted at the active caller's BL, where X1 holds the record.
static const uintptr_t k_key_call_offset = 0x865f148;
// Prefetch success calls the key-cache helper only after its own stale-ID and
// nonzero-record checks. At this BL, X2 is the ID, X3 the record, W4 is 2.
static const uintptr_t k_prefetch_cache_call_offset = 0x698c34c;
#endif
// The same wrapper is called both after a fresh PlayPlay completion and when
// the stream owner reapplies its cached record at owner+0x59c. Its saved LR
// distinguishes those two cases; the setter's immediate LR does not.
static const uintptr_t k_callback_return_offset = 0x146ceac;
static const uintptr_t k_replay_return_offset = 0x18f5460;
#ifndef PPKC_TESTING
static const uint8_t k_spotify_uuid[16] = {
    0xf5, 0x1d, 0xbd, 0x93, 0x3b, 0x8f, 0x3a, 0x12,
    0x94, 0x31, 0x96, 0xc6, 0x06, 0xe3, 0xaf, 0xc2
};
#endif

static pthread_once_t g_install_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_record_mutex = PTHREAD_MUTEX_INITIALIZER;
#ifndef PPKC_GUM
static ppkc_set_key_fn g_original_set_key;
static ppkc_success_fn g_original_success;
static ppkc_prefetch_cache_fn g_original_prefetch_cache;
#ifndef PPKC_TESTING
// Set before installing the optional hook: ElleKit can patch the entry even
// when it fails to return an original trampoline.
__attribute__((used)) static uintptr_t g_prefetch_resume;
#endif
static uintptr_t g_playback_return;
static uintptr_t g_prefetch_cache_return;
#endif
static uintptr_t g_callback_return;
static uintptr_t g_replay_return;
enum { PPKC_SLOTS = 8 };
typedef struct {
    uint8_t file_id[PPKC_FILE_ID_BYTES];
    uint8_t record[PPKC_RECORD_BYTES];
    uint64_t generation;
    int occupied;
    int attributed;
} ppkc_slot;
#ifndef PPKC_GUM
typedef struct {
    uint8_t file_id[PPKC_FILE_ID_BYTES];
    const void *record;
    int valid;
} ppkc_scope;
#endif
static ppkc_slot g_slots[PPKC_SLOTS];
#ifndef PPKC_GUM
static _Thread_local ppkc_scope g_scope;
#endif
static uint64_t g_generation;
static int g_installed;

static void ppkc_wipe(void *memory, size_t length) {
    volatile uint8_t *bytes = (volatile uint8_t *)memory;
    while (length--) *bytes++ = 0;
}

#ifndef PPKC_TESTING
static int ppkc_matching_bundle(void) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle) return 0;
    CFTypeRef version = CFBundleGetValueForInfoDictionaryKey(
        bundle, CFSTR("CFBundleShortVersionString"));
    CFTypeRef build = CFBundleGetValueForInfoDictionaryKey(
        bundle, CFSTR("CFBundleVersion"));
    return version && build &&
        CFGetTypeID(version) == CFStringGetTypeID() &&
        CFGetTypeID(build) == CFStringGetTypeID() &&
        CFStringCompare((CFStringRef)version, CFSTR("9.1.88"), 0) == kCFCompareEqualTo &&
        CFStringCompare((CFStringRef)build, CFSTR("918802209"), 0) == kCFCompareEqualTo;
}

static uintptr_t ppkc_spotify_base(void) {
    if (!ppkc_matching_bundle()) return 0;
    for (uint32_t image = 0; image < _dyld_image_count(); ++image) {
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(image);
        const char *image_name = _dyld_get_image_name(image);
        if (!header || !image_name || !strstr(image_name, "/Spotify.app/Spotify") ||
            header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 ||
            header->filetype != MH_EXECUTE) continue;

        const uint8_t *command = (const uint8_t *)(header + 1);
        const uint8_t *end = command + header->sizeofcmds;
        for (uint32_t index = 0; index < header->ncmds; ++index) {
            if (command > end || (size_t)(end - command) < sizeof(struct load_command)) return 0;
            const struct load_command *load = (const struct load_command *)command;
            if (load->cmdsize < sizeof(*load) || load->cmdsize > (size_t)(end - command)) return 0;
            if (load->cmd == LC_UUID && load->cmdsize >= sizeof(struct uuid_command)) {
                if (memcmp(((const struct uuid_command *)load)->uuid,
                           k_spotify_uuid, sizeof(k_spotify_uuid))) return 0;
                return (uintptr_t)header;
            }
            command += load->cmdsize;
        }
    }
    return 0;
}
#else
static uintptr_t g_test_base = 0x100000000;
#ifndef PPKC_GUM
static uintptr_t g_test_caller;
static uintptr_t g_test_prefetch_caller;
static int g_test_bad_prefetch_fingerprint;
static const void *g_test_entry_sp;
extern void ppkc_test_hook_function(void *, void *, void **);
#endif
static uintptr_t ppkc_spotify_base(void) { return g_test_base; }
#endif

#ifndef PPKC_GUM
static int ppkc_prefetch_fingerprint(uintptr_t base) {
#ifdef PPKC_TESTING
    (void)base;
    return !g_test_bad_prefetch_fingerprint;
#else
    static const struct { uintptr_t offset; uint32_t instruction; } expected[] = {
        { 0x698c310, 0x34000a60 }, // stale-ID rejection
        { 0x698c324, 0xf100711f }, // 28-byte nonzero scan
        { 0x698c318, 0xb94032c5 }, // w5 comes from the capture
        { 0x698c340, 0xaa1503e2 }, // x2 = 20-byte ID
        { 0x698c344, 0xaa1403e3 }, // x3 = 28-byte record
        { 0x698c348, 0x52800044 }, // w4 = 2
        { 0x698c34c, 0x946e9775 }, // BL cache helper
        { 0x8532120, 0xd10083ff }, // cache helper prologue
        { 0x8532124, 0xa9017bfd }, // stp x29, x30, [sp, #0x10]
        { 0x8532128, 0x910043fd }, // add x29, sp, #0x10
        { 0x853212c, 0xb81fc3a4 }, // stur w4, [x29, #-4]
        { 0x8532130, 0xb9000be5 }, // helper forwards w5
    };
    for (size_t i = 0; i < sizeof(expected) / sizeof(expected[0]); ++i) {
        uint32_t actual;
        memcpy(&actual, (const void *)(base + expected[i].offset), sizeof(actual));
        if (actual != expected[i].instruction) return 0;
    }
    return 1;
#endif
}

static void ppkc_scope_enter(const void *closure, const void *record,
                             ppkc_scope *previous) {
    *previous = g_scope;
    ppkc_wipe(&g_scope, sizeof(g_scope));
    if (!closure || !record) return;
    const uint8_t *capture = *(const uint8_t *const *)closure;
    if (!capture) return;
    memcpy(g_scope.file_id, capture + sizeof(void *), PPKC_FILE_ID_BYTES);
    g_scope.record = record;
    g_scope.valid = 1;
}

static void ppkc_scope_leave(ppkc_scope *previous) {
    ppkc_wipe(&g_scope, sizeof(g_scope));
    g_scope = *previous;
    ppkc_wipe(previous, sizeof(*previous));
}
#endif

// Wrapper +0x865f128 saved incoming x19 (stream owner) at its SP+0x18 and
// caller LR at SP+0x28. The fresh callback reads owner+0x90; replay uses the
// cached record at owner+0x59c or a provider record with status 0..2, alongside
// the active 20-byte ID at owner+0x160.
static int ppkc_id_from_wrapper_frame(const void *context, const void *record,
                                      const void *entry_sp,
                                      uint8_t out_id[PPKC_FILE_ID_BYTES]) {
    if (!entry_sp || ((uintptr_t)entry_sp & 15)) return 0;
    const uint8_t *frame = (const uint8_t *)entry_sp;
    uintptr_t caller;
    memcpy(&caller, frame + 0x28, sizeof(caller));
    if (caller != g_callback_return && caller != g_replay_return) return 0;

    const uint8_t *owner;
    memcpy(&owner, frame + 0x18, sizeof(owner));
    if (!owner) return 0;
    const uint8_t *crypto;
    memcpy(&crypto, owner + 0x78, sizeof(crypto));
    if (!crypto || crypto + 0x78 != context) return 0;

    const uint8_t *candidate;
    if (caller == g_callback_return) {
        candidate = owner + 0x90;
    } else {
        uint32_t state;
        memcpy(&state, owner + 0x1c0, sizeof(state));
        if (!record) return 0;
        if (record == owner + 0x59c) {
            if (state != 6) return 0;
        } else {
            // +0x18f5398 and +0x18f53d0 classify provider statuses 0..2.
            // +0x18f5420 selects state 6 only for status 2, otherwise 3;
            // all three cases call this same key setter at +0x18f545c.
            uint32_t record_status;
            memcpy(&record_status, (const uint8_t *)record + 0x1c,
                   sizeof(record_status));
            if (record_status > 2 || state != (record_status == 2 ? 6u : 3u))
                return 0;
        }
        candidate = owner + 0x160;
    }
    uint8_t any = 0;
    for (size_t i = 0; i < PPKC_FILE_ID_BYTES; ++i) any |= candidate[i];
    if (!any) return 0;
    memcpy(out_id, candidate, PPKC_FILE_ID_BYTES);
    return 1;
}

static void ppkc_store_record(const void *key_record,
                              const uint8_t file_id[PPKC_FILE_ID_BYTES]) {
    if (!key_record) return;
    pthread_mutex_lock(&g_record_mutex);
    int attributed = file_id != NULL;
    size_t slot = PPKC_SLOTS;
    if (attributed) {
        for (size_t i = 0; i < PPKC_SLOTS; ++i) {
            if (g_slots[i].occupied && g_slots[i].attributed &&
                memcmp(g_slots[i].file_id, file_id, PPKC_FILE_ID_BYTES) == 0) {
                slot = i;
                break;
            }
        }
    }
    if (slot == PPKC_SLOTS) {
        for (size_t i = 0; i < PPKC_SLOTS; ++i) {
            if (!g_slots[i].occupied) { slot = i; break; }
        }
    }
    if (slot == PPKC_SLOTS) {
        slot = 0;
        for (size_t i = 1; i < PPKC_SLOTS; ++i)
            if (g_slots[i].generation < g_slots[slot].generation) slot = i;
    }
    ppkc_wipe(&g_slots[slot], sizeof(g_slots[slot]));
    memcpy(g_slots[slot].record, key_record, PPKC_RECORD_BYTES);
    if (attributed) memcpy(g_slots[slot].file_id, file_id, PPKC_FILE_ID_BYTES);
    ++g_generation;
    g_slots[slot].generation = g_generation;
    g_slots[slot].occupied = 1;
    g_slots[slot].attributed = attributed;
    pthread_mutex_unlock(&g_record_mutex);
}

#ifdef PPKC_GUM
static GumInterceptor *g_interceptor;
static GumInvocationListener *g_key_listener;
static GumInvocationListener *g_prefetch_listener;

#ifdef PPKC_TESTING
extern int ppkc_test_graft_matches(int prefetch);
extern void ppkc_test_gum_prefetch_wipe(const uint8_t *file_id,
                                        const uint8_t *record);
#endif
// Key words span callsite[-8, +4]; prefetch also checks X2's ID setup at -12.
static int ppkc_graft_words_match(const uint32_t *words, int prefetch) {
    if (prefetch)
        return words[0] == 0xaa1503e2 && words[1] == 0xaa1403e3 &&
               words[2] == 0x52800044 && words[3] == 0x15f9af2d &&
               words[4] == 0x381883bf;
    return words[0] == 0x9101e280 && words[1] == 0xaa1303e1 &&
           (words[2] == 0x158663b9 || words[2] == 0x158663ae) &&
           words[3] == 0x94624f91;
}
static int ppkc_graft_matches(uintptr_t base, int prefetch) {
#ifdef PPKC_TESTING
    (void)base;
    return ppkc_test_graft_matches(prefetch);
#else
    uint32_t words[5];
    const uintptr_t offset = prefetch ? k_prefetch_cache_call_offset : k_key_call_offset;
    memcpy(words, (const void *)(base + offset - (prefetch ? 12 : 8)),
           prefetch ? 20 : 16);
    return ppkc_graft_words_match(words, prefetch);
#endif
}

static void ppkc_key_call_probe(GumInvocationContext *context, gpointer user_data) {
    (void)user_data;
    const void *record = gum_invocation_context_get_nth_argument(context, 1);
    uint8_t local_id[PPKC_FILE_ID_BYTES] = {0};
    const uint8_t *file_id = NULL;
    const void *entry_sp = context->cpu_context ?
        (const void *)(uintptr_t)context->cpu_context->sp : NULL;
    if (ppkc_id_from_wrapper_frame(gum_invocation_context_get_nth_argument(context, 0),
                                   record, entry_sp, local_id)) file_id = local_id;
    ppkc_store_record(record, file_id);
    ppkc_wipe(local_id, sizeof(local_id));
}

static void ppkc_prefetch_cache_call_probe(GumInvocationContext *context,
                                            gpointer user_data) {
    // IPA/Gum probes the accepted callback's BL before Spotify's cache helper
    // runs. This records the input pair, not proof that the helper persisted it.
    (void)user_data;
    if ((uintptr_t)gum_invocation_context_get_nth_argument(context, 4) != 2) return;
    const uint8_t *file_id = gum_invocation_context_get_nth_argument(context, 2);
    const uint8_t *record = gum_invocation_context_get_nth_argument(context, 3);
    if (!file_id || !record) return;
    uint8_t local_id[PPKC_FILE_ID_BYTES], local_record[PPKC_RECORD_BYTES];
    uint8_t any_id = 0, any_record = 0;
    memcpy(local_id, file_id, sizeof(local_id));
    memcpy(local_record, record, sizeof(local_record));
    for (size_t i = 0; i < sizeof(local_id); ++i) any_id |= local_id[i];
    for (size_t i = 0; i < sizeof(local_record); ++i) any_record |= local_record[i];
    if (any_id && any_record) ppkc_store_record(local_record, local_id);
    ppkc_wipe(local_record, sizeof(local_record));
    ppkc_wipe(local_id, sizeof(local_id));
#ifdef PPKC_TESTING
    ppkc_test_gum_prefetch_wipe(local_id, local_record);
#endif
}
#else
__attribute__((noinline))
static void ppkc_success_hook(void *closure, const void *key_record) {
    ppkc_success_fn original = g_original_success;
    if (!original) return;
    ppkc_scope previous;
    ppkc_scope_enter(closure, key_record, &previous);
    original(closure, key_record);
    ppkc_scope_leave(&previous);
}

// The replacement must pass the *entry* SP, not its own compiler-created
// frame. Tail branching preserves the setter's original x0/x1 and LR.
__attribute__((noinline, used))
static void ppkc_set_key_hook_impl(void *context, const void *key_record,
                                   const void *entry_sp, uintptr_t return_address) {
    ppkc_set_key_fn original = g_original_set_key;
    // MSHookFunction promises an original trampoline. If that promise is not
    // met, do not read arbitrary memory or recurse through the patched entry.
    if (!original) return;

    int playback_caller = return_address == g_playback_return;
    uint8_t local_record[PPKC_RECORD_BYTES];
    uint8_t local_id[PPKC_FILE_ID_BYTES] = {0};
    int attributed = playback_caller && g_scope.valid && g_scope.record == key_record;
    if (playback_caller && key_record)
        memcpy(local_record, key_record, sizeof(local_record));
    if (attributed) memcpy(local_id, g_scope.file_id, sizeof(local_id));
    // A cached-key replay does not invoke the PlayPlay success callback, so
    // TLS is absent even though the setter has a valid 28-byte record. Bind it
    // only through the verified wrapper frame and its distinct saved LR.
    else if (playback_caller && !g_scope.valid && key_record)
        attributed = ppkc_id_from_wrapper_frame(context, key_record, entry_sp, local_id);

    original(context, key_record);

    if (playback_caller && key_record) {
        ppkc_store_record(local_record, attributed ? local_id : NULL);
        ppkc_wipe(local_record, sizeof(local_record));
    }
    ppkc_wipe(local_id, sizeof(local_id));
}

#ifdef PPKC_TESTING
static void ppkc_set_key_hook(void *context, const void *key_record) {
    ppkc_set_key_hook_impl(context, key_record, g_test_entry_sp, g_test_caller);
}
#else
__attribute__((naked, noinline))
static void ppkc_set_key_hook(void *context, const void *key_record) {
    __asm__ volatile("mov x2, sp\n"
                     "mov x3, x30\n"
                     "b _ppkc_set_key_hook_impl\n");
}
#endif

#ifdef PPKC_TESTING
static int g_test_prefetch_wiped = 1;
extern uintptr_t ppkc_test_prefetch_fallback(void *, void *, const uint8_t *,
                                              const uint8_t *, uint32_t, uint32_t);
static uintptr_t ppkc_prefetch_cache_fallback(void *cache, void *metadata,
                                               const uint8_t *file_id,
                                               const uint8_t *record,
                                               uint32_t mode, uint32_t extra) {
    return ppkc_test_prefetch_fallback(cache, metadata, file_id, record,
                                        mode, extra);
}
#else
// ElleKit can return NULL after patching the target. Its arm64 patch replaces
// at most the first four instructions, so replay this exact, fingerprinted
// prologue and resume at +0x10. The remaining wrapper calls Spotify's helper
// and returns normally; no call through the patched entry or guessed ABI.
__attribute__((naked, noinline, used))
static uintptr_t ppkc_prefetch_cache_fallback(
    void *cache __attribute__((unused)), void *metadata __attribute__((unused)),
    const uint8_t *file_id __attribute__((unused)),
    const uint8_t *record __attribute__((unused)),
    uint32_t mode __attribute__((unused)), uint32_t extra __attribute__((unused))) {
    __asm__ volatile(".inst 0xd10083ff\n" // sub sp, sp, #0x20
                     ".inst 0xa9017bfd\n" // stp x29, x30, [sp, #0x10]
                     ".inst 0x910043fd\n" // add x29, sp, #0x10
                     ".inst 0xb81fc3a4\n" // stur w4, [x29, #-4]
                     "adrp x16, _g_prefetch_resume@PAGE\n"
                     "add x16, x16, _g_prefetch_resume@PAGEOFF\n"
                     "ldar x16, [x16]\n"
                     "br x16\n");
}
#endif

__attribute__((noinline, used))
static uintptr_t ppkc_prefetch_cache_hook_impl(void *cache, void *metadata,
                                               const uint8_t *file_id,
                                               const uint8_t *record,
                                               uint32_t mode, uint32_t extra,
                                               uintptr_t return_address) {
    // A patched entry can run on another thread before MSHookFunction returns
    // its trampoline. The NULL case uses the prologue-replay fallback below.
    ppkc_prefetch_cache_fn original =
        __atomic_load_n(&g_original_prefetch_cache, __ATOMIC_ACQUIRE);
    if (!original) original = ppkc_prefetch_cache_fallback;
    if (return_address != g_prefetch_cache_return || mode != 2 ||
        !file_id || !record)
        return original(cache, metadata, file_id, record, mode, extra);

    uint8_t local_id[PPKC_FILE_ID_BYTES];
    uint8_t local_record[PPKC_RECORD_BYTES];
    uint8_t id_any = 0, record_any = 0;
    memcpy(local_id, file_id, sizeof(local_id));
    memcpy(local_record, record, sizeof(local_record));
    for (size_t i = 0; i < sizeof(local_id); ++i) id_any |= local_id[i];
    for (size_t i = 0; i < sizeof(local_record); ++i) record_any |= local_record[i];

    uintptr_t result = original(cache, metadata, file_id, record, mode, extra);
    // Rootless publishes only after the helper returns. Its non-void result is
    // forwarded unchanged; return alone still does not prove durable caching.
    if (id_any && record_any) ppkc_store_record(local_record, local_id);
    ppkc_wipe(local_id, sizeof(local_id));
    ppkc_wipe(local_record, sizeof(local_record));
#ifdef PPKC_TESTING
    for (size_t i = 0; i < sizeof(local_id); ++i)
        if (local_id[i]) g_test_prefetch_wiped = 0;
    for (size_t i = 0; i < sizeof(local_record); ++i)
        if (local_record[i]) g_test_prefetch_wiped = 0;
#endif
    return result;
}

#ifdef PPKC_TESTING
static uintptr_t ppkc_prefetch_cache_hook(void *cache, void *metadata,
                                           const uint8_t *file_id,
                                           const uint8_t *record,
                                           uint32_t mode, uint32_t extra) {
    return ppkc_prefetch_cache_hook_impl(cache, metadata, file_id, record, mode,
                                          extra, g_test_prefetch_caller);
}
#else
// The helper has six arguments. X6 carries the original LR without changing X5.
__attribute__((naked, noinline))
static uintptr_t ppkc_prefetch_cache_hook(void *cache, void *metadata,
                                           const uint8_t *file_id,
                                           const uint8_t *record,
                                           uint32_t mode, uint32_t extra) {
    __asm__ volatile("mov x6, x30\n"
                     "b _ppkc_prefetch_cache_hook_impl\n");
}
#endif
#endif

static void ppkc_install_once(void) {
    uintptr_t base = ppkc_spotify_base();
    if (!base) return;

#ifdef PPKC_GUM
    if (!ppkc_graft_matches(base, 0)) return;
    gum_init_embedded();
    gum_process_set_code_signing_policy(GUM_CODE_SIGNING_REQUIRED);
    g_interceptor = gum_interceptor_obtain();
    g_callback_return = base + k_callback_return_offset;
    g_replay_return = base + k_replay_return_offset;
    g_key_listener = gum_make_probe_listener(ppkc_key_call_probe, NULL, NULL);
    if (gum_interceptor_attach(g_interceptor, (void *)(base + k_key_call_offset),
                               g_key_listener, NULL) == GUM_ATTACH_OK) {
        g_installed = 1;
        if (ppkc_graft_matches(base, 1)) {
            g_prefetch_listener = gum_make_probe_listener(
                ppkc_prefetch_cache_call_probe, NULL, NULL);
            if (gum_interceptor_attach(g_interceptor,
                                       (void *)(base + k_prefetch_cache_call_offset),
                                       g_prefetch_listener, NULL) != GUM_ATTACH_OK) {
                g_object_unref(g_prefetch_listener);
                g_prefetch_listener = NULL;
            }
        }
    } else {
        g_object_unref(g_key_listener);
        g_object_unref(g_interceptor);
        g_key_listener = NULL;
        g_interceptor = NULL;
        gum_deinit_embedded();
    }
#else
    // Resolve at runtime so the rootless package leaves playback untouched
    // if the function-hook backend is absent.
#ifdef PPKC_TESTING
    ppkc_hook_function_fn hook = ppkc_test_hook_function;
#else
    ppkc_hook_function_fn hook =
        (ppkc_hook_function_fn)dlsym(RTLD_DEFAULT, "MSHookFunction");
#endif
    if (!hook) return;

    g_playback_return = base + k_playback_return_offset;
    g_callback_return = base + k_callback_return_offset;
    g_replay_return = base + k_replay_return_offset;
    void *original = NULL;
    hook((void *)(base + k_set_key_offset), (void *)ppkc_set_key_hook, &original);
    if (!original) return;
    g_original_set_key = (ppkc_set_key_fn)original;
    original = NULL;
    hook((void *)(base + k_success_offset), (void *)ppkc_success_hook, &original);
    if (!original) return;
    g_original_success = (ppkc_success_fn)original;
    g_installed = 1;

    // This is optional: an absent or changed prefetch site must not disable
    // the already-installed playback capture path.
    if (ppkc_prefetch_fingerprint(base)) {
        g_prefetch_cache_return = base + k_prefetch_cache_return_offset;
#ifndef PPKC_TESTING
        __atomic_store_n(&g_prefetch_resume,
                         base + k_prefetch_cache_offset + 0x10,
                         __ATOMIC_RELEASE);
        // Publish the fallback target before ElleKit makes its entry patch
        // visible to another core, including its NULL-trampoline outcome.
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
#endif
        original = NULL;
        hook((void *)(base + k_prefetch_cache_offset),
             (void *)ppkc_prefetch_cache_hook, &original);
        if (original)
            __atomic_store_n(&g_original_prefetch_cache,
                             (ppkc_prefetch_cache_fn)original, __ATOMIC_RELEASE);
    }
#endif
}

int ppkc_install(void) {
    pthread_once(&g_install_once, ppkc_install_once);
    return g_installed;
}

uint64_t ppkc_generation(void) {
    pthread_mutex_lock(&g_record_mutex);
    uint64_t generation = g_generation;
    pthread_mutex_unlock(&g_record_mutex);
    return generation;
}

int ppkc_consume_after(uint64_t after_generation,
                       uint8_t out_record[PPKC_RECORD_BYTES],
                       uint64_t *out_generation) {
    if (!out_record) return 0;
    pthread_mutex_lock(&g_record_mutex);
    size_t slot = PPKC_SLOTS;
    for (size_t i = 0; i < PPKC_SLOTS; ++i)
        if (g_slots[i].occupied && g_slots[i].generation > after_generation &&
            (slot == PPKC_SLOTS || g_slots[i].generation > g_slots[slot].generation)) slot = i;
    int found = slot != PPKC_SLOTS;
    if (found) {
        memcpy(out_record, g_slots[slot].record, PPKC_RECORD_BYTES);
        if (out_generation) *out_generation = g_slots[slot].generation;
        ppkc_wipe(&g_slots[slot], sizeof(g_slots[slot]));
    }
    pthread_mutex_unlock(&g_record_mutex);
    return found;
}

int ppkc_consume_for_file_id(const uint8_t file_id[PPKC_FILE_ID_BYTES],
                             uint8_t out_record[PPKC_RECORD_BYTES],
                             uint64_t *out_generation) {
    if (!file_id || !out_record) return 0;
    pthread_mutex_lock(&g_record_mutex);
    size_t slot = PPKC_SLOTS;
    for (size_t i = 0; i < PPKC_SLOTS; ++i)
        if (g_slots[i].occupied && g_slots[i].attributed &&
            memcmp(g_slots[i].file_id, file_id, PPKC_FILE_ID_BYTES) == 0 &&
            (slot == PPKC_SLOTS || g_slots[i].generation > g_slots[slot].generation)) slot = i;
    int found = slot != PPKC_SLOTS;
    if (found) {
        memcpy(out_record, g_slots[slot].record, PPKC_RECORD_BYTES);
        if (out_generation) *out_generation = g_slots[slot].generation;
        ppkc_wipe(&g_slots[slot], sizeof(g_slots[slot]));
    }
    pthread_mutex_unlock(&g_record_mutex);
    return found;
}

int ppkc_has_for_file_id(const uint8_t file_id[PPKC_FILE_ID_BYTES]) {
    if (!file_id) return 0;
    pthread_mutex_lock(&g_record_mutex);
    int found = 0;
    for (size_t i = 0; i < PPKC_SLOTS; ++i) {
        if (g_slots[i].occupied && g_slots[i].attributed &&
            memcmp(g_slots[i].file_id, file_id, PPKC_FILE_ID_BYTES) == 0) {
            found = 1;
            break;
        }
    }
    pthread_mutex_unlock(&g_record_mutex);
    return found;
}

void ppkc_clear(void) {
    pthread_mutex_lock(&g_record_mutex);
    ppkc_wipe(g_slots, sizeof(g_slots));
    pthread_mutex_unlock(&g_record_mutex);
}
