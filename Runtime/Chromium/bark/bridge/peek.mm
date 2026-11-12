#import <AppKit/AppKit.h>

#include <algorithm>
#include <array>
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

#include "base/command_line.h"
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
#include "base/strings/utf_string_conversions.h"
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
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "bark/bridge/barc_runtime_startup.h"
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

uint64_t barc_tab_present_peek(int32_t source_window, int32_t source_tab,
    int32_t peek_window, int32_t peek_tab, void* expected_sidebar,
    void* header, void* actions) {
  auto* source = LookupTab(Window(source_window), source_tab);
  auto* peek = LookupTab(Window(peek_window), peek_tab);
  auto* owner = source ? BrowserView::GetBrowserViewForBrowser(source->GetBrowserWindowInterface()) : nullptr;
  if (!owner || !expected_sidebar || !header || !actions || navigation_callback_depth) return 0;
  return owner->browser_widget()->PresentBarcPeek(source, peek,
      gfx::NativeView((__bridge NSView*)expected_sidebar),
      gfx::NativeView((__bridge NSView*)header), gfx::NativeView((__bridge NSView*)actions));
}
int barc_tab_hide_peek(int32_t source_window, int32_t source_tab,
    int32_t peek_window, int32_t peek_tab, uint64_t generation,
    void* header, void* actions) {
  auto* source = LookupTab(Window(source_window), source_tab);
  auto* peek = LookupTab(Window(peek_window), peek_tab);
  auto* owner = source ? BrowserView::GetBrowserViewForBrowser(source->GetBrowserWindowInterface()) : nullptr;
  return owner && header && actions && !navigation_callback_depth &&
      owner->browser_widget()->HideBarcPeek(source, peek, generation,
          gfx::NativeView((__bridge NSView*)header), gfx::NativeView((__bridge NSView*)actions));
}
int barc_tab_is_peek_presented(int32_t source_window, int32_t source_tab,
    int32_t peek_window, int32_t peek_tab, uint64_t generation,
    void* header, void* actions) {
  auto* source = LookupTab(Window(source_window), source_tab);
  auto* peek = LookupTab(Window(peek_window), peek_tab);
  auto* owner = source ? BrowserView::GetBrowserViewForBrowser(source->GetBrowserWindowInterface()) : nullptr;
  return owner && header && actions && owner->browser_widget()->IsBarcPeekPresented(
      source, peek, generation, gfx::NativeView((__bridge NSView*)header),
      gfx::NativeView((__bridge NSView*)actions));
}

@interface BarcPeekBackdrop : NSView {
 @private
  base::WeakPtr<tabs::TabInterface> source_;
  base::WeakPtr<tabs::TabInterface> peek_;
}
- (instancetype)initWithSource:(tabs::TabInterface*)source peek:(tabs::TabInterface*)peek;
@end
@implementation BarcPeekBackdrop
- (instancetype)initWithSource:(tabs::TabInterface*)source peek:(tabs::TabInterface*)peek {
  if ((self = [super initWithFrame:NSZeroRect])) {
    source_ = source->GetWeakPtr();
    peek_ = peek->GetWeakPtr();
  }
  return self;
}
- (void)mouseDown:(NSEvent*)event {
  if (!source_ || !peek_ || !barc::IsPeekPair(source_.get(), peek_.get())) return;
  auto* owner = peek_->GetBrowserWindowInterface();
  if (owner) barc_tab_close(owner->GetSessionID().id(), peek_->GetHandle().raw_value());
}
@end

