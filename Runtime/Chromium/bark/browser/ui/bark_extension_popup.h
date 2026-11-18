#ifndef BARK_BROWSER_UI_BARK_EXTENSION_POPUP_H_
#define BARK_BROWSER_UI_BARK_EXTENSION_POPUP_H_

#include "chrome/browser/ui/extensions/extension_popup_types.h"

class BrowserWindowInterface;
namespace extensions {
class Extension;
}

namespace bark {

// Opens the extension's tab-specific popup on a visible, selected Bark client.
bool OpenExtensionActionPopup(BrowserWindowInterface& browser,
                              const extensions::Extension& extension,
                              ShowPopupCallback callback);

}  // namespace bark

#endif  // BARK_BROWSER_UI_BARK_EXTENSION_POPUP_H_
