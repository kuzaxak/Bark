#include "bark/browser/ui/bark_command_policy.h"

#include "bark/browser/ui/bark_browser_window.h"
#include "chrome/app/chrome_command_ids.h"
#include "ui/menus/simple_menu_model.h"

namespace bark {

bool HostWindowOffersCommand(int command_id) {
  switch (command_id) {
    case IDC_BOOKMARK_ALL_TABS:
    case IDC_BOOKMARK_THIS_TAB:
    case IDC_CLOSE_TAB:
    case IDC_CONTENT_CONTEXT_ADD_LINK_TO_READING_LIST:
    case IDC_CONTENT_CONTEXT_LENS_REGION_SEARCH:
    case IDC_CONTENT_CONTEXT_LISTEN_TO_THIS_PAGE:
    case IDC_CONTENT_CONTEXT_OPEN_IN_READING_MODE:
    case IDC_FOCUS_BOOKMARKS:
    case IDC_FOCUS_TOOLBAR:
    case IDC_READING_LIST_MENU_ADD_TAB:
    case IDC_ROUTE_MEDIA:
    case IDC_SEND_TAB_TO_SELF:
    case IDC_SHOW_APP_MENU:
    case IDC_SHOW_AVATAR_MENU:
    case IDC_SHOW_BOOKMARK_BAR:
    case IDC_SHOW_CHROME_LABS:
    case IDC_TAB_SEARCH:
      return false;
    default:
      return true;
  }
}

void RemoveUnofferedItems(const BrowserWindowInterface* browser,
                          ui::SimpleMenuModel* menu) {
  if (!BarkBrowserWindow::FromBrowser(browser)) {
    return;
  }
  auto separator = [menu](size_t index) {
    return menu->GetTypeAt(index) == ui::MenuModel::TYPE_SEPARATOR;
  };
  for (size_t i = menu->GetItemCount(); i-- > 0;) {
    if (!separator(i) && !HostWindowOffersCommand(menu->GetCommandIdAt(i))) {
      menu->RemoveItemAt(i);
    }
  }
  for (size_t i = menu->GetItemCount(); i-- > 0;) {
    if (separator(i) &&
        (i == 0 || i + 1 == menu->GetItemCount() || separator(i - 1))) {
      menu->RemoveItemAt(i);
    }
  }
}

}  // namespace bark
