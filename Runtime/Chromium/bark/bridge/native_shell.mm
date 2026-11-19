#import <AppKit/AppKit.h>

#include <algorithm>
#include <cmath>
#include <map>
#include <limits>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <objc/runtime.h>

#include "bark/browser/webauthn/barc_vault_authenticator.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "net/base/url_util.h"
#include "components/search_engines/template_url_service.h"
#include "components/search_engines/template_url.h"
#include "services/network/public/cpp/resource_request_body.h"

#include "base/files/file_util.h"
#include "base/files/scoped_file.h"
#include "base/uuid.h"
#include "net/base/file_stream.h"
#include "net/base/io_buffer.h"
#include "services/network/public/cpp/simple_url_loader_stream_consumer.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "chrome/browser/profiles/nuke_profile_directory_utils.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/common/referrer.h"
#include "net/base/isolation_info.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/cookies/site_for_cookies.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"

#include "base/containers/linked_list.h"
#include "base/memory/ref_counted_memory.h"
#include "bark/browser/content_blocking/native_content_blocker.h"
#include "base/supports_user_data.h"
#include "base/auto_reset.h"
#include "base/synchronization/atomic_flag.h"
#include "base/task/bind_post_task.h"
#include "base/task/thread_pool.h"
#include "base/barrier_callback.h"
#include "base/no_destructor.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/scoped_multi_source_observation.h"
#include "components/download/public/common/download_item.h"
#include "content/public/browser/back_forward_cache.h"
#include "content/public/browser/download_manager.h"
#include "base/task/single_thread_task_runner.h"
#include "content/public/browser/media_session.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "mojo/public/cpp/bindings/associated_receiver.h"
#include "chrome/common/chrome_render_frame.mojom.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/navigation_discard_reason.h"
#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "components/autofill/content/browser/content_autofill_client.h"
#include "components/autofill/content/browser/content_autofill_driver.h"
#include "components/autofill/core/browser/autofill_field.h"
#include "components/autofill/core/browser/form_structure.h"
#include "components/autofill/core/browser/foundations/scoped_autofill_managers_observation.h"
#include "components/password_manager/content/browser/content_password_manager_driver.h"
#include "components/password_manager/core/browser/password_form.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/strings/string_util.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/version_info/version_info.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "third_party/blink/public/common/web_preferences/web_preferences.h"
#include "services/network/public/mojom/web_sandbox_flags.mojom.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "bark/bridge/barc_profiles.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_muted_utils.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "bark/bridge/barc_runtime_startup.h"
#include "bark/browser/ui/bark_browser_window.h"
#include "chrome/browser/ui/views/infobars/confirm_infobar.h"
#include "components/infobars/content/content_infobar_manager.h"
#include "components/infobars/core/confirm_infobar_delegate.h"
#include "ui/views/view_tracker.h"
#include "chrome/browser/ui/views/frame/browser_widget.h"
#include "components/sessions/core/session_id.h"
#include "components/tabs/public/split_tab_data.h"
#include "components/tabs/public/tab_interface.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/weak_document_ptr.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_partition_key_collection.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "third_party/blink/public/common/storage_key/storage_key.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/base_window.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/codec/jpeg_codec.h"
#include "extensions/browser/extensions_browser_client.h"
#include "chrome/browser/ui/views/toolbar/toolbar_view.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/controls/native/native_view_host.h"
#include "url/gurl.h"

#include "bark/bridge/barc_bridge_functions.h"
#include "bark/bridge/bridge_internal.h"

using namespace barc::internal;

