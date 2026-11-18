#ifndef BARK_BROWSER_UI_NATIVE_SPACE_PAGE_H_
#define BARK_BROWSER_UI_NATIVE_SPACE_PAGE_H_

#include "build/build_config.h"

class BrowserWindowInterface;

namespace bark {

// The owner may keep an active native tab while the app presents an empty
// space. Suppression follows the client across page and strip changes.
#if BUILDFLAG(IS_MAC)
bool IsNativeSpacePageSuppressed(const BrowserWindowInterface* owner);
bool SetNativeSpacePageSuppressed(BrowserWindowInterface* owner,
                                  bool suppressed);
#else
inline bool IsNativeSpacePageSuppressed(const BrowserWindowInterface*) {
  return false;
}
#endif

}  // namespace bark

#endif  // BARK_BROWSER_UI_NATIVE_SPACE_PAGE_H_
