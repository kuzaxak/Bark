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
#include "chrome/browser/ui/webui/certificate_viewer/certificate_viewer_webui.h"
#include "content/public/browser/document_user_data.h"
#include "ui/views/widget/widget.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/ssl/chrome_security_state_util.h"
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
#include "content/public/browser/ssl_status.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/weak_document_ptr.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "net/cert/cert_status_flags.h"
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
#include "bark/browser/ui/native_space_page.h"

using namespace barc::internal;

namespace {

class CertificateViewerOwner
    : public content::DocumentUserData<CertificateViewerOwner> {
 public:
  base::WeakPtr<views::Widget> widget;

 private:
  friend class content::DocumentUserData<CertificateViewerOwner>;
  explicit CertificateViewerOwner(content::RenderFrameHost* frame)
      : DocumentUserData(frame) {}
  DOCUMENT_USER_DATA_KEY_DECL();
};
DOCUMENT_USER_DATA_KEY_IMPL(CertificateViewerOwner);

int CertificateCommand(BrowserWindowInterface* window,
                       tabs::TabInterface* tab, int32_t command) {
  if (!tab || window->IsDeleteScheduled() || !window->GetWindow() ||
      !window->IsSelectedForNativeWindow() ||
      bark::IsNativeSpacePageSuppressed(window))
    return BARC_CERTIFICATE_UNAVAILABLE;
  auto* contents = tab->GetContents();
  if (contents->IsBeingDestroyed() ||
      contents->GetBrowserContext() != window->GetProfile())
    return BARC_CERTIFICATE_UNAVAILABLE;
  NSView* view = contents->GetNativeView().GetNativeNSView();
  gfx::NativeWindow parent = window->GetWindow()->GetNativeWindow();
  if (![view window] || [view window] != parent.GetNativeNSWindow() ||
      [view isHiddenOrHasHiddenAncestor] || ![parent.GetNativeNSWindow() isVisible])
    return BARC_CERTIFICATE_UNAVAILABLE;
  auto* frame = contents->GetPrimaryMainFrame();
  if (!frame)
    return BARC_CERTIFICATE_UNAVAILABLE;
  if (command == BARC_PAGE_CERTIFICATE_VIEWER_FOCUSED ||
      command == BARC_PAGE_CLOSE_CERTIFICATE_VIEWER) {
    auto* owner = CertificateViewerOwner::GetForCurrentDocument(frame);
    auto* widget = owner ? owner->widget.get() : nullptr;
    NSWindow* dialog_window =
        widget ? widget->GetNativeWindow().GetNativeNSWindow() : nil;
    if (!dialog_window || [NSApp keyWindow] != dialog_window)
      return 0;
    if (command == BARC_PAGE_CLOSE_CERTIFICATE_VIEWER && !widget->IsClosed())
      widget->Close();
    return 1;
  }
  auto& controller = contents->GetController();
  auto* entry = controller.GetLastCommittedEntry();
  if (!entry || entry != controller.GetVisibleEntry() ||
      !entry->GetURL().SchemeIs(url::kHttpsScheme) ||
      !entry->GetSSL().certificate)
    return BARC_CERTIFICATE_UNAVAILABLE;
  const bool certificate_error = net::IsCertStatusError(entry->GetSSL().cert_status);
  if (entry->GetPageType() != content::PAGE_TYPE_NORMAL &&
      (entry->GetPageType() != content::PAGE_TYPE_ERROR || !certificate_error))
    return BARC_CERTIFICATE_UNAVAILABLE;
  if (command == BARC_PAGE_CERTIFICATE_STATE) {
    return !certificate_error &&
                   chrome_security_state::GetSecurityLevel(contents) == security_state::SECURE
               ? BARC_CERTIFICATE_SECURE
               : BARC_CERTIFICATE_AVAILABLE;
  }
  auto* owner = CertificateViewerOwner::GetForCurrentDocument(frame);
  if (owner && owner->widget && !owner->widget->IsClosed())
    return 1;
  const auto document = frame->GetWeakDocumentPtr();
  auto* viewer = CertificateViewerDialog::ShowConstrained(
      entry->GetSSL().certificate->CopyCertBuffers(), contents, parent);
  if (viewer) {
    if (auto* widget = views::Widget::GetWidgetForNativeWindow(
            viewer->GetNativeWebContentsModalDialog())) {
      if (auto* document_frame = document.AsRenderFrameHostIfValid()) {
        CertificateViewerOwner::GetOrCreateForCurrentDocument(document_frame)
            ->widget = widget->GetWeakPtr();
      }
    }
  }
  return 1;
}
}  // namespace