namespace barc {
int NativeShellWidth(const BrowserView* browser_view) {
  auto* shell = browser_view->barc_native_shell();
  return shell && shell->GetVisible() && !browser_view->barc_compact_shell()
      ? kNativeShellWidth : 0;
}
int NativeShellHeight(const BrowserView* browser_view) {
  auto* shell = browser_view->barc_native_shell();
  if (!shell || !shell->GetVisible()) return 0;
  if (browser_view->barc_compact_shell()) return 44;
  auto* header = browser_view->barc_page_header();
  BarcPageHeader* paired = PageHeader(shell->native_view().GetNativeNSView());
  return header && header->GetVisible() && paired &&
      header->native_view().GetNativeNSView() == paired.view ? paired.height : 0;
}
bool ConfigureNativeMini(BrowserWindowInterface* browser) {
  if (auto* client = bark::BarkBrowserWindow::FromBrowser(browser))
    return client->MarkApplicationMini();
  auto* view = browser && !browser->IsDeleteScheduled()
      ? BrowserView::GetBrowserViewForBrowser(browser) : nullptr;
  return view && view->InitializeBarcCompactShell();
}
namespace {
class PeekUnloadHandler final : public UnloadController::TabUnloadHandler {
 public:
  explicit PeekUnloadHandler(BrowserWindowInterface* browser)
      : browser_(browser->GetWeakPtr()) {}
  bool ShouldSkipBeforeUnload(content::WebContents* contents) override {
    return IsPeekCloseCommitted(tabs::TabInterface::GetFromContents(contents));
  }
  bool ShouldShowCustomConfirmation(content::WebContents* contents) override {
    auto* tab = tabs::TabInterface::GetFromContents(contents);
    if (!browser_ || browser_->IsDeleteScheduled() || !tab ||
        tab->GetBrowserWindowInterface() != browser_.get() ||
        UnloadController::From(browser_.get())->owner_close_admitted() ||
        IsPeekCloseCommitted(tab)) return false;
    auto* view = BrowserView::GetBrowserViewForBrowser(browser_.get());
    return view && view->browser_widget() && (PeekForSource(tab) ||
        view->browser_widget()->HasPhysicalClosePending() || browser_shutdown::IsTryingToQuit());
  }
  bool ShowCustomConfirmation(content::WebContents* contents,
      base::OnceCallback<void(bool)> on_closed) override {
    if (!ShouldShowCustomConfirmation(contents)) return false;
    auto* source = tabs::TabInterface::GetFromContents(contents);
    auto* view = BrowserView::GetBrowserViewForBrowser(browser_.get());
    auto* widget = view->browser_widget();
    if (widget->HasPhysicalClosePending() || browser_shutdown::IsTryingToQuit()) {
      if (!browser_shutdown::IsTryingToQuit() && !widget->IsPhysicalCloseTarget(source)) {
        // This controller already belongs to another exact subset. Do not run
        // its old continuation/reset over that cohort or start a second prompt.
        contents->SetClosedByUserGesture(false);
        NotifyPeekCloseCancelled(source);
      }
      return true;
    }
    auto* peek = PeekForSource(source);
    return widget->RequestPeekPairClose(source, peek, std::move(on_closed));
  }
 private:
  base::WeakPtr<BrowserWindowInterface> browser_;
};
}  // namespace
views::NativeViewHost* CreateNativeShell(BrowserView* browser_view) {
  if (!IsNativeApplicationRegistered() ||
      (browser_view->browser()->GetType() != BrowserWindowInterface::TYPE_NORMAL &&
       !browser_view->barc_compact_shell()))
    return nullptr;
  UnloadController::From(browser_view->browser())->AddTabUnloadHandler(
      std::make_unique<PeekUnloadHandler>(browser_view->browser()));
  // A WebUI toolbar page stays in the accessibility tree while its view is
  // hidden, so the hidden toolbar's subtree is cut off explicitly.
  browser_view->toolbar()->GetViewAccessibility().SetIsLeaf(true);
  auto* host =
      browser_view->AddChildView(std::make_unique<views::NativeViewHost>());
  host->SetVisible(false);
  return host;
}
void LayoutNativeShell(views::NativeViewHost* shell,
                       BrowserView* browser_view) {
  if (!shell || !shell->GetVisible())
    return;
  const gfx::Rect bounds = browser_view->GetLocalBounds();
  if (browser_view->barc_compact_shell()) {
    shell->SetBounds(bounds.x(), bounds.y(), bounds.width(), 44);
  } else {
    auto alive = browser_view->GetAsWeakPtr();
    views::ViewTracker header(browser_view->barc_page_header());
    shell->SetBounds(bounds.x(), bounds.y(), kNativeShellWidth, bounds.height());
    if (!alive || !header.view() || alive->barc_page_header() != header.view()) return;
    const int height = NativeShellHeight(alive.get());
    if (header.view()->GetVisible()) {
      header.view()->SetBounds(bounds.x() + kNativeShellWidth, bounds.y(),
          std::max(0, bounds.width() - kNativeShellWidth), height);
    }
  }
}
}  // namespace barc
