#ifndef BARK_BROWSER_UI_BARK_COMMAND_POLICY_H_
#define BARK_BROWSER_UI_BARK_COMMAND_POLICY_H_

class BrowserWindowInterface;

namespace ui {
class SimpleMenuModel;
}

namespace bark {

// False for a command whose UI a host window does not have. The menu bar
// hides such a command and the context menu leaves it out.
bool HostWindowOffersCommand(int command_id);

// Takes the commands a host window does not offer out of `browser`'s context
// menu, with the separators they leave doubled or at either end. Leaves the
// menu of any other window as it is.
void RemoveUnofferedItems(const BrowserWindowInterface* browser,
                          ui::SimpleMenuModel* menu);

}  // namespace bark

#endif  // BARK_BROWSER_UI_BARK_COMMAND_POLICY_H_