int barc_tab_execute_command(int32_t window_id, int32_t tab_id,
                             int32_t command) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || navigation_callback_depth)
    return 0;
  auto* window = Window(window_id);
  auto* tab = LookupTab(window, tab_id);
  if (command == BARC_PAGE_SHOW_CERTIFICATE ||
      command == BARC_PAGE_CERTIFICATE_STATE ||
      command == BARC_PAGE_CERTIFICATE_VIEWER_FOCUSED ||
      command == BARC_PAGE_CLOSE_CERTIFICATE_VIEWER)
    return CertificateCommand(window, tab, command);
  if (command == BARC_PAGE_CLEAR_BACK_FORWARD_CACHE) {
    auto* unload = window ? UnloadController::From(window) : nullptr;
    auto* view = window ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
    if (!tab || window->IsDeleteScheduled() || !unload ||
        unload->owner_close_admitted() || unload->is_attempting_to_close_browser() ||
        (view && view->browser_widget()->HasPhysicalClosePending()) ||
        tab->GetContents()->IsBeingDestroyed() ||
        tab->GetContents()->GetBrowserContext() != window->GetProfile()) return 0;
    auto owner = window->GetWeakPtr();
    auto contents = tab->GetContents()->GetWeakPtr();
    auto* frame = contents->GetPrimaryMainFrame();
    if (!frame || !frame->IsRenderFrameLive() ||
        frame->GetLifecycleState() != content::RenderFrameHost::LifecycleState::kActive) return 0;
    auto document = frame->GetWeakDocumentPtr();
    contents->GetController().GetBackForwardCache().Flush();
    // Cache eviction may synchronously close/transfer/navigate the live page.
    // Re-resolve exact ownership; no borrowed tab/owner survives that callout.
    if (discovery_stopped || !owner || !contents || contents->IsBeingDestroyed() ||
        Window(window_id) != owner.get() || owner->IsDeleteScheduled() || UnloadController::From(owner.get())->owner_close_admitted() ||
        UnloadController::From(owner.get())->is_attempting_to_close_browser()) return 0;
    auto* current_view = BrowserView::GetBrowserViewForBrowser(owner.get());
    if (current_view && current_view->browser_widget()->HasPhysicalClosePending()) return 0;
    auto* current = LookupTab(owner.get(), tab_id);
    auto* current_document = document.AsRenderFrameHostIfValid();
    return current && current_document && current_document->IsRenderFrameLive() &&
        current_document->GetLifecycleState() == content::RenderFrameHost::LifecycleState::kActive &&
        current->GetContents() == contents.get() && contents->GetBrowserContext() == owner->GetProfile() &&
        current_document == contents->GetPrimaryMainFrame();
  }
  if (!tab || window->IsDeleteScheduled() ||
      tab->GetContents()->GetBrowserContext() != window->GetProfile() ||
      !window->IsSelectedForNativeWindow() ||
      bark::IsNativeSpacePageSuppressed(window) ||
      window->GetTabStripModel()->GetActiveWebContents() != tab->GetContents())
    return 0;
  if (command == BARC_PAGE_HARD_RELOAD &&
      NativeContentBlocker::IsRegistered() &&
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return 0;
  if (command == BARC_PAGE_VIDEO_PIP_TOGGLE) {
    auto* contents = tab->GetContents();
    // Document PiP has a different lifetime/UI contract; observing it does not
    // mean this video toggle may close or recreate it.
    if (contents->HasPictureInPictureDocument())
      return 0;
    auto* session = content::MediaSession::Get(contents);
    const bool exiting = contents->HasPictureInPictureVideo();
    const auto action = exiting
        ? media_session::mojom::MediaSessionAction::kExitPictureInPicture
        : media_session::mojom::MediaSessionAction::kEnterPictureInPicture;
    const auto actions = session->GetMediaSessionActionsSync();
    if (std::ranges::find(actions, action) == actions.end())
      return 0;
    // Use Chromium's normal routed user action. The site's registered handler
    // and native permission/activation checks remain authoritative. No owner or
    // contents are dereferenced after the potentially reentrant dispatch.
    if (exiting)
      session->ExitPictureInPicture();
    else
      session->EnterPictureInPicture();
    return 1;
  }
  const char* devtools_panel = nullptr;
  switch (command) {
    case BARC_PAGE_DEVTOOLS_CONSOLE: devtools_panel = "console"; break;
    case BARC_PAGE_DEVTOOLS_NETWORK: devtools_panel = "network"; break;
    case BARC_PAGE_DEVTOOLS_PERFORMANCE: devtools_panel = "timeline"; break;
    default: break;
  }
  if (devtools_panel) {
    if (!chrome::IsCommandEnabled(window, IDC_DEV_TOOLS) ||
        !DevToolsWindow::AllowDevToolsFor(window->GetProfile(), tab->GetContents()))
      return 0;
    DevToolsWindow::OpenDevToolsWindow(
        tab->GetContents(), window->GetProfile(),
        DevToolsOpenedByAction::kMainMenuOrMainShortcut,
        content::DevToolsManagerDelegate::DevToolsOptions(devtools_panel));
    return 1;
  }
  int chrome_command;
  switch (command) {
    case BARC_PAGE_FIND: chrome_command = IDC_FIND; break;
    case BARC_PAGE_FIND_NEXT: chrome_command = IDC_FIND_NEXT; break;
    case BARC_PAGE_FIND_PREVIOUS: chrome_command = IDC_FIND_PREVIOUS; break;
    case BARC_PAGE_ZOOM_IN: chrome_command = IDC_ZOOM_PLUS; break;
    case BARC_PAGE_ZOOM_OUT: chrome_command = IDC_ZOOM_MINUS; break;
    case BARC_PAGE_ZOOM_RESET: chrome_command = IDC_ZOOM_NORMAL; break;
    case BARC_PAGE_PRINT: chrome_command = IDC_PRINT; break;
    case BARC_PAGE_DEVTOOLS: chrome_command = IDC_DEV_TOOLS; break;
    case BARC_PAGE_DEVTOOLS_INSPECT: chrome_command = IDC_DEV_TOOLS_INSPECT; break;
    case BARC_PAGE_HARD_RELOAD: chrome_command = IDC_RELOAD_BYPASSING_CACHE; break;
    default: return 0;
  }
  if (!chrome::IsCommandEnabled(window, chrome_command) ||
      (command == BARC_PAGE_PRINT && !chrome::CanPrint(window)) ||
      ((command == BARC_PAGE_DEVTOOLS || command == BARC_PAGE_DEVTOOLS_INSPECT) &&
       !DevToolsWindow::AllowDevToolsFor(window->GetProfile(), tab->GetContents())))
    return 0;
  // No callback occurs between exact admission and controller dispatch. The
  // command itself may enter a modal loop: never dereference borrowed owners
  // or contents after this call, and do not reinterpret its result as UI completion.
  return chrome::ExecuteCommand(window, chrome_command);
}
int barc_tab_media_action(int32_t window_id, int32_t tab_id, int32_t action) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || navigation_callback_depth) return 0;
  auto* owner = Window(window_id);
  auto* tab = LookupTab(owner, tab_id);
  if (!tab || owner->IsDeleteScheduled() || UnloadController::From(owner)->owner_close_admitted() ||
      tab->GetContents()->GetBrowserContext() != owner->GetProfile()) return 0;
  auto* contents = tab->GetContents();
  auto* session = content::MediaSession::GetIfExists(contents);
  if (!session) return 0;
  auto* routed = session->GetRoutedFrame();
  if (!routed || !routed->IsActive() || routed->GetOutermostMainFrame() != contents->GetPrimaryMainFrame()) return 0;
  media_session::mojom::MediaSessionAction required;
  switch (action) {
    case BARC_MEDIA_PLAY: required = media_session::mojom::MediaSessionAction::kPlay; break;
    case BARC_MEDIA_PAUSE: required = media_session::mojom::MediaSessionAction::kPause; break;
    case BARC_MEDIA_PREVIOUS_TRACK: required = media_session::mojom::MediaSessionAction::kPreviousTrack; break;
    case BARC_MEDIA_NEXT_TRACK: required = media_session::mojom::MediaSessionAction::kNextTrack; break;
    default: return 0;
  }
  const auto actions = session->GetMediaSessionActionsSync();
  if (std::ranges::find(actions, required) == actions.end()) return 0;
  // The exact page may end/transfer during the normal routed callout. No native
  // owner is dereferenced afterward; no selection, activation or fallback occurs.
  switch (action) {
    case BARC_MEDIA_PLAY: session->Resume(content::MediaSession::SuspendType::kUI); break;
    case BARC_MEDIA_PAUSE: session->Suspend(content::MediaSession::SuspendType::kUI); break;
    case BARC_MEDIA_PREVIOUS_TRACK: session->PreviousTrack(); break;
    case BARC_MEDIA_NEXT_TRACK: session->NextTrack(); break;
  }
  return 1;
}
int barc_tab_set_muted(int32_t window_id, int32_t tab_id, int muted) {
  if (navigation_callback_depth || (muted != 0 && muted != 1))
    return 0;
  auto* window = Window(window_id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab || tab->GetContents()->GetBrowserContext() != window->GetProfile())
    return 0;
  auto contents = tab->GetContents()->GetWeakPtr();
  const bool accepted = SetTabAudioMuted(contents.get(), muted != 0,
                                        TabMutedReason::kAudioIndicator, {});
  // Audio observers can close or transfer the bound page. Never retain/use a
  // borrowed TabInterface across that callout or silently address its replacement.
  auto* current = LookupTab(Window(window_id), tab_id);
  return accepted && contents && current && current->GetContents() == contents.get();
}
size_t barc_tab_copy_history(int32_t window, int32_t tab_id, int32_t direction,
                             char* buffer, size_t capacity) {
  auto* owner = Window(window);
  auto* tab = LookupTab(owner, tab_id);
  if (!tab || (direction != 0 && direction != 1) ||
      tab->GetContents()->GetBrowserContext() != owner->GetProfile()) return 0;
  auto& controller = tab->GetContents()->GetController();
  base::ListValue entries;
  const int step = direction ? 1 : -1;
  for (int index = controller.GetCurrentEntryIndex() + step, scanned = 0;
       index >= 0 && index < controller.GetEntryCount() && scanned < 100;
       index += step, ++scanned) {
    auto* entry = controller.GetEntryAtIndex(index);
    if (!entry || entry->GetTitle().size() > 4096) continue;
    const std::string title = base::UTF16ToUTF8(entry->GetTitle());
    const std::string& url = entry->GetVirtualURL().spec();
    if (title.size() > 4096 || url.size() > 8192) continue;
    entries.Append(base::DictValue().Set("id", entry->GetUniqueID())
        .Set("title", title).Set("url", url));
  }
  std::string json;
  if (!base::JSONWriter::Write(entries, &json) || json.size() >= 1024 * 1024) return 0;
  const size_t required = json.size() + 1;
  if (buffer && capacity >= required) {
    // SAFETY: This C ABI requires the caller to supply a writable allocation
    // containing at least capacity chars. Only the conversion trusts that
    // contract; all subsequent writes are bounded span operations.
    auto output = UNSAFE_BUFFERS(base::span<char>(buffer, capacity));
    output.first(json.size()).copy_from(base::span(json));
    output[json.size()] = '\0';
  }
  return required;
}
int barc_tab_go_to_history_entry(int32_t window, int32_t tab_id, int32_t entry_id) {
  if (navigation_callback_depth || entry_id <= 0) return 0;
  auto* owner = Window(window);
  auto* tab = LookupTab(owner, tab_id);
  if (!tab || !owner->IsSelectedForNativeWindow() || !tab->IsActivated() ||
      tab->GetContents()->GetBrowserContext() != owner->GetProfile() ||
      (NativeContentBlocker::IsRegistered() &&
       tab->GetContents()->GetUserData(&kApplicationLaunchKey))) return 0;
  auto& controller = tab->GetContents()->GetController();
  for (int index = 0; index < controller.GetEntryCount(); ++index) {
    auto* entry = controller.GetEntryAtIndex(index);
    if (entry && entry->GetUniqueID() == entry_id) {
      controller.GoToIndex(index);
      return 1;
    }
  }
  return 0;
}
int barc_tab_go_back(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
  // Captured application/private intents own the first navigation until exact
  // context policy and model admission consume their intrinsic blank role.
  if (tab && NativeContentBlocker::IsRegistered() &&
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return 0;
  if (!tab || !tab->GetContents()->GetController().CanGoBack())
    return 0;
  tab->GetContents()->GetController().GoBack();
  return 1;
}
int barc_tab_go_forward(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
  // Captured application/private intents own the first navigation until exact
  // context policy and model admission consume their intrinsic blank role.
  if (tab && NativeContentBlocker::IsRegistered() &&
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return 0;
  if (!tab || !tab->GetContents()->GetController().CanGoForward())
    return 0;
  tab->GetContents()->GetController().GoForward();
  return 1;
}
int barc_tab_reload(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
  // Captured application/private intents own the first navigation until exact
  // context policy and model admission consume their intrinsic blank role.
  if (tab && NativeContentBlocker::IsRegistered() &&
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return 0;
  if (!tab)
    return 0;
  tab->GetContents()->GetController().Reload(content::ReloadType::NORMAL, true);
  return 1;
}
int barc_tab_stop(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
  if (!tab)
    return 0;
  tab->GetContents()->Stop();
  return 1;
}
