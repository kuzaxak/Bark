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

namespace {
NativeContentBlocker* BlockerForWindow(int32_t id, bool create = true) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || !barc::IsNativeApplicationRegistered() ||
      !NativeContentBlocker::IsRegistered()) return nullptr;
  auto* window = Window(id);
  if (!window || UnloadController::From(window)->owner_close_admitted())
    return nullptr;
  // Actual context, including independent OTR. Never resolve its original.
  return NativeContentBlocker::Get(window->GetProfile(), create);
}
std::optional<std::string> BlockerDomain(const char* input) {
  if (!input || !*input) return std::string();
  const GURL url(std::string("https://") + input);
  if (!url.is_valid() || url.host().empty() || url.has_username() ||
      url.has_password() || url.has_port() || url.has_query() || url.has_ref() ||
      url.path() != "/") return std::nullopt;
  return std::string(url.host());
}
}  // namespace

namespace {
NativeContentBlocker::Completion BlockerCompletion(
    BarcBlockerCallback callback, void* context,
    base::WeakPtr<BrowserWindowInterface> owner = {}, uint64_t context_id = 0) {
  struct Reply {
    BarcBlockerCallback callback;
    raw_ptr<void> context;
  };
  auto reply = std::make_unique<Reply>(Reply{callback, context});
  return base::BindOnce([](std::unique_ptr<Reply> reply,
                          base::WeakPtr<BrowserWindowInterface> owner,
                          uint64_t context_id, NativeContentBlocker::Result result) {
    if (context_id) {
      auto* service = owner && !owner->IsDeleteScheduled()
          ? BlockerForWindow(owner->GetSessionID().id(), false) : nullptr;
      if (!service || service->state().context_id != context_id)
        result.status = NativeContentBlocker::Result::kOwnerEnded;
    }
    auto callback = reply->callback;
    void* context = reply->context.get();
    reply->context = nullptr;
    reply.reset();
    {
      base::AutoReset<int> scope(&navigation_callback_depth,
                                 navigation_callback_depth + 1);
      callback(context, result.revision, static_cast<int32_t>(result.status));
    }
    barc::NotifyApplicationBrowserAvailable();
  }, std::move(reply), std::move(owner), context_id);
}
}  // namespace

int barc_blocker_state(int32_t window, BarcBlockerState* output) {
  if (!IsSized(output)) return 0;
  WriteKnownFields(output, BarcBlockerState{});
  auto* service = BlockerForWindow(window, false);
  if (!service) return 0;
  const auto state = service->state();
  WriteKnownFields(output, {0, state.context_id, state.publication_revision,
                            state.installed_revision, state.source_generation,
                            state.required_source_generation,
                            state.pending_revision, state.ready,
                            state.requested_policy});
  return 1;
}
int barc_blocker_set_policy(int32_t policy, uint64_t required_source_generation,
                            const char* const* domains, size_t count) {
  // This one registration call is passive before ChromeMain. Do not construct
  // stores, a keyed factory or workers to publish initially unresolved intent.
  if (![NSThread isMainThread] || discovery_stopped ||
      !barc::IsNativeApplicationRegistered() ||
      policy < BARC_BLOCKER_UNRESOLVED || policy > BARC_BLOCKER_ENABLED ||
      (!NativeContentBlocker::IsRegistered() && policy != BARC_BLOCKER_UNRESOLVED) ||
      (!domains && count) ||
      (policy == BARC_BLOCKER_UNRESOLVED && (count || required_source_generation)) ||
      (policy != BARC_BLOCKER_UNRESOLVED &&
       !content::BrowserThread::CurrentlyOn(content::BrowserThread::UI))) return 0;
  std::vector<std::string> parsed;
  for (const auto* domain : UNSAFE_BUFFERS(base::span(domains, count))) {
    auto host = BlockerDomain(domain);
    if (!host || host->empty()) return 0;
    parsed.push_back(std::move(*host));
  }
  return NativeContentBlocker::SetPolicy(
      static_cast<NativeContentBlocker::Policy>(policy), required_source_generation,
      std::move(parsed));
}
int barc_blocker_publish_rules(const uint8_t* bytes, size_t length,
    uint64_t source_generation, BarcBlockerCallback callback, void* context) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || !barc::IsNativeApplicationRegistered() ||
      !NativeContentBlocker::IsRegistered() || !callback || !source_generation ||
      ((bytes == nullptr) != (length == 0))) return 0;
  scoped_refptr<const base::RefCountedMemory> input;
  if (bytes) input = base::MakeRefCounted<base::RefCountedStaticMemory>(
      UNSAFE_BUFFERS(base::span(bytes, length)));
  NativeContentBlocker::PublishRules(std::move(input), source_generation,
                                     BlockerCompletion(callback, context));
  return 1;
}
int barc_blocker_prepare(int32_t window, BarcBlockerCallback callback, void* context) {
  if (!callback) return 0;
  auto* original = Window(window);
  auto owner = original ? original->GetWeakPtr()
                       : base::WeakPtr<BrowserWindowInterface>();
  auto* service = BlockerForWindow(window);
  if (!service || !owner || Window(window) != owner.get()) return 0;
  const uint64_t context_id = service->state().context_id;
  service->Prepare(BlockerCompletion(callback, context, std::move(owner), context_id));
  return 1;
}
int barc_blocker_set_tab_policy(int32_t window, int32_t tab_id, int oauth,
                                const char* continued_host,
                                uint64_t disabled_for_ms) {
  auto* owner = Window(window);
  auto* tab = owner ? LookupTab(owner, tab_id) : nullptr;
  auto domain = BlockerDomain(continued_host);
  if (!tab || !domain || (oauth != 0 && oauth != 1) ||
      disabled_for_ms > static_cast<uint64_t>(INT64_MAX)) return 0;
  auto* service = BlockerForWindow(window);
  if (!service) return 0;
  const bool published = service->SetTabPolicy(*tab, oauth != 0, std::move(*domain),
                                               base::Milliseconds(disabled_for_ms));
  // An exact asynchronous policy gate may settle after header admission or a
  // cached/disabled install. Wake the existing captured-intent drain once its
  // caller returns; this is not a resource request or readiness polling path.
  if (published) barc::NotifyApplicationBrowserAvailable();
  return published;
}