namespace barc {
bool IsPeekCloseCommitted(tabs::TabInterface* source) {
  auto* link = source ? static_cast<PeekSource*>(source->GetContents()->GetUserData(&kPeekSourceKey)) : nullptr;
  auto* role = PeekRoleFor(source);
  return (link && link->close_committed) || (role && role->close_committed);
}
void ResetPeekCloseCommitted(tabs::TabInterface* tab, content::WebContents* expected) {
  // New role objects begin uncommitted; replacement contents have their own
  // lifetime. Undo only the surviving old contents skipped by this commit.
  if (!tab || tab->GetContents() != expected) return;
  if (auto* role = PeekRoleFor(tab)) role->close_committed = false;
  if (auto* link = static_cast<PeekSource*>(expected->GetUserData(&kPeekSourceKey)))
    link->close_committed = false;
}
bool CommitPeekPairClose(tabs::TabInterface* source, tabs::TabInterface* peek) {
  if (!IsPeekPair(source, peek)) return false;
  static_cast<PeekSource*>(source->GetContents()->GetUserData(&kPeekSourceKey))->close_committed = true;
  PeekRoleFor(peek)->close_committed = true;
  return true;
}
tabs::TabInterface* PeekForSource(tabs::TabInterface* source) {
  auto* link = source ? static_cast<PeekSource*>(source->GetContents()->GetUserData(&kPeekSourceKey)) : nullptr;
  auto* peek = link ? link->peek.get() : nullptr;
  auto* role = PeekRoleFor(peek);
  return role && role->source.get() == source ? peek : nullptr;
}
bool IsPeekPair(tabs::TabInterface* source, tabs::TabInterface* peek) {
  auto* role = PeekRoleFor(peek);
  auto* link = source ? static_cast<PeekSource*>(source->GetContents()->GetUserData(&kPeekSourceKey)) : nullptr;
  auto* owner = source ? source->GetBrowserWindowInterface() : nullptr;
  auto* peer = peek ? peek->GetBrowserWindowInterface() : nullptr;
  return role && role->source.get() == source && link && link->peek.get() == peek &&
      owner && peer && !owner->IsDeleteScheduled() && !peer->IsDeleteScheduled() &&
      owner->GetProfile() == peer->GetProfile() && owner->GetWindow() && peer->GetWindow() &&
      owner->GetWindow()->GetNativeWindow() == peer->GetWindow()->GetNativeWindow();
}
void AttachPeekBackdrop(views::NativeViewHost* host, tabs::TabInterface* source,
                        tabs::TabInterface* peek) {
  if (!host || !IsPeekPair(source, peek)) return;
  BarcPeekBackdrop* backdrop = [[BarcPeekBackdrop alloc] initWithSource:source peek:peek];
  host->Attach(gfx::NativeView(backdrop));
}
bool MovePeekNativeShell(BrowserWindowInterface* from, BrowserWindowInterface* to) {
  if (!from || !to || from == to || from->GetProfile() != to->GetProfile()) return false;
  auto source = from->GetWeakPtr();
  auto destination = to->GetWeakPtr();
  auto* old_view = BrowserView::GetBrowserViewForBrowser(from);
  auto* new_view = BrowserView::GetBrowserViewForBrowser(to);
  if (!old_view || !new_view || old_view->browser_widget() != new_view->browser_widget() ||
      !old_view->barc_native_shell() || !new_view->barc_native_shell() ||
      new_view->barc_native_shell()->native_view()) return false;
  NSView* expected = old_view->barc_native_shell()->native_view().GetNativeNSView();
  if (!expected) return false;
  const int32_t old_id = from->GetSessionID().id(), new_id = to->GetSessionID().id();
  auto selected = old_view->browser_widget()->selected_browser_view()->GetAsWeakPtr();
  auto current = [&] {
    return source && destination && selected && Window(old_id) == source.get() &&
        Window(new_id) == destination.get() &&
        BrowserView::GetBrowserViewForBrowser(source.get()) &&
        BrowserView::GetBrowserViewForBrowser(destination.get()) &&
        BrowserView::GetBrowserViewForBrowser(destination.get())->browser_widget()->selected_browser_view() == selected.get();
  };
  if (!barc_window_detach_native_shell_if_owned(old_id, (__bridge void*)expected) || !current()) return false;
  if (!barc_window_native_shell_is_owned(new_id, nullptr)) return false;
  return barc_window_attach_native_shell(new_id, (__bridge void*)expected) && current();
}
}  // namespace barc
