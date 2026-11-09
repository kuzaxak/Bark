#ifndef BARC_PAGE_TWEAKS_H_
#define BARC_PAGE_TWEAKS_H_
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// UI thread after Barc registration. Fixed version1 preference JSON, <=16MiB,
// copied synchronously, 200 opt-in scripts maximum, <=64KiB each. Null/zero
// revokes all configuration. Invalid input also revokes before returning0,
// so failed removal cannot retain stale script permission. No executable callbacks
// or per-document IDs.
// Material changes take effect on the next load and retire only affected cached
// documents/pending script continuations. Unchanged publications are no-ops.
__attribute__((visibility("default"))) int barc_page_tweaks_publish(
    const uint8_t* json, size_t length);
#ifdef __cplusplus
}
#endif
#endif
