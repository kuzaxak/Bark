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

int barc_window_get_split(int32_t id, int32_t member, BarcSplitLayout* layout) {
  auto* window = Window(id);
  auto* strip = window ? window->GetTabStripModel() : nullptr;
  auto* active = strip ? strip->GetActiveTab() : nullptr;
  auto* target = member ? tabs::TabHandle(member).Get() : active;
  if (!window || !IsSized(layout) || !target)
    return 0;
  auto* view = BrowserView::GetBrowserViewForBrowser(window);
  auto* widget = view ? view->browser_widget() : nullptr;
  std::vector<tabs::TabInterface*> presented;
  split_tabs::SplitTabVisualData visual;
  tabs::TabInterface* presented_active = nullptr;
  uint64_t generation = 0;
  const bool mounted = widget && widget->GetBarcPresentedTabs(
      &presented, &visual, &presented_active, &generation);
  if (!mounted || !std::ranges::contains(presented, target))
    return 0;
  BarcSplitLayout result{};
  result.count = presented.size();
  result.orientation = visual.split_layout() == split_tabs::SplitTabLayout::kSideBySide
      ? BARC_SPLIT_SIDE_BY_SIDE : BARC_SPLIT_STACKED;
  result.active_tab = presented_active->GetHandle().raw_value();
  result.kind = BARC_SPLIT_PHYSICAL;
  result.generation = generation;
  for (size_t i = 0; i < presented.size(); ++i)
    base::span(result.tabs)[i] = presented[i]->GetHandle().raw_value();
  base::span(result.dividers).first(presented.size() - 1).copy_from(visual.split_dividers());
  WriteKnownFields(layout, result);
  return 1;
}
int barc_window_set_split(int32_t id, const BarcSplitLayout* layout) {
  if (!IsSized(layout) || navigation_callback_depth)
    return 0;
  const BarcSplitLayout request = *layout;
  if (request.count < 2 || request.count > 4 || request.orientation > BARC_SPLIT_STACKED)
    return 0;
  const auto handles = base::span(request.tabs).first(request.count);
  const auto dividers = base::span(request.dividers).first(request.count - 1);
  if (!split_tabs::SplitTabVisualData::AreValidDividers(dividers) ||
      dividers.front() <= 0 || dividers.back() >= 1 ||
      !std::ranges::contains(handles, request.active_tab))
    return 0;
  auto* window = Window(id);
  auto* view = window ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
  if (!view || !view->GetIsNormalType() || !window->IsSelectedForNativeWindow())
    return 0;
  std::vector<tabs::TabInterface*> tabs;
  for (int32_t handle : handles) {
    auto* tab = handle ? tabs::TabHandle(handle).Get() : nullptr;
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* owner_view = owner ? BrowserView::GetBrowserViewForBrowser(owner) : nullptr;
    if (!owner || Window(owner->GetSessionID().id()) != owner ||
        !owner_view || !owner_view->GetIsNormalType() ||
        owner_view->browser_widget() != view->browser_widget() ||
        tab->GetContents()->GetBrowserContext() != owner->GetProfile() ||
        std::ranges::contains(tabs, tab))
      return 0;
    tabs.push_back(tab);
  }
  const bool any_private = window->GetProfile()->IsOffTheRecord() ||
      std::ranges::any_of(tabs, [](auto* tab) {
        return tab->GetBrowserWindowInterface()->GetProfile()->IsOffTheRecord();
      });
  if ((any_private && !std::ranges::all_of(tabs, [window](auto* tab) {
        return tab->GetBrowserWindowInterface()->GetProfile() == window->GetProfile();
      })) || !LookupTab(window, request.active_tab))
    return 0;
  base::AutoReset callback_depth(&navigation_callback_depth, navigation_callback_depth + 1);
  return view->browser_widget()->SetBarcPresentedTabs(
      tabs, split_tabs::SplitTabVisualData(request.orientation == BARC_SPLIT_SIDE_BY_SIDE
          ? split_tabs::SplitTabLayout::kSideBySide : split_tabs::SplitTabLayout::kStacked, dividers),
      LookupTab(window, request.active_tab));
}
int barc_window_clear_split(int32_t id, int32_t member,
                            const BarcSplitLayout* expected) {
  if (!IsSized(expected) || navigation_callback_depth)
    return 0;
  const BarcSplitLayout request = *expected;
  BarcSplitLayout actual{.size = sizeof(BarcSplitLayout)};
  if (!barc_window_get_split(id, member, &actual) ||
      actual.kind != request.kind || request.generation == 0 ||
      actual.generation != request.generation ||
      actual.count != request.count || actual.orientation != request.orientation ||
      actual.active_tab != request.active_tab ||
      !std::ranges::equal(base::span(actual.tabs).first(actual.count),
                         base::span(request.tabs).first(request.count)) ||
      !std::ranges::equal(base::span(actual.dividers).first(actual.count - 1),
                         base::span(request.dividers).first(request.count - 1))) {
    return 0;
  }
  auto* window = Window(id);
  auto* view = window ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
  if (!view || !view->GetIsNormalType())
    return 0;
  auto* widget = view->browser_widget();
  auto alive = widget->GetWeakPtr();
  auto* selected = tabs::TabHandle(actual.active_tab).Get();
  auto* selected_owner = selected ? selected->GetBrowserWindowInterface() : nullptr;
  if (!selected_owner || Window(selected_owner->GetSessionID().id()) != selected_owner ||
      !selected_owner->IsSelectedForNativeWindow() ||
      UnloadController::From(selected_owner)->owner_close_admitted())
    return 0;
  auto selected_tab = selected->GetWeakPtr();
  auto owner_alive = selected_owner->GetWeakPtr();
  const uint64_t epoch = widget->barc_selection_epoch();
  base::AutoReset callback_depth(&navigation_callback_depth, navigation_callback_depth + 1);
  widget->ClearBarcPresentedTabs();
  return alive && owner_alive && selected_tab &&
      Window(owner_alive->GetSessionID().id()) == owner_alive.get() &&
      owner_alive->IsSelectedForNativeWindow() &&
      !UnloadController::From(owner_alive.get())->owner_close_admitted() &&
      widget->barc_selection_epoch() == epoch && !widget->HasBarcPresentedTabs() &&
      selected_tab->GetBrowserWindowInterface() == owner_alive.get() &&
      owner_alive->GetTabStripModel()->GetActiveTab() == selected_tab.get();
}
