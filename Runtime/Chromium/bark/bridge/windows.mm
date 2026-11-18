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
#include "bark/browser/ui/native_space_page.h"
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
#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_window_factory.h"
#include "bark/browser/ui/bark_window_host.h"

using namespace barc::internal;

int32_t barc_window_new_peer(int32_t source) {
  auto* window = Window(source);
  if (!window)
    return 0;
  BrowserWindowInterface* peer = nullptr;
  {
    bark::ScopedAppWindowCreation app_window;
    peer = CreateBrowserWindow(
        BrowserWindowCreateParams(*window->GetProfile(), true));
  }
  if (auto* view = peer ? BrowserView::GetBrowserViewForBrowser(peer) : nullptr)
    view->MarkBarcAppFactoryOrigin();
  return peer ? peer->GetSessionID().id() : 0;
}
int32_t barc_window_new_peer_in_native_window(int32_t source_id,
                                                int32_t owner_id) {
  auto* source = Window(source_id);
  auto* owner = Window(owner_id);
  if (!source || !owner || !barc::CanResolveApplicationBrowser() ||
      navigation_callback_depth || !owner->GetWindow() ||
      UnloadController::From(source)->owner_close_admitted() ||
      UnloadController::From(owner)->owner_close_admitted() ||
      !BrowserWindow::CanCreateInNativeWindow(owner->GetSessionID()))
    return 0;
  std::array<char, 37> source_uuid{}, owner_uuid{};
  const bool private_source = barc_window_private_session_uuid(
      source_id, source_uuid.data(), source_uuid.size()) == 37;
  if (private_source) {
    if (barc_window_private_session_uuid(owner_id, owner_uuid.data(),
                                         owner_uuid.size()) != 37 ||
        source_uuid != owner_uuid)
      return 0;
  } else if (barc_window_profile_uuid(source_id, source_uuid.data(),
                                       source_uuid.size()) != 37 ||
             barc_window_profile_uuid(owner_id, owner_uuid.data(),
                                       owner_uuid.size()) != 37) {
    return 0;
  }
  auto source_alive = source->GetWeakPtr();
  auto owner_alive = owner->GetWeakPtr();
  auto profile_alive = source->GetProfile()->GetWeakPtr();
  auto keep_alive = ScopedProfileKeepAlive::TryAcquire(
      source->GetProfile()->GetOriginalProfile(),
      ProfileKeepAliveOrigin::kProfileCreationFlow);
  auto* collection = GlobalBrowserCollection::GetInstance();
  auto* selected = collection->FindBrowserWithWindow(
      owner->GetWindow()->GetNativeWindow());
  auto selected_alive = selected ? selected->GetWeakPtr()
                                : base::WeakPtr<BrowserWindowInterface>();
  if (!keep_alive || !selected_alive)
    return 0;
  BrowserWindowCreateParams params(*source->GetProfile(), true);
  params.native_window_owner = owner->GetSessionID();
  auto* created = CreateBrowserWindow(std::move(params));
  if (!created)
    return 0;
  auto created_alive = created->GetWeakPtr();
  if (auto* view = BrowserView::GetBrowserViewForBrowser(created))
    view->MarkBarcAppFactoryOrigin();
  const auto valid = [&] {
    if (!barc::CanResolveApplicationBrowser() || !source_alive || !owner_alive ||
        !profile_alive || !created_alive || source_alive->IsDeleteScheduled() ||
        owner_alive->IsDeleteScheduled() || created_alive->IsDeleteScheduled() ||
        !owner_alive->GetWindow() || !created_alive->GetWindow() ||
        source_alive->GetProfile() != profile_alive.get() ||
        created_alive->GetProfile() != profile_alive.get() ||
        UnloadController::From(source_alive.get())->owner_close_admitted() ||
        UnloadController::From(owner_alive.get())->owner_close_admitted())
      return false;
    return owner_alive->GetWindow()->GetNativeWindow() ==
               created_alive->GetWindow()->GetNativeWindow() &&
        GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
            owner_alive->GetWindow()->GetNativeWindow()) == selected_alive.get();
  };
  if (!valid()) {
    if (created_alive && !created_alive->IsDeleteScheduled() &&
        created_alive->GetWindow() && created_alive->GetTabStripModel()->empty())
      created_alive->GetWindow()->Close();
    return 0;
  }
  return created_alive->GetSessionID().id();
}
int barc_window_close(int32_t id) {
  auto* window = Window(id);
  if (!window)
    return 0;
  if (navigation_callback_depth) {
    return content::GetUIThreadTaskRunner({})->PostNonNestableTask(
        FROM_HERE, base::BindOnce([](int32_t window) { barc_window_close(window); },
                                 id));
  }
  window->GetWindow()->Close();
  return 1;
}
int barc_window_set_page_hidden(int32_t id, int hidden) {
  auto* window = Window(id);
  auto* view = window && !window->IsDeleteScheduled()
                   ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
  auto* widget = view ? view->browser_widget() : nullptr;
  if (!widget || widget->IsClosed() || widget->IsPhysicalCloseCommitted())
    return 0;
  widget->set_barc_page_hidden(hidden != 0);
  return 1;
}
int barc_window_set_app_lifetime(int32_t id) {
  auto* window = Window(id);
  if (auto* host = bark::BarkWindowHost::ForBrowser(window)) {
    if (window->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
        host->closing() ||
        UnloadController::From(window)->is_attempting_to_close_browser())
      return 0;
    UnloadController::SetEmptyTabStripRetention(&RetainsEmptyTabStrip);
    if (AppLifetimeGroups().insert(host->physical_group()).second)
      barc::BrowserDiscoveryChanged();
    return 1;
  }
  auto* view = window && !window->IsDeleteScheduled() &&
                       window->GetType() == BrowserWindowInterface::TYPE_NORMAL
                   ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
  auto* widget = view ? view->browser_widget() : nullptr;
  if (!widget || widget->IsClosed() || widget->HasPhysicalClosePending() ||
      UnloadController::From(window)->is_attempting_to_close_browser())
    return 0;
  UnloadController::SetEmptyTabStripRetention(&RetainsEmptyTabStrip);
  if (AppLifetimeGroups().insert(widget->barc_physical_group()).second)
    barc::BrowserDiscoveryChanged();
  return 1;
}
size_t barc_window_tab_count(int32_t id) {
  auto* window = Window(id);
  return window ? window->GetTabStripModel()->count() : 0;
}
int32_t barc_window_tab_at(int32_t id, size_t index) {
  auto* window = Window(id);
  if (!window ||
      index >= static_cast<size_t>(window->GetTabStripModel()->count()))
    return 0;
  return window->GetTabStripModel()
      ->GetTabAtIndex(static_cast<int>(index))
      ->GetHandle()
      .raw_value();
}
int32_t barc_tab_create(int32_t id, const char* value, int foreground) {
  auto* window = Window(id);
  GURL url = URL(value);
  if (!window || !url.is_valid())
    return 0;
  const bool present = foreground || (window->GetTabStripModel()->empty() &&
                                      !HasAppLifetime(window));
  if (present && !barc_window_select(id))
    return 0;
  window = Window(id);
  if (!window)
    return 0;
  auto* contents = chrome::AddAndReturnTabAt(window, url, -1, foreground != 0);
  // Insertion observers can close or move the new tab. Compare the returned
  // address against the surviving strip before dereferencing its contents.
  window = Window(id);
  if (!window || !contents)
    return 0;
  auto* strip = window->GetTabStripModel();
  const int index = strip->GetIndexOfWebContents(contents);
  if (index == TabStripModel::kNoTab)
    return 0;
  static_cast<tabs::TabModel*>(strip->GetTabAtIndex(index))->set_barc_app_factory_origin();
  barc::BrowserDiscoveryChanged();
  const int32_t tab_id = strip->GetTabAtIndex(index)->GetHandle().raw_value();
  // A nested profile selection wins over this request's original foreground
  // intent. Show itself can also invoke callbacks, so resolve once more after it.
  if (present && window->IsSelectedForNativeWindow())
    window->GetWindow()->Show();
  return LookupTab(Window(id), tab_id) ? tab_id : 0;
}
int barc_tab_select(int32_t id, int32_t tab_id) {
  if (navigation_callback_depth)
    return 0;
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab || !barc_window_select(id))
    return 0;
  // Admission can invoke native/profile callbacks; resolve the existing handles
  // again before mutating selection or focusing the requested document.
  window = Window(id);
  tab = LookupTab(window, tab_id);
  if (!tab)
    return 0;
  auto contents = tab->GetContents()->GetWeakPtr();
  auto* strip = window->GetTabStripModel();
  strip->ActivateTabAt(strip->GetIndexOfWebContents(tab->GetContents()));
  if (!contents)
    return 0;
  window = Window(id);
  tab = LookupTab(window, tab_id);
  if (!tab || tab->GetContents() != contents.get() ||
      !window->IsSelectedForNativeWindow())
    return 0;
  contents->Focus();
  return 1;
}
int barc_tab_search(int32_t id, int32_t tab_id, const char* query,
                    const char* kagi_session_token) {
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab || !query || strlen(query) > 16384 ||
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return 0;
  char identity[37] = {};
  if (barc_window_profile_uuid(id, identity, sizeof(identity)) != sizeof(identity) &&
      barc_window_private_session_uuid(id, identity, sizeof(identity)) != sizeof(identity)) return 0;
  auto* service = TemplateURLServiceFactory::GetForProfile(window->GetProfile());
  if (!service || !service->loaded()) return 0;
  const auto* provider = service->GetDefaultSearchProvider();
  if (!provider || !provider->SupportsReplacement(service->search_terms_data())) return 0;
  TemplateURLRef::PostContent post;
  GURL url(provider->url_ref().ReplaceSearchTerms(
      TemplateURLRef::SearchTermsArgs(base::UTF8ToUTF16(query)),
      service->search_terms_data(), &post));
  if (!url.SchemeIsHTTPOrHTTPS()) return 0;
  // The Session Link remains in the app Keychain. Borrow it only for an
  // explicitly selected, uncontrolled token-free Kagi template; never store it
  // in TemplateURLData, nor send it to a custom/managed/extension provider.
  if (kagi_session_token && *kagi_session_token && strlen(kagi_session_token) <= 8192 &&
      provider->url() == "https://kagi.com/search?q={searchTerms}" &&
      provider->url_ref().GetPostParamsString().empty() &&
      !service->is_default_search_managed() && !service->IsExtensionControlledDefaultSearch()) {
    url = net::AppendQueryParameter(url, "token", kagi_session_token);
  }
  content::NavigationController::LoadURLParams params(url);
  params.transition_type = ui::PAGE_TRANSITION_GENERATED;
  if (!post.first.empty()) {
    params.load_type = content::NavigationController::LOAD_TYPE_HTTP_POST;
    params.post_data = network::ResourceRequestBody::CreateFromCopyOfBytes(base::as_byte_span(post.second));
    params.extra_headers = "Content-Type: " + post.first;
  }
  tab->GetContents()->GetController().LoadURLWithParams(params);
  return 1;
}
int barc_tab_navigate(int32_t id, int32_t tab_id, const char* value) {
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  GURL url = URL(value);
  // Captured application/private intents own the first navigation until exact
  // context policy and model admission consume their intrinsic blank role.
  if (tab && NativeContentBlocker::IsRegistered() &&
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return 0;
  if (!tab || !url.is_valid())
    return 0;
  tab->GetContents()->GetController().LoadURL(
      url, content::Referrer(), ui::PAGE_TRANSITION_TYPED, std::string());
  return 1;
}
int barc_tab_close(int32_t id, int32_t tab_id) {
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab)
    return 0;
  if (navigation_callback_depth) {
    return content::GetUIThreadTaskRunner({})->PostNonNestableTask(
        FROM_HERE, base::BindOnce(
            [](int32_t window, int32_t tab) { barc_tab_close(window, tab); },
            id, tab_id));
  }
  window->GetTabStripModel()->CloseWebContents(
      tab->GetContents(), TabCloseTypes::CLOSE_USER_GESTURE |
                              TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
  return 1;
}
namespace {
int TransferTab(int32_t source_id, int32_t tab_id, int32_t destination_id,
                BarcTransferAdmission admission, void* context) {
  auto* source = Window(source_id);
  auto* destination = Window(destination_id);
  auto* tab = LookupTab(source, tab_id);
  if (!tab || !destination || source == destination ||
      source->GetProfile() != destination->GetProfile())
    return 0;
  if (navigation_callback_depth)
    return 0;
  if (!barc_window_select(destination_id))
    return 0;
  source = Window(source_id);
  destination = Window(destination_id);
  tab = LookupTab(source, tab_id);
  if (!tab || !destination ||
      source->GetProfile() != destination->GetProfile())
    return 0;
  auto* from = source->GetTabStripModel();
  const int source_index = from->GetIndexOfWebContents(tab->GetContents());
  const int pinned = from->IsTabPinned(source_index) ? AddTabTypes::ADD_PINNED : 0;
  const int rollback_types =
      pinned | (from->active_index() == source_index ? AddTabTypes::ADD_ACTIVE : 0);
  // A failed move must return the original live split, not just its page.
  const auto original_split = tab->GetSplit();
  const auto original_group = tab->GetGroup();
  auto* active_before = from->GetActiveTab();
  if (!active_before)
    return 0;
  const auto original_active = active_before->GetHandle().raw_value();
  auto source_alive = source->GetWeakPtr();
  std::vector<int32_t> split_members;
  std::optional<split_tabs::SplitTabVisualData> split_visual;
  std::optional<tabs::TabCollection::Handle> split_collection;
  if (original_split) {
    const auto* data = from->GetSplitData(*original_split);
    const auto members = data->ListTabs();
    if (members.size() < 2 || members.size() > 4 ||
        data->visual_data()->pane_count() != members.size())
      return 0;
    split_visual = *data->visual_data();
    split_collection = data->GetCollectionHandle();
    for (auto* member : members)
      split_members.push_back(member->GetHandle().raw_value());
  }
  const auto split_unchanged = [&](int32_t expected_active, bool inserted) {
    auto* owner = Window(source_id);
    if (!original_split || !source_alive || owner != source_alive.get())
      return false;
    auto* strip = owner->GetTabStripModel();
    auto* active = strip->GetActiveTab();
    if (!active || active->GetHandle().raw_value() != expected_active)
      return false;
    std::vector<int32_t> remaining;
    for (int32_t member : split_members) {
      if (member == tab_id && !inserted)
        continue;
      auto* current = LookupTab(owner, member);
      if (!current || current->GetGroup() != original_group ||
          current->IsPinned() != (pinned != 0))
        return false;
      if (member == tab_id) {
        if (current->IsSplit())
          return false;
      } else {
        remaining.push_back(member);
      }
    }
    if (remaining.size() == 1) {
      return !strip->ContainsSplit(*original_split) &&
             !LookupTab(owner, remaining.front())->IsSplit();
    }
    if (!strip->ContainsSplit(*original_split))
      return false;
    const auto* data = strip->GetSplitData(*original_split);
    const auto members = data->ListTabs();
    if (data->GetCollectionHandle() != *split_collection ||
        members.size() != remaining.size() ||
        *data->visual_data() != split_tabs::SplitTabVisualData::EqualSplit(
            split_visual->split_layout(), remaining.size()))
      return false;
    for (size_t i = 0; i < remaining.size(); ++i) {
      if (members[i]->GetHandle().raw_value() != remaining[i])
        return false;
    }
    return true;
  };
  // The ordinary empty-strip notification closes the source, so defer it until
  // the live tab is safely inserted or returned. Explicit closes still win.
  base::ScopedClosureRunner complete_detach(base::BindOnce(
      [](base::WeakPtr<BrowserWindowInterface> source) {
        if (source && !source->IsDeleteScheduled())
          source->GetTabStripModel()->NotifyEmptyAfterDeferredDetach();
      },
      source->GetWeakPtr()));
  auto detached = from->DetachTabAtForInsertion(source_index,
                                               /*notify_empty=*/false);
  if (!detached)
    return 0;
  // Detach notifies observers, which may close the destination. Restore to the
  // surviving source when possible; do not retain a dead destination strip.
  destination = Window(destination_id);
  const auto restore_source = [&]() -> int {
    if (auto* surviving_source = Window(source_id);
        source_alive && surviving_source == source_alive.get() &&
        !UnloadController::From(surviving_source)->owner_close_admitted()) {
      auto* strip = surviving_source->GetTabStripModel();
      int32_t after_detach_active = original_active;
      if (original_split && original_active == tab_id) {
        const size_t position = std::ranges::find(split_members, tab_id) -
                                split_members.begin();
        after_detach_active = position + 1 < split_members.size()
            ? split_members[position + 1] : split_members[position - 1];
      }
      const bool restore_split = split_unchanged(after_detach_active, false);
      int insertion = std::min(source_index, strip->count());
      // Do not dissolve a surviving or deliberately reconfigured split just
      // to return the detached page. Rebuild the original collection below
      // only if its identity, members, geometry and active pane still match.
      if (insertion < strip->count()) {
        if (const auto at = strip->GetSplitForTab(insertion)) {
          const auto range = strip->GetSplitData(*at)->GetIndexRange();
          if (insertion > static_cast<int>(range.start()))
            insertion = range.end();
        }
      }
      if (restore_split && split_members.size() > 2)
        insertion = strip->GetSplitData(*original_split)->GetIndexRange().end();
      // Keep the surviving active pane during reinsertion. Restoring an active
      // moved pane before its split would briefly hide/remount the other panes.
      const int returning_types = original_split
          ? rollback_types & ~AddTabTypes::ADD_ACTIVE : rollback_types;
      strip->InsertDetachedTabAt(insertion, std::move(detached), returning_types,
                                restore_split ? original_group : std::nullopt);
      if (restore_split && split_unchanged(after_detach_active, true)) {
        // Only this restoration phase defers destructive C callbacks; the
        // destination-close notification above retains its existing behavior.
        base::AutoReset depth(&navigation_callback_depth,
                              navigation_callback_depth + 1);
        if (split_members.size() > 2)
          strip->RemoveSplit(*original_split);
        surviving_source = Window(source_id);
        if (!source_alive || surviving_source != source_alive.get())
          return 0;
        strip = surviving_source->GetTabStripModel();
        std::vector<int> indices;
        for (int32_t member : split_members) {
          auto* current = LookupTab(surviving_source, member);
          if (!current || current->IsSplit() ||
              current->GetGroup() != original_group ||
              current->IsPinned() != (pinned != 0))
            return 0;
          indices.push_back(strip->GetIndexOfTab(current));
        }
        auto* active = strip->GetActiveTab();
        if (!active || active->GetHandle().raw_value() != after_detach_active)
          return 0;
        strip->RestoreSplit(*original_split, indices, *split_visual);
        surviving_source = Window(source_id);
        if (!source_alive || surviving_source != source_alive.get())
          return 0;
        strip = surviving_source->GetTabStripModel();
        active = strip->GetActiveTab();
        if (original_active != after_detach_active && active &&
            active->GetHandle().raw_value() == after_detach_active &&
            strip->ContainsSplit(*original_split)) {
          const auto* data = strip->GetSplitData(*original_split);
          const auto members = data->ListTabs();
          bool unchanged = *data->visual_data() == *split_visual &&
                           members.size() == split_members.size();
          for (size_t i = 0; unchanged && i < members.size(); ++i)
            unchanged = members[i]->GetHandle().raw_value() == split_members[i];
          if (unchanged) {
            auto* restored_active = LookupTab(surviving_source, original_active);
            if (restored_active)
              strip->ActivateTabAt(strip->GetIndexOfTab(restored_active));
          }
        }
      }
    }
    return 0;
  };
  if (!destination)
    return restore_source();
  auto* to = destination->GetTabStripModel();
  const int32_t previous_active = to->GetActiveTab()
      ? to->GetActiveTab()->GetHandle().raw_value() : 0;
  to->InsertDetachedTabAt(to->count(), std::move(detached),
                         AddTabTypes::ADD_ACTIVE | pinned);
  destination = Window(destination_id);
  if (!LookupTab(destination, tab_id))
    return 0;
  if (admission && !admission(context, destination_id, tab_id)) {
    // Admission may reenter close/transfer. Restore only if this exact tab still
    // belongs to this destination and the original source remains live.
    source = Window(source_id);
    destination = Window(destination_id);
    tab = LookupTab(destination, tab_id);
    if (!source || !tab || source->GetProfile() != destination->GetProfile() ||
        UnloadController::From(source)->owner_close_admitted())
      return 0;
    const bool restore_previous_active =
        destination->GetTabStripModel()->GetActiveTab() == tab;
    base::ScopedClosureRunner complete_rollback(base::BindOnce(
        [](base::WeakPtr<BrowserWindowInterface> destination) {
          if (destination && !destination->IsDeleteScheduled())
            destination->GetTabStripModel()->NotifyEmptyAfterDeferredDetach();
        }, destination->GetWeakPtr()));
    to = destination->GetTabStripModel();
    detached = to->DetachTabAtForInsertion(to->GetIndexOfTab(tab),
                                          /*notify_empty=*/false);
    if (!detached)
      return 0;
    destination = Window(destination_id);
    const int32_t active_after_detach = destination &&
            destination->GetTabStripModel()->GetActiveTab()
        ? destination->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value()
        : 0;
    source = Window(source_id);
    if (!source || UnloadController::From(source)->owner_close_admitted()) {
      // An explicit source close won during detach. Keep the live page in its
      // still-surviving destination instead of destroying it as rollback state.
      if (auto* surviving = Window(destination_id)) {
        if (!UnloadController::From(surviving)->owner_close_admitted()) {
          auto* strip = surviving->GetTabStripModel();
          strip->InsertDetachedTabAt(strip->count(), std::move(detached),
              pinned | (restore_previous_active ? AddTabTypes::ADD_ACTIVE : 0));
        }
      }
      return 0;
    }
    restore_source();
    destination = Window(destination_id);
    if (restore_previous_active && destination) {
      to = destination->GetTabStripModel();
      auto* active = to->GetActiveTab();
      const int32_t current_active = active ? active->GetHandle().raw_value() : 0;
      // Reinsertion/restoring a split notifies source observers. A newer
      // destination selection from those callouts must not be overwritten.
      if (current_active == active_after_detach) {
        if (auto* previous = LookupTab(destination, previous_active)) {
          if (previous != active)
            to->ActivateTabAt(to->GetIndexOfTab(previous));
        }
      }
    }
    return 0;
  }
  destination = Window(destination_id);
  tab = LookupTab(destination, tab_id);
  if (!tab)
    return 0;
  if (admission) ClearPeekRole(tab);
  if (destination->IsSelectedForNativeWindow() &&
      (!admission || destination->GetTabStripModel()->GetActiveTab() == tab))
    destination->GetWindow()->Show();
  return LookupTab(Window(destination_id), tab_id) ? 1 : 0;
}
}  // namespace
int barc_tab_transfer(int32_t source, int32_t tab, int32_t destination) {
  return TransferTab(source, tab, destination, nullptr, nullptr);
}
int barc_tab_transfer_with_admission(int32_t source, int32_t tab,
                                     int32_t destination,
                                     BarcTransferAdmission admission,
                                     void* context) {
  if (!admission) return 0;
  if (source == destination && !navigation_callback_depth) {
    auto* owner = Window(source);
    auto* page = LookupTab(owner, tab);
    if (!page || !PeekRoleFor(page) || UnloadController::From(owner)->owner_close_admitted()) return 0;
    auto alive = page->GetWeakPtr();
    if (!admission(context, destination, tab) || !alive ||
        LookupTab(Window(destination), tab) != alive.get()) return 0;
    ClearPeekRole(alive.get());
    return 1;
  }
  return TransferTab(source, tab, destination, admission, context);
}
int barc_window_select(int32_t id) {
  auto* window = Window(id);
  if (!window) {
    return 0;
  }
  const auto alive = window->GetWeakPtr();
  bool selected = false;
  if (auto* bark_window = bark::BarkBrowserWindow::FromBrowser(window)) {
    selected = bark_window->host()->Select(bark_window);
  } else if (auto* view = BrowserView::GetBrowserViewForBrowser(window)) {
    selected = view->browser_widget()->SelectLogicalBrowserView(view);
  }
  if (selected && alive &&
      bark::SetNativeSpacePageSuppressed(alive.get(), false)) {
    alive->NotifyNativeWindowSelectionChanged();
    barc::BrowserDiscoveryChanged();
  }
  return alive && alive->IsSelectedForNativeWindow() && selected;
}
size_t barc_tab_copy_launch_space(int32_t window, int32_t tab_id,
                                   char* buffer, size_t capacity) {
  base::span<char> output;
  if (buffer && capacity) {
    // SAFETY: C callers provide `capacity` writable bytes. Only this boundary
    // conversion trusts that claim; all subsequent copies use bounded spans.
    output = UNSAFE_BUFFERS(base::span<char>(buffer, capacity));
    output[0] = '\0';
  }
  auto* tab = LookupTab(Window(window), tab_id);
  auto* launch = tab ? static_cast<ApplicationLaunch*>(
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) : nullptr;
  if (!launch || launch->space.empty()) return 0;
  if (!output.empty()) {
    const size_t count = std::min(output.size() - 1, launch->space.size());
    output.first(count).copy_from(base::span(launch->space).first(count));
    output[count] = '\0';
  }
  return launch->space.size() + 1;
}
int barc_tab_application_pending(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
  return tab && tab->GetContents()->GetUserData(&kApplicationLaunchKey) ? 1 : 0;
}
size_t barc_tab_copy_title(int32_t id,
                           int32_t tab_id,
                           char* buffer,
                           size_t capacity) {
  base::span<char> output;
  if (buffer && capacity) {
    // SAFETY: This C ABI requires the caller to supply a writable allocation
    // containing at least capacity chars. Only the conversion trusts that
    // contract; all subsequent writes are bounded span operations.
    output = UNSAFE_BUFFERS(base::span<char>(buffer, capacity));
    output[0] = '\0';
  }
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab)
    return 0;
  const std::string title = base::UTF16ToUTF8(tab->GetContents()->GetTitle());
  if (buffer && capacity) {
    const size_t count = std::min(title.size(), capacity - 1);
    output.first(count).copy_from(base::span(title).first(count));
    output[count] = '\0';
  }
  return title.size() + 1;
}
int barc_window_show(int32_t id) {
  if (!barc_window_select(id))
    return 0;
  auto* window = Window(id);
  if (!window || !window->IsSelectedForNativeWindow())
    return 0;
  auto alive = window->GetWeakPtr();
  window->GetWindow()->Show();
  return alive && Window(id) == alive.get() &&
         alive->IsSelectedForNativeWindow();
}
int barc_window_attach_native_shell(int32_t id, void* native_view) {
  auto* window = Window(id);
  auto* browser_view = window ? BrowserView::GetBrowserViewForBrowser(window)
                              : nullptr;
  auto* host = browser_view ? browser_view->barc_native_shell() : nullptr;
  if (!host || attaching_native_shell)
    return 0;
  NSView* view = (__bridge NSView*)native_view;
  if (view.window && view.window !=
          browser_view->GetWidget()->GetNativeWindow().GetNativeNSWindow())
    return 0;
  auto owner = window->GetWeakPtr();
  auto browser = browser_view->GetAsWeakPtr();
  auto* selected_view = browser_view->browser_widget()->selected_browser_view();
  if (!selected_view)
    return 0;
  auto selected = selected_view->GetAsWeakPtr();
  auto* header_host = browser_view->barc_page_header();
  views::ViewTracker header_alive(header_host);
  BarcPageHeader* paired = browser_view->barc_compact_shell() ? nil : PageHeader(view);
  if (paired.view.window && paired.view.window !=
          browser_view->GetWidget()->GetNativeWindow().GetNativeNSWindow()) return 0;
  views::ViewTracker host_alive(host);
  const auto intact = [&] {
    return owner && Window(id) == owner.get() && browser && host_alive.view() &&
           BrowserView::GetBrowserViewForBrowser(owner.get()) == browser.get() &&
           browser->barc_native_shell() == host_alive.view() &&
           (!header_host || (header_alive.view() && browser->barc_page_header() == header_alive.view())) && selected &&
           browser->browser_widget()->selected_browser_view() == selected.get();
  };
  // Stack-owned guards survive synchronous native teardown. C close requests
  // are non-nestable deferred; native NSWindow.close is guarded inside Views.
  base::AutoReset<bool> attach_scope(&attaching_native_shell, true);
  base::AutoReset<int> callback_scope(&navigation_callback_depth,
                                      navigation_callback_depth + 1);
  browser->BarcNativeShellWillChange();
  // Hide the exact pair before any reentrant detach/hierarchy notification.
  if (header_host) {
    header_host->SetVisible(false);
    if (!intact()) return 0;
  }
  host->SetVisible(false);
  if (!intact()) return 0;
  if (header_host) {
    header_host->Detach();
    if (!intact()) return 0;
  }
  host->Detach();
  if (!intact())
    return 0;
  if (view) {
    host->Attach(gfx::NativeView(view));
    if (!intact() || host->native_view().GetNativeNSView() != view)
      return 0;
  }
  if (paired && header_host) {
    header_host->Attach(gfx::NativeView(paired.view));
    if (!intact() || header_host->native_view().GetNativeNSView() != paired.view) return 0;
    header_host->SetVisible(true);
    if (!intact()) return 0;
  }
  host->SetVisible(view != nil);
  if (!intact())
    return 0;
  browser->InvalidateLayout();
  return intact();
}


int barc_window_set_native_header(int32_t id, void* expected_sidebar,
    void* expected_header, void* replacement_header, int32_t height) {
  auto* owner = Window(id);
  auto* browser = owner ? BrowserView::GetBrowserViewForBrowser(owner) : nullptr;
  auto* sidebar_host = browser ? browser->barc_native_shell() : nullptr;
  auto* host = browser ? browser->barc_page_header() : nullptr;
  NSView* sidebar = (__bridge NSView*)expected_sidebar;
  NSView* expected = (__bridge NSView*)expected_header;
  NSView* replacement = (__bridge NSView*)replacement_header;
  if (!browser || browser->barc_compact_shell() || !sidebar_host || !host ||
      !sidebar || attaching_native_shell || height < 0 || height > 128 ||
      (replacement != nil) != (height > 0) || replacement == sidebar ||
      sidebar_host->native_view().GetNativeNSView() != sidebar ||
      host->native_view().GetNativeNSView() != expected ||
      (replacement.window && replacement.window != sidebar.window) ||
      (replacement != expected && replacement.superview)) return 0;
  BarcPageHeader* old = PageHeader(sidebar);
  if (expected == replacement && old.view == replacement && old.height == height) return 1;
  auto alive = browser->GetAsWeakPtr();
  auto owner_alive = owner->GetWeakPtr();
  views::ViewTracker sidebar_alive(sidebar_host), header_alive(host);
  const auto current = [&] {
    return alive && owner_alive && Window(id) == owner_alive.get() &&
        BrowserView::GetBrowserViewForBrowser(owner_alive.get()) == alive.get() &&
        sidebar_alive.view() && header_alive.view() &&
        alive->barc_native_shell() == sidebar_alive.view() &&
        alive->barc_page_header() == header_alive.view() &&
        sidebar_host->native_view().GetNativeNSView() == sidebar;
  };
  base::AutoReset<bool> attachment(&attaching_native_shell, true);
  base::AutoReset<int> callbacks(&navigation_callback_depth, navigation_callback_depth + 1);
  // A height-only update preserves the native responder and never reparents.
  if (expected != replacement) {
    host->SetVisible(false);
    if (!current()) return 0;
    host->Detach();
    if (!current()) return 0;
    if (replacement) {
      host->Attach(gfx::NativeView(replacement));
      if (!current() || host->native_view().GetNativeNSView() != replacement) return 0;
    }
  }
  BarcPageHeader* paired = nil;
  if (replacement) {
    paired = [[BarcPageHeader alloc] init]; paired.view = replacement; paired.height = height;
  }
  objc_setAssociatedObject(sidebar, &kNativePageHeaderKey, paired, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (!current()) return 0;
  host->SetVisible(replacement != nil);
  if (!current()) return 0;
  alive->InvalidateLayout();
  return current() && host->native_view().GetNativeNSView() == replacement;
}

int barc_window_native_shell_is_owned(int32_t id, void* expected_view) {
  auto* window = Window(id);
  auto* host = window ? bark::BarkWindowHost::ForBrowser(window) : nullptr;
  return host && !host->closing() &&
         host->root_view().GetNativeNSView() == (__bridge NSView*)expected_view;
}
int barc_window_detach_native_shell_if_owned(int32_t id, void* expected_view) {
  return expected_view && barc_window_native_shell_is_owned(id, expected_view)
             ? barc_window_attach_native_shell(id, nullptr) : 0;
}


namespace barc {
bool MarkApplicationPage(int32_t window, int32_t tab_id, uint64_t request,
                          std::string space) {
  auto* owner = Window(window);
  auto* tab = LookupTab(owner, tab_id);
  if (!tab || !request || tab->GetContents()->GetBrowserContext() != owner->GetProfile() ||
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return false;
  tab->GetContents()->SetUserData(&kApplicationLaunchKey,
      std::make_unique<ApplicationLaunch>(request, std::move(space), owner->GetProfile()->GetWeakPtr()));
  return true;
}
bool ApplicationPageMatches(int32_t window, int32_t tab_id, uint64_t request) {
  auto* owner = Window(window);
  auto* tab = LookupTab(owner, tab_id);
  auto* launch = tab ? static_cast<ApplicationLaunch*>(
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) : nullptr;
  return launch && launch->request == request && launch->profile &&
      owner->GetProfile() == launch->profile.get() &&
      tab->GetContents()->GetBrowserContext() == launch->profile.get();
}
bool SetApplicationPageResume(ApplicationPage page, base::RepeatingClosure resume) {
  if (!resume || !ApplicationPageMatches(page.window, page.tab, page.request))
    return false;
  auto* launch = static_cast<ApplicationLaunch*>(
      LookupTab(Window(page.window), page.tab)->GetContents()->GetUserData(
          &kApplicationLaunchKey));
  if (launch->resume) return false;
  launch->resume = std::move(resume);
  PendingApplicationPageIntents().Append(launch);
  NotifyApplicationBrowserAvailable();
  return true;
}
void DrainApplicationPageIntents() {
  auto& pending = PendingApplicationPageIntents();
  if (pending.empty()) return;
  // Re-read the front on the next event. A callback can consume any record,
  // close its owner or stop the runtime; never preserve an intrusive next node.
  auto resume = pending.head()->value()->resume;
  resume.Run();
}
void ClearApplicationPageIntents() {
  auto& pending = PendingApplicationPageIntents();
  while (!pending.empty()) {
    auto* launch = pending.head()->value();
    launch->RemoveFromList();
    launch->resume.Reset();
  }
}
void ConsumeApplicationPage(int32_t window, int32_t tab_id, uint64_t request) {
  if (ApplicationPageMatches(window, tab_id, request))
    LookupTab(Window(window), tab_id)->GetContents()->RemoveUserData(&kApplicationLaunchKey);
}
void AbandonApplicationPageRequest(int32_t tab_id, uint64_t request) {
  auto* tab = tabs::TabHandle(tab_id).Get();
  auto* launch = tab ? static_cast<ApplicationLaunch*>(
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) : nullptr;
  // Clearing this exact request's intrinsic hint is not a command against a
  // newer owner. A transferred page survives and cannot remain falsely pending.
  if (launch && launch->request == request && launch->profile &&
      tab->GetContents()->GetBrowserContext() == launch->profile.get())
    tab->GetContents()->RemoveUserData(&kApplicationLaunchKey);
}
}  // namespace barc
