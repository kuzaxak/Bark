#include "device/bluetooth/bluetooth_adapter_factory.h"
#include "device/bluetooth/test/mock_bluetooth_adapter.h"
#include "content/public/browser/content_browser_client.h"
#include "content/public/common/content_client.h"
#include "content/public/browser/web_authentication_delegate.h"
#include "content/public/test/web_contents_tester.h"
#include "chrome/test/base/testing_profile.h"
#include "base/test/test_future.h"
#include "chrome/browser/webauthn/chrome_authenticator_request_delegate.h"
#include "base/json/json_reader.h"
#include "base/base64.h"
#include "device/fido/authenticator_supported_options.h"
#include "device/fido/fido_discovery_factory.h"
#include "chrome/browser/webauthn/barc_vault_authenticator.h"
#include "chrome/browser/webauthn/authenticator_request_dialog_controller.h"
#include "chrome/browser/webauthn/authenticator_request_dialog_model.h"
#include "components/cbor/reader.h"
#include "components/cbor/writer.h"
#include "crypto/hash.h"
#include "device/fido/attestation_object.h"
#include "device/fido/authenticator_get_assertion_response.h"
#include "device/fido/authenticator_make_credential_response.h"
#include "device/fido/ctap_make_credential_request.h"
#include "device/fido/ctap_get_assertion_request.h"
#include "device/fido/fido_authenticator.h"
#include "device/fido/fido_discovery_base.h"
#include "device/fido/fido_test_data.h"
#include "base/base64url.h"
#include "chrome/browser/password_manager/chrome_password_manager_client.h"
#include "chrome/browser/ui/passwords/manage_passwords_ui_controller.h"
#include "components/password_manager/core/browser/mock_password_form_manager_for_ui.h"
#include "testing/gmock/include/gmock/gmock.h"
#import <AppKit/AppKit.h>
#import "chrome/browser/app_controller_mac.h"

#include "chrome/browser/ui/views/frame/barc_bridge.h"
#include "chrome/browser/ui/views/frame/barc_profiles.h"
#include "chrome/browser/ui/views/frame/barc_runtime_startup.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/renderer_context_menu/render_view_context_menu_test_util.h"
#include "chrome/app/chrome_command_ids.h"
#include "content/public/browser/back_forward_cache.h"
#include "components/performance_manager/public/decorators/page_live_state_decorator.h"
#include "components/performance_manager/public/features.h"
#include "components/performance_manager/public/performance_manager.h"
#include "content/public/common/content_features.h"
#include "content/public/browser/context_menu_params.h"
#include "chrome/browser/ui/browser_live_tab_context.h"
#include "base/run_loop.h"
#include "base/synchronization/waitable_event.h"
#include "chrome/browser/content_blocking/native_content_blocker.h"
#include "chrome/browser/content_blocking/barc_page_tweaks.h"
#include "chrome/browser/content_blocking/nook_adblock/nook_adblock.h"
#include "chrome/browser/extensions/chrome_test_extension_loader.h"
#include "extensions/browser/background_script_executor.h"
#include "extensions/test/test_extension_dir.h"
#include "extensions/test/extension_test_message_listener.h"

#include <algorithm>
#include "net/test/embedded_test_server/http_request.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/string_util.h"
#include <atomic>
#include <array>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>

#include "base/command_line.h"
#include "base/files/scoped_temp_dir.h"
#include "base/files/scoped_file.h"
#include "base/files/file_util.h"
#include "base/files/file_enumerator.h"
#include "base/files/scoped_temp_dir.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/storage_partition.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "net/base/isolation_info.h"
#include "net/traffic_annotation/network_traffic_annotation_test_helper.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/ref_counted_memory.h"
#include "base/scoped_observation.h"
#include "base/task/execution_fence.h"
#include "base/task/thread_pool/thread_pool_instance.h"
#include "base/test/bind.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/chrome_browser_main.h"
#include "chrome/browser/chrome_browser_main_extra_parts.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "base/threading/thread_restrictions.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/enterprise/data_protection/data_protection_navigation_controller.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/common/chrome_render_frame.mojom.h"
#include "content/public/test/back_forward_cache_util.h"
#include "content/public/test/prerender_test_util.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "chrome/browser/pdf/pdf_extension_test_util.h"
#include "chrome/browser/printing/oop_features.h"
#include "chrome/browser/printing/print_backend_service_test_impl.h"
#include "chrome/browser/printing/print_preview_dialog_controller.h"
#include "chrome/browser/printing/test_print_preview_observer.h"
#include "chrome/browser/ui/webui/print_preview/print_preview_ui.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/web_ui.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "components/infobars/content/content_infobar_manager.h"
#include "components/infobars/core/confirm_infobar_delegate.h"
#include "components/infobars/core/infobar.h"
#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"
#include "printing/backend/test_print_backend.h"
#include "printing/buildflags/buildflags.h"
#include "printing/print_job_constants.h"
#include "chrome/browser/download/download_prefs.h"
#include "third_party/blink/public/common/web_preferences/web_preferences.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "chrome/browser/file_select_helper.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/policy/developer_tools_policy_handler.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/sessions/session_service.h"
#include "chrome/browser/sessions/session_service_factory.h"
#include "chrome/browser/ui/browser_active_state_manager/browser_active_state_manager.h"
#include "chrome/browser/ui/browser_command_controller.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_element_identifiers.h"
#include "chrome/browser/ui/browser_init_state.h"
#include "chrome/browser/ui/browser_manager_service.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/embedder_browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/browser_window/public/profile_browser_collection.h"
#include "chrome/browser/ui/find_bar/find_bar.h"
#include "chrome/browser/ui/find_bar/find_bar_controller.h"
#include "chrome/browser/ui/tabs/tab_muted_utils.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "base/strings/string_number_conversions.h"
#include "chrome/browser/ui/views/tabs/tab/tab_accessibility.h"
#include "chrome/grit/generated_resources.h"
#include "ui/base/l10n/l10n_util.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/ui/views/frame/app_menu_button.h"
#include "chrome/browser/ui/views/bookmarks/bookmark_bar_view.h"
#include "chrome/browser/ui/views/download/download_in_progress_dialog_view.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/browser_widget.h"
#include "chrome/browser/ui/views/frame/contents_container_view.h"
#include "chrome/browser/ui/views/frame/contents_web_view.h"
#include "chrome/browser/ui/views/frame/multi_contents_view.h"
#include "chrome/browser/ui/views/frame/multi_contents_resize_area.h"
#include "chrome/browser/ui/views/frame/multi_contents_view_delegate.h"
#include "chrome/browser/ui/views/location_bar/location_bar_view.h"
#include "chrome/browser/ui/views/location_bar/zoom_bubble_coordinator.h"
#include "chrome/browser/ui/views/location_bar/zoom_bubble_view.h"
#include "components/tabs/public/split_tab_data.h"
#include "chrome/browser/ui/views/frame/tab_strip_region_view.h"
#include "chrome/browser/ui/views/side_panel/side_panel.h"
#include "chrome/browser/ui/views/tab_search_bubble_host.h"
#include "chrome/browser/ui/views/tabs/shared/tab_strip_combo_button.h"
#include "chrome/browser/ui/views/toolbar/toolbar_view.h"
#include "chrome/browser/ui/views/toolbar/webui_toolbar_web_view.h"
#include "chrome/common/chrome_switches.h"
#include "chrome/common/pref_names.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "chrome/common/chrome_features.h"
#include "ui/accessibility/ax_node_data.h"
#include "ui/accessibility/platform/ax_platform_node.h"
#include "ui/accessibility/platform/ax_platform_node_delegate.h"
#include "ui/base/hit_test.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/focus/focus_manager.h"
#include "components/download/public/common/download_item.h"
#include "components/enterprise/buildflags/buildflags.h"
#include "components/enterprise/data_controls/core/browser/test_utils.h"
#include "components/javascript_dialogs/app_modal_dialog_controller.h"
#include "components/javascript_dialogs/app_modal_dialog_view.h"
#include "components/prefs/pref_service.h"
#include "components/permissions/permission_request_manager.h"
#include "components/permissions/test/mock_permission_prompt_factory.h"
#include "components/permissions/test/mock_permission_request.h"
#include "components/sessions/core/session_id.h"
#include "components/tabs/public/tab_interface.h"
#include "components/zoom/zoom_controller.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/file_select_listener.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/hit_test_region_observer.h"
#include "components/download/database/download_db_conversions.h"
#include "components/download/public/common/download_source.h"
#include "components/download/public/common/download_features.h"
#include "components/download/public/common/parallel_download_configs.h"
#include "components/download/public/common/download_url_parameters.h"
#include "content/public/test/test_web_ui.h"
#include "chrome/browser/ui/webui/downloads/downloads_list_tracker.h"
#include "chrome/browser/ui/webui/downloads/downloads_dom_handler.h"
#include "chrome/browser/download/bubble/download_bubble_ui_controller.h"
#include "chrome/browser/download/download_commands.h"
#include "chrome/browser/download/download_item_model.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "content/public/test/url_loader_interceptor.h"
#include "content/public/test/download_test_observer.h"
#include "content/public/test/no_renderer_crashes_assertion.h"
#include "content/public/test/slow_download_http_response.h"
#include "content/public/test/test_navigation_observer.h"
#include "content/public/test/test_utils.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/install_default_websocket_handlers.h"
#include "chrome/browser/chrome_content_browser_client.h"
#include "services/network/public/mojom/websocket.mojom.h"
#include "net/test/embedded_test_server/create_websocket_handler.h"
#include "net/test/embedded_test_server/websocket_echo_handler.h"
#include "net/test/embedded_test_server/http_response.h"
#include "net/dns/mock_host_resolver.h"
#include "net/cookies/cookie_partition_key.h"
#include "net/cookies/cookie_partition_key_collection.h"
#include "net/test/embedded_test_server/controllable_http_response.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/base/window_open_disposition.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/codec/jpeg_codec.h"
#include "ui/shell_dialogs/fake_select_file_dialog.h"
#include "ui/views/window/non_client_view.h"
#include "ui/views/interaction/view_subregion_anchor.h"
#include "ui/events/event.h"
#include "ui/views/view_observer.h"
#include "ui/views/view_tracker.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/view_utils.h"
#include "ui/views/window/dialog_delegate.h"
#include "ui/views/widget/widget_observer.h"
#include "url/gurl.h"

@interface BarcReentrantNativeView : NSView
@property(copy) void (^onMove)(NSView*);
@property(copy) void (^onVisibility)(NSView*);
@end
@implementation BarcReentrantNativeView
@synthesize onMove = _onMove;
@synthesize onVisibility = _onVisibility;
- (void)setHidden:(BOOL)hidden {
  [super setHidden:hidden];
  auto callback = self.onVisibility;
  self.onVisibility = nil;
  if (callback)
    callback(self);
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  auto callback = self.onMove;
  self.onMove = nil;
  if (callback)
    callback(self);
}
@end

namespace {
struct NavigationEvent {
  int32_t kind;
  int32_t window;
  std::string url;
  std::string title;
  int32_t error;
  uint32_t flags;
};
struct NativeMediaEvent {
  int32_t window, tab;
  uint32_t flags;
  std::string title, artist, album;
};
class NavigationEvents {
 public:
  std::vector<NativeMediaEvent> media;
  bool unsubscribe_media = false;
  bool trace_media_commit = false;
  bool media_commit_observed = false;
  std::vector<std::string> metadata_after_commit;
  static void ReceiveMedia(void* context, uint64_t observation, int32_t window,
                           int32_t tab, uint32_t flags, const char* title,
                           const char* artist, const char* album) {
    auto* self = static_cast<NavigationEvents*>(context);
    EXPECT_EQ(self->token, observation);
    self->media.push_back({window, tab, flags, title, artist, album});
    if (self->media_commit_observed) self->metadata_after_commit.push_back(title);
    if (self->unsubscribe_media) barc_tab_unobserve(observation);
  }
  int thumbnail_calls = 0;
  uint64_t thumbnail_request = 0;
  std::vector<uint8_t> thumbnail;
  static void ReceiveThumbnail(void* context, uint64_t observation,
                               uint64_t request, const uint8_t* png, size_t size) {
    auto* self = static_cast<NavigationEvents*>(context);
    EXPECT_EQ(self->token, observation);
    ++self->thumbnail_calls;
    self->thumbnail_request = request;
    self->thumbnail = png && size
        ? UNSAFE_BUFFERS(std::vector<uint8_t>(png, png + size))
        : std::vector<uint8_t>();
  }
  struct FileReply { uint64_t request;int result,status;std::string path,mime;int64_t bytes;base::ScopedFD directory; };
  std::vector<FileReply> files;
  static void ReceiveFile(void* context,uint64_t observation,uint64_t request,int32_t result,int32_t status,
                          const char* path,const char* mime,int64_t bytes,int32_t directory) {
    auto* self=static_cast<NavigationEvents*>(context);
    EXPECT_EQ(self->token,observation);
    self->files.push_back({request,result,status,path,mime,bytes,base::ScopedFD(directory)});
  }
  std::vector<std::pair<uint64_t, std::string>> picks;
  static void ReceivePicker(void* context, uint64_t observation, uint64_t request,
      const char* selector, size_t length) {
    auto* self = static_cast<NavigationEvents*>(context);
    EXPECT_EQ(self->token, observation);
    EXPECT_LE(length, 2048u);
    self->picks.emplace_back(request, std::string(selector, length));
  }
  struct ScriptReply {
    uint64_t request; int32_t result; std::string text, json; bool is_string;
  };
  std::vector<ScriptReply> scripts;
  bool unsubscribe_script = false;
  static void ReceiveScript(void* context, uint64_t observation, uint64_t request,
      int32_t result, const char* text, size_t text_length,
      const char* json, size_t json_length, int32_t is_string) {
    auto* self = static_cast<NavigationEvents*>(context);
    EXPECT_EQ(self->token, observation);
    self->scripts.push_back({request, result, std::string(text, text_length),
                             std::string(json, json_length), is_string != 0});
    if (self->unsubscribe_script) barc_tab_unobserve(observation);
  }
  struct TranslationReply { uint64_t request; int32_t result; std::string payload; };
  std::vector<TranslationReply> translations;
  static void ReceiveTranslation(void* context, uint64_t observation,
      uint64_t generation, uint64_t request, int32_t result, const char* payload) {
    auto* self = static_cast<NavigationEvents*>(context);
    EXPECT_EQ(self->token, observation);
    self->translations.push_back({request, result, payload ? payload : ""});
  }
  std::vector<int32_t> style_results;
  static void ReceiveStyle(void* context, uint64_t observation,
                            uint64_t request, int32_t result) {
    auto* self = static_cast<NavigationEvents*>(context);
    EXPECT_EQ(self->token, observation);
    self->style_results.push_back(result);
  }
  std::vector<int32_t> site_results;
  static void SiteDataResult(void* context, uint64_t observation,
                              uint64_t request, int32_t result) {
    auto* self = static_cast<NavigationEvents*>(context);
    EXPECT_EQ(self->token, observation);
    self->site_results.push_back(result);
  }
  ~NavigationEvents() { barc_tab_unobserve(token); }
  static void Receive(void* context, uint64_t observation, int32_t kind,
                      int32_t window, int32_t tab, const char* url,
                      const char* title, int32_t error, uint32_t flags) {
    auto* self = static_cast<NavigationEvents*>(context);
    self->token = observation;
    self->events.push_back({kind, window, url, title, error, flags});
    if (kind == BARC_TAB_FAILED && self->on_failed) {
      std::move(self->on_failed).Run();
      return;
    }
    if (kind == BARC_TAB_CONTINUE_NATIVE_BLOCK && self->on_native_continue) {
      std::move(self->on_native_continue).Run();
      return;
    }
    if (self->trace_media_commit && kind == BARC_TAB_COMMITTED && !(flags & BARC_TAB_SAME_DOCUMENT))
      self->media_commit_observed = true;
    if (kind == BARC_TAB_INITIAL && self->release_owner) {
      auto* owner = self->release_owner.get();
      barc_tab_unobserve(observation);
      owner->reset();
      return;
    }
    if (kind == BARC_TAB_STATE && self->unsubscribe_audible && (flags & BARC_TAB_AUDIBLE)) {
      self->audio_unsubscribed = true;
      self->media_at_audio_unsubscribe = self->media.size();
      barc_tab_unobserve(observation);
      return;
    }
    if (kind == BARC_TAB_STATE && self->nested_media_owner) {
      auto* nested = self->nested_media_owner.get();
      self->nested_media_owner = nullptr;
      nested->token = barc_tab_observe(window, self->nested_media_tab, Receive, nested);
      EXPECT_NE(0u, nested->token);
      EXPECT_EQ(1, barc_tab_observe_media(nested->token, ReceiveMedia));
    }
    if (self->unsubscribe_initial && kind == BARC_TAB_INITIAL)
      barc_tab_unobserve(observation);
    if (kind == BARC_TAB_STARTED && self->transfer_destination) {
      EXPECT_EQ(0, barc_tab_transfer(window, tab, self->transfer_destination));
      self->transfer_refused = true;
    }
    if (kind == BARC_TAB_STARTED &&
        (self->close_started || self->close_window_started)) {
      if (self->unsubscribe_before_close)
        barc_tab_unobserve(observation);
      EXPECT_EQ(1, self->close_window_started ? barc_window_close(window)
                                            : barc_tab_close(window, tab));
    }
    if (kind == BARC_TAB_STATE && self->commands_on_audio_state &&
        (flags & BARC_TAB_MUTED)) {
      self->commands_on_audio_state = false;
      EXPECT_EQ(0, barc_tab_execute_command(window, tab, BARC_PAGE_ZOOM_IN));
      EXPECT_EQ(0, barc_tab_set_muted(window, tab, 0));
      self->audio_commands_refused = true;
      if (self->close_on_audio_state)
        EXPECT_EQ(1, barc_tab_close(window, tab));
    }
    if (kind == BARC_TAB_CLOSE_CANCELLED) {
      if (self->retry_cancelled) {
        self->retry_cancelled = false;
        EXPECT_EQ(1, barc_tab_close(window, tab));
      } else if (self->unsubscribe_cancelled) {
        barc_tab_unobserve(observation);
      }
      if (self->on_cancelled) std::move(self->on_cancelled).Run();
    }
    if (kind == BARC_TAB_CLOSED) {
      barc_tab_unobserve(observation);
      EXPECT_EQ(0u, barc_tab_observe(window, tab, Receive, context));
      if (self->on_closed)
        std::move(self->on_closed).Run();
    }
  }
  size_t Count(int32_t kind) const {
    return std::count_if(events.begin(), events.end(),
                        [kind](const auto& e) { return e.kind == kind; });
  }
  base::OnceClosure on_closed;
  base::OnceClosure on_cancelled;
  base::OnceClosure on_failed;
  base::OnceClosure on_native_continue;
  uint64_t token = 0;
  raw_ptr<std::unique_ptr<NavigationEvents>> release_owner = nullptr;
  bool unsubscribe_initial = false;
  bool close_started = false;
  bool close_window_started = false;
  bool unsubscribe_before_close = false;
  int32_t transfer_destination = 0;
  bool transfer_refused = false;
  raw_ptr<NavigationEvents> nested_media_owner = nullptr;
  int32_t nested_media_tab = 0;
  bool unsubscribe_audible = false;
  bool audio_unsubscribed = false;
  size_t media_at_audio_unsubscribe = 0;
  bool commands_on_audio_state = false;
  bool audio_commands_refused = false;
  bool close_on_audio_state = false;
  bool retry_cancelled = false;
  bool unsubscribe_cancelled = false;
  std::vector<NavigationEvent> events;
};

struct NativeDownloadEvent {
  int32_t kind;
  uint64_t manager;
  std::string profile, guid, target;
  int32_t state;
  uint32_t flags;
};
class NativeDownloadEvents {
 public:
  ~NativeDownloadEvents() { barc_downloads_unobserve(token); }
  static void Receive(void* context, uint64_t token, int32_t event,
                      const BarcDownloadSnapshot* row) {
    auto* self = static_cast<NativeDownloadEvents*>(context);
    self->token = token;
    self->events.push_back({event, row->manager, row->profile_uuid, row->guid,
                           row->target_path, row->state, row->flags});
    if (self->stop_first) { self->stop_first = false; barc_downloads_unobserve(token); }
  }
  std::optional<NativeDownloadEvent> Last(const std::string& profile, int32_t kind,
                                        int32_t state = -1) const {
    for (auto it = events.rbegin(); it != events.rend(); ++it)
      if (it->profile == profile && it->kind == kind && (state == -1 || it->state == state)) return *it;
    return std::nullopt;
  }
  uint64_t token = 0;
  bool stop_first = false;
  std::vector<NativeDownloadEvent> events;
};

// Preempt only after acceptance has started dismissing this exact warning.
class PreemptOnDownloadWarningDismissal : public views::WidgetObserver {
 public:
  PreemptOnDownloadWarningDismissal(views::Widget* warning,
                                    base::OnceClosure preempt)
      : preempt_(std::move(preempt)) {
    observation_.Observe(warning);
  }
  void OnWidgetVisibilityChanged(views::Widget*, bool visible) override {
    if (!visible) Preempt();
  }
  void OnWidgetDestroying(views::Widget*) override { Preempt(); }
 private:
  void Preempt() {
    observation_.Reset();
    if (preempt_) std::move(preempt_).Run();
  }
  base::OnceClosure preempt_;
  base::ScopedObservation<views::Widget, views::WidgetObserver> observation_{this};
};

// Keep cancellation observable without opening a real OS picker in mechanics.
class UploadSelectionListener : public content::FileSelectListener {
 public:
  int cancelled = 0;
  int selected = 0;

 private:
  ~UploadSelectionListener() override = default;
  void FileSelected(std::vector<blink::mojom::FileChooserFileInfoPtr>,
                    const base::FilePath&,
                    blink::mojom::FileChooserParams::Mode) override {
    ++selected;
  }
  void FileSelectionCanceled() override { ++cancelled; }
};

class ViewOwnerDeletionObserver : public views::ViewObserver {
 public:
  ViewOwnerDeletionObserver(BrowserWindowInterface* browser, BrowserView* view)
      : browser_(browser) {
    observation_.Observe(view);
  }
  void OnViewIsDeleting(views::View*) override {
    EXPECT_EQ(nullptr, BrowserView::Get(browser_->GetUnownedUserDataHost()));
    EXPECT_EQ(nullptr, BrowserView::GetBrowserViewForBrowser(browser_));
    observation_.Reset();
    browser_ = nullptr;
    deleted_ = true;
  }
  bool deleted() const { return deleted_; }

 private:
  raw_ptr<BrowserWindowInterface> browser_;
  bool deleted_ = false;
  base::ScopedObservation<views::View, views::ViewObserver> observation_{this};
};
// A source reinsertion observer may legally select a different destination tab.
class SelectDestinationOnSourceInsert : public TabStripModelObserver {
 public:
  SelectDestinationOnSourceInsert(TabStripModel* source, int32_t destination,
                                   int32_t tab)
      : destination_(destination), tab_(tab) { source->AddObserver(this); }
  void OnTabStripModelChanged(TabStripModel*, const TabStripModelChange& change,
                              const TabStripSelectionChange&) override {
    if (change.type() == TabStripModelChange::kInserted && !called_) {
      called_ = true;
      EXPECT_EQ(1, barc_tab_select(destination_, tab_));
    }
  }
  bool called() const { return called_; }
 private:
  const int32_t destination_;
  const int32_t tab_;
  bool called_ = false;
};

// Close a separate destination during the source's actual removal notification.
class CloseTransferDestination : public TabStripModelObserver {
 public:
  CloseTransferDestination(TabStripModel* source, int32_t destination,
                           int32_t select_after_close = 0)
      : destination_(destination), select_after_close_(select_after_close) {
    source->AddObserver(this);
  }
  void OnTabStripModelChanged(TabStripModel*,
                              const TabStripModelChange& change,
                              const TabStripSelectionChange&) override {
    if (change.type() == TabStripModelChange::kRemoved && !called_) {
      called_ = true;
      EXPECT_EQ(1, barc_window_close(destination_));
      if (select_after_close_)
        EXPECT_EQ(1, barc_window_select(select_after_close_));
    }
  }
  bool called() const { return called_; }

 private:
  const int32_t destination_;
  const int32_t select_after_close_;
  bool called_ = false;
};
}  // namespace

class BarcBridgeBrowserTest : public InProcessBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-native-shell");
  }
};

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, NativeShellRetainedUntilDetach) {
  const int32_t window = browser()->GetSessionID().id();
  auto* view = BrowserView::GetBrowserViewForBrowser(browser());
  ASSERT_NE(nullptr, view->barc_native_shell());
  __weak NSView* attached = nil;
  @autoreleasepool {
    NSView* replacement =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
    attached = replacement;
    ASSERT_EQ(1, barc_window_attach_native_shell(window,
                                                 (__bridge void*)replacement));
  }
  @autoreleasepool {
    EXPECT_NE(nil, attached);
    EXPECT_EQ(barc::kNativeShellWidth, barc::NativeShellWidth(view));
    ASSERT_EQ(1, barc_window_attach_native_shell(window, nullptr));
  }
  EXPECT_EQ(nil, attached);
  EXPECT_EQ(0, barc::NativeShellWidth(view));
  EXPECT_EQ(0, barc_window_attach_native_shell(-1, nullptr));

  const int32_t empty_peer = barc_window_new_peer(window);
  ASSERT_GT(empty_peer, 0);
  auto* peer = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(empty_peer));
  ui_test_utils::BrowserDestroyedObserver peer_closed(peer);
  EXPECT_EQ(0, barc_tab_create(empty_peer, "not a valid URL", 1));
  EXPECT_EQ(1, barc_window_close(empty_peer));
  peer_closed.Wait();
  EXPECT_EQ(0, barc_window_close(empty_peer));
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, NativeAttachReentrantCallbacks) {
  const int32_t primary = browser()->GetSessionID().id();
  auto* primary_view = BrowserView::GetBrowserViewForBrowser(browser());
  auto* popup = CreateBrowserWindow(BrowserWindowCreateParams(
      BrowserWindowInterface::TYPE_POPUP, browser()->GetProfile(), true));
  ASSERT_TRUE(popup);
  const int32_t popup_id = popup->GetSessionID().id();
  ASSERT_EQ(nullptr, BrowserView::GetBrowserViewForBrowser(popup)->barc_native_shell());
  EXPECT_EQ(0, barc_window_native_shell_is_owned(popup_id, nullptr));
  EXPECT_EQ(0, barc_window_set_native_header(popup_id, (__bridge void*)[[NSView alloc] init],
      nullptr, (__bridge void*)[[NSView alloc] init], 40));
  ui_test_utils::BrowserDestroyedObserver popup_closed(popup);
  ASSERT_EQ(1, barc_window_close(popup_id));
  popup_closed.Wait();
  BarcReentrantNativeView* shell = [[BarcReentrantNativeView alloc] init];
  NSView* nested = [[NSView alloc] init];
  shell.onMove = ^(NSView*) {
    EXPECT_EQ(0, barc_window_attach_native_shell(primary, (__bridge void*)nested));
    EXPECT_EQ(1, barc_window_select(primary));
  };
  ASSERT_EQ(1, barc_window_attach_native_shell(primary, (__bridge void*)shell));
  EXPECT_EQ(shell, primary_view->barc_native_shell()->native_view().GetNativeNSView());
  EXPECT_EQ(1, barc_window_native_shell_is_owned(primary, (__bridge void*)shell));
  BarcReentrantNativeView* page_bar = [[BarcReentrantNativeView alloc] init];
  __weak NSView* weak_sidebar = shell;
  __weak NSView* weak_nested = nested;
  __block bool reentered_header = false;
  page_bar.onMove = ^(NSView*) {
    reentered_header = true;
    EXPECT_EQ(0, barc_window_set_native_header(primary, (__bridge void*)weak_sidebar,
        nullptr, (__bridge void*)weak_nested, 38));
    EXPECT_EQ(0, barc_window_detach_native_shell_if_owned(primary, (__bridge void*)weak_sidebar));
  };
  ASSERT_EQ(1, barc_window_set_native_header(primary, (__bridge void*)shell,
      nullptr, (__bridge void*)page_bar, 40));
  EXPECT_TRUE(reentered_header);
  page_bar.onMove = nil;
  NSView* bar_parent = page_bar.superview;
  ASSERT_TRUE(bar_parent);
  ASSERT_EQ(1, barc_window_set_native_header(primary, (__bridge void*)shell,
      (__bridge void*)page_bar, (__bridge void*)page_bar, 40));
  EXPECT_EQ(bar_parent, page_bar.superview);
  ASSERT_EQ(1, barc_window_set_native_header(primary, (__bridge void*)shell,
      (__bridge void*)page_bar, (__bridge void*)page_bar, 38));
  EXPECT_EQ(bar_parent, page_bar.superview);
  EXPECT_EQ(38, barc::NativeShellHeight(primary_view));
  NSView* replacement_bar = [[NSView alloc] init];
  ASSERT_EQ(1, barc_window_set_native_header(primary, (__bridge void*)shell,
      (__bridge void*)page_bar, (__bridge void*)replacement_bar, 40));
  EXPECT_EQ(0, barc_window_set_native_header(primary, (__bridge void*)shell,
      (__bridge void*)page_bar, nullptr, 0));
  EXPECT_EQ(replacement_bar, primary_view->barc_page_header()->native_view().GetNativeNSView());
  EXPECT_EQ(0, barc_window_set_native_header(primary, (__bridge void*)nested,
      (__bridge void*)replacement_bar, nullptr, 0));
  ASSERT_EQ(1, barc_window_set_native_header(primary, (__bridge void*)shell,
      (__bridge void*)replacement_bar, nullptr, 0));
  EXPECT_FALSE(replacement_bar.superview);
  EXPECT_EQ(0, barc::NativeShellHeight(primary_view));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(primary, (__bridge void*)nested));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(primary, nullptr));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(-1, (__bridge void*)shell));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(-1, nullptr));
  EXPECT_EQ(0, barc_window_detach_native_shell_if_owned(primary, (__bridge void*)nested));
  EXPECT_EQ(0, barc_window_detach_native_shell_if_owned(primary, nullptr));
  EXPECT_EQ(0, barc_window_detach_native_shell_if_owned(-1, (__bridge void*)shell));
  EXPECT_EQ(shell, primary_view->barc_native_shell()->native_view().GetNativeNSView());
  EXPECT_EQ(1, barc_window_detach_native_shell_if_owned(primary, (__bridge void*)shell));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(primary, (__bridge void*)shell));
  EXPECT_EQ(1, barc_window_native_shell_is_owned(primary, nullptr));
  EXPECT_EQ(0, barc_window_detach_native_shell_if_owned(primary, nullptr));
  EXPECT_EQ(1, barc_window_native_shell_is_owned(primary, nullptr));
  EXPECT_EQ(1, barc_window_attach_native_shell(primary, (__bridge void*)nested));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(primary, (__bridge void*)shell));
  EXPECT_EQ(1, barc_window_native_shell_is_owned(primary, (__bridge void*)nested));
  EXPECT_EQ(0, barc_window_detach_native_shell_if_owned(primary, (__bridge void*)shell));
  EXPECT_EQ(1, barc_window_native_shell_is_owned(primary, (__bridge void*)nested));
  EXPECT_EQ(1, barc_window_attach_native_shell(primary, (__bridge void*)shell));
  shell.onMove = ^(NSView*) {
    EXPECT_EQ(0, barc_window_attach_native_shell(primary, (__bridge void*)nested));
  };
  ASSERT_EQ(1, barc_window_attach_native_shell(primary, nullptr));
  EXPECT_FALSE(primary_view->barc_native_shell()->native_view());

  // Raw Cocoa close bypasses C-ABI close deferral during both reparenting
  // and the NativeViewHost visibility callout.
  for (bool close_on_visibility : {false, true}) {
    const int32_t peer = barc_window_new_peer(primary);
    ASSERT_GT(peer, 0);
    ASSERT_NE(0, barc_tab_create(peer, "about:blank", 0));
    auto* owner = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
        SessionID::FromSerializedValue(peer));
    auto alive = owner->GetWeakPtr();
    auto* peer_view = BrowserView::GetBrowserViewForBrowser(owner);
    auto view_alive = peer_view->GetAsWeakPtr();
    NSWindow* native_window = peer_view->GetWidget()->GetNativeWindow().GetNativeNSWindow();
    BarcReentrantNativeView* closing = [[BarcReentrantNativeView alloc] init];
    if (close_on_visibility)
      closing.onVisibility = ^(NSView*) { [native_window close]; };
    else
      closing.onMove = ^(NSView*) { [native_window close]; };
    EXPECT_EQ(0, barc_window_attach_native_shell(peer, (__bridge void*)closing));
    EXPECT_FALSE(view_alive);
    ASSERT_TRUE(base::test::RunUntil([&] { return !alive; }));
    EXPECT_NE(nullptr, primary_view->barc_native_shell());
  }
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, ClosedDistinguishesOwnerShutdown) {
  const int32_t primary = browser()->GetSessionID().id();
  for (int close_kind : {0, 1, 2, 3}) {
    SCOPED_TRACE(close_kind);
    const int32_t peer = barc_window_new_peer(primary);
    ASSERT_GT(peer, 0);
    const int32_t tab = barc_tab_create(peer, "about:blank", 0);
    ASSERT_NE(0, tab);
    NavigationEvents events;
    ASSERT_NE(0u, barc_tab_observe(peer, tab, NavigationEvents::Receive, &events));
    if (close_kind == 0) {
      ASSERT_EQ(1, barc_tab_close(peer, tab));
    } else if (close_kind == 1) {
      ASSERT_TRUE(content::ExecJs(tabs::TabHandle(tab).Get()->GetContents(),
                                  "window.close();"));
    } else if (close_kind == 2) {
      ASSERT_EQ(1, barc_window_close(peer));
    } else {
      auto* owner = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
          SessionID::FromSerializedValue(peer));
      [owner->GetWindow()->GetNativeWindow().GetNativeNSWindow() close];
    }
    ASSERT_TRUE(base::test::RunUntil([&] { return events.Count(BARC_TAB_CLOSED) == 1; }));
    const auto terminal = std::find_if(events.events.begin(), events.events.end(),
        [](const auto& event) { return event.kind == BARC_TAB_CLOSED; });
    ASSERT_NE(events.events.end(), terminal);
    EXPECT_EQ(close_kind >= 2, !!(terminal->flags & BARC_TAB_OWNER_ENDED));
  }
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       LastPopupTabAdmissionRefusalRetainsDocumentAndOpener) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),
      embedded_test_server()->GetURL("/title1.html")));
  auto* opener = browser()->GetTabStripModel()->GetActiveWebContents();
  ui_test_utils::BrowserCreatedObserver added;
  ASSERT_TRUE(content::ExecJs(opener, content::JsReplace(
      "window.mini = window.open($1, 'mini', 'popup,width=640,height=480')",
      embedded_test_server()->GetURL("/title2.html"))));
  auto* source = added.Wait();
  ASSERT_TRUE(source);
  ASSERT_EQ(BrowserWindowInterface::TYPE_POPUP, source->GetType());
  ASSERT_EQ(1, source->GetTabStripModel()->count());
  auto* contents = source->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  ASSERT_TRUE(content::ExecJs(contents,
      "document.body.innerHTML = '<input id=draft>';"
      "draft.value = 'unsaved'; window.liveMarker = {value: 'same'};"));
  ASSERT_EQ(true, content::EvalJs(contents, "window.opener !== null"));
  const int history = contents->GetController().GetEntryCount();
  const int32_t source_id = source->GetSessionID().id();
  const int32_t tab_id = tabs::TabInterface::GetFromContents(contents)->GetHandle().raw_value();
  const int32_t destination_id = browser()->GetSessionID().id();
  struct Admission {
    base::WeakPtr<BrowserWindowInterface> source;
    bool called = false;
    bool accept = false;
    int32_t newer_selection = 0;
  } admission{source->GetWeakPtr()};
  const auto decide = [](void* context, int32_t window, int32_t tab) -> int {
    auto* admission = static_cast<Admission*>(context);
    admission->called = true;
    EXPECT_TRUE(admission->source);
    if (!admission->source) return 0;
    EXPECT_EQ(0, admission->source->GetTabStripModel()->count());
    EXPECT_FALSE(admission->source->IsDeleteScheduled());
    EXPECT_FALSE(UnloadController::From(admission->source.get())
                     ->is_attempting_to_close_browser());
    EXPECT_GT(barc_tab_copy_title(window, tab, nullptr, 0), 0u);
    if (admission->newer_selection)
      EXPECT_EQ(1, barc_tab_select(window, admission->newer_selection));
    return admission->accept;
  };
  EXPECT_EQ(0, barc_tab_transfer_with_admission(source_id, tab_id,
      destination_id, decide, &admission));
  ASSERT_TRUE(admission.called);
  ASSERT_TRUE(admission.source);
  EXPECT_EQ(1, source->GetTabStripModel()->count());
  EXPECT_EQ(contents, source->GetTabStripModel()->GetActiveWebContents());
  EXPECT_EQ(opener, browser()->GetTabStripModel()->GetActiveWebContents());
  EXPECT_EQ("unsaved", content::EvalJs(contents, "draft.value"));
  EXPECT_EQ("same", content::EvalJs(contents, "liveMarker.value"));
  EXPECT_EQ(true, content::EvalJs(contents, "window.opener !== null"));
  EXPECT_EQ(history, contents->GetController().GetEntryCount());
  const int32_t newer = barc_tab_create(destination_id, "about:blank", 0);
  ASSERT_GT(newer, 0);
  admission.called = false;
  admission.newer_selection = newer;
  EXPECT_EQ(0, barc_tab_transfer_with_admission(source_id, tab_id,
      destination_id, decide, &admission));
  EXPECT_TRUE(admission.called);
  ASSERT_TRUE(admission.source);
  EXPECT_EQ(contents, source->GetTabStripModel()->GetActiveWebContents());
  EXPECT_EQ(tabs::TabHandle(newer).Get()->GetContents(),
            browser()->GetTabStripModel()->GetActiveWebContents());
  EXPECT_EQ("unsaved", content::EvalJs(contents, "draft.value"));
  // Source reinsertion is another callback boundary, after the original
  // refusal. Give automatic detach a different successor, then deliberately
  // select `newer` from the source observer; rollback must preserve it.
  ASSERT_GT(barc_tab_create(destination_id, "about:blank", 0), 0);
  const int32_t opener_tab = tabs::TabInterface::GetFromContents(opener)->GetHandle().raw_value();
  ASSERT_EQ(1, barc_tab_select(destination_id, opener_tab));
  admission.called = false;
  admission.newer_selection = 0;
  {
    SelectDestinationOnSourceInsert select_on_restore(
        source->GetTabStripModel(), destination_id, newer);
    EXPECT_EQ(0, barc_tab_transfer_with_admission(source_id, tab_id,
        destination_id, decide, &admission));
    EXPECT_TRUE(select_on_restore.called());
  }
  EXPECT_TRUE(admission.called);
  ASSERT_TRUE(admission.source);
  EXPECT_EQ(contents, source->GetTabStripModel()->GetActiveWebContents());
  EXPECT_EQ(tabs::TabHandle(newer).Get()->GetContents(),
            browser()->GetTabStripModel()->GetActiveWebContents());
  EXPECT_EQ("unsaved", content::EvalJs(contents, "draft.value"));
  admission.called = false;
  admission.newer_selection = 0;
  admission.accept = true;
  ui_test_utils::BrowserDestroyedObserver closed(source);
  ASSERT_EQ(1, barc_tab_transfer_with_admission(source_id, tab_id,
      destination_id, decide, &admission));
  EXPECT_TRUE(admission.called);
  closed.Wait();
  EXPECT_EQ(contents, tabs::TabHandle(tab_id).Get()->GetContents());
  EXPECT_EQ("unsaved", content::EvalJs(contents, "draft.value"));
  EXPECT_EQ(true, content::EvalJs(contents, "window.opener !== null"));
  EXPECT_EQ(history, contents->GetController().GetEntryCount());
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       LastTabTransferAndCompletedClose) {
  // Keep the primary test window alive throughout both last-tab window closes.
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL first_url = embedded_test_server()->GetURL("/title1.html");
  const GURL second_url = embedded_test_server()->GetURL("/title2.html");
  const int32_t primary = browser()->GetSessionID().id();
  const int32_t source = barc_window_new_peer(primary);
  ASSERT_GT(source, 0);
  const int32_t page = barc_tab_create(source, first_url.spec().c_str(), 1);
  ASSERT_NE(0, page);
  auto* contents = tabs::TabHandle(page).Get()->GetContents();
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  {
    content::TestNavigationObserver navigated(contents);
    ASSERT_EQ(1, barc_tab_navigate(source, page, second_url.spec().c_str()));
    navigated.Wait();
  }
  ASSERT_EQ(second_url, contents->GetLastCommittedURL());
  const int history_entries = contents->GetController().GetEntryCount();
  ASSERT_GE(history_entries, 2);
  ASSERT_TRUE(content::ExecJs(contents,
                              "window.marker = 'original document';"
                              "document.body.innerHTML = '<input id=draft>';"));
  ASSERT_TRUE(content::ExecJs(
      contents,
      "document.querySelector('#draft').value = 'unsaved draft';"
      "document.body.style.height = '6000px'; window.scrollTo(0, 1200);"));
  ASSERT_EQ(1200, content::EvalJs(contents, "window.scrollY"));

  const int32_t destination = barc_window_new_peer(primary);
  ASSERT_GT(destination, 0);
  auto* collection = GlobalBrowserCollection::GetInstance();
  auto* source_browser =
      collection->FindBrowserWithID(SessionID::FromSerializedValue(source));
  ui_test_utils::BrowserDestroyedObserver source_closed(source_browser);
  ASSERT_EQ(1, barc_tab_transfer(source, page, destination));
  source_closed.Wait();
  EXPECT_EQ(nullptr, collection->FindBrowserWithID(
                         SessionID::FromSerializedValue(source)));
  ASSERT_NE(nullptr, tabs::TabHandle(page).Get());
  EXPECT_EQ(contents, tabs::TabHandle(page).Get()->GetContents());
  EXPECT_EQ("original document", content::EvalJs(contents, "window.marker"));
  EXPECT_EQ(
      "unsaved draft",
      content::EvalJs(contents, "document.querySelector('#draft').value"));
  EXPECT_EQ(1200, content::EvalJs(contents, "window.scrollY"));
  EXPECT_EQ(history_entries, contents->GetController().GetEntryCount());
  EXPECT_TRUE(contents->GetController().CanGoBack());
  {
    content::TestNavigationObserver went_back(contents);
    contents->GetController().GoBack();
    went_back.Wait();
  }
  EXPECT_EQ(first_url, contents->GetLastCommittedURL());
  EXPECT_EQ(0, barc_tab_select(source, page));
  EXPECT_EQ(0, barc_tab_navigate(primary, page, "about:blank"));
  EXPECT_EQ(1, barc_tab_select(destination, page));

  auto* destination_browser = collection->FindBrowserWithID(
      SessionID::FromSerializedValue(destination));
  ui_test_utils::BrowserDestroyedObserver destination_closed(
      destination_browser);
  content::WebContentsDestroyedWatcher document_destroyed(contents);
  ASSERT_EQ(1, barc_tab_close(destination, page));
  document_destroyed.Wait();
  destination_closed.Wait();
  EXPECT_EQ(nullptr, tabs::TabHandle(page).Get());
  EXPECT_EQ(0, barc_tab_close(destination, page));
  EXPECT_EQ(0, barc_tab_create(source, "about:blank", 1));
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       LastTabTransferCancellationRetainsLiveSource) {
  const int32_t primary = browser()->GetSessionID().id();
  const int32_t source_id = barc_window_new_peer(primary);
  const int32_t destination_id = barc_window_new_peer(primary);
  ASSERT_GT(source_id, 0);
  ASSERT_GT(destination_id, 0);
  const int32_t page = barc_tab_create(source_id, "about:blank", 1);
  ASSERT_NE(0, page);
  auto* contents = tabs::TabHandle(page).Get()->GetContents();
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  ASSERT_TRUE(content::ExecJs(contents,
                              "window.liveMarker = 'retained';"
                              "document.body.innerHTML = '<input id=draft>';"
                              "draft.value = 'unsaved';"));
  auto* source = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(source_id));
  ASSERT_NE(nullptr, source);
  auto* strip = source->GetTabStripModel();
  CloseTransferDestination cancellation(strip, destination_id);
  EXPECT_EQ(0, barc_tab_transfer(source_id, page, destination_id));
  ASSERT_TRUE(cancellation.called());
  ASSERT_EQ(source, GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
                        SessionID::FromSerializedValue(source_id)));
  EXPECT_FALSE(source->IsDeleteScheduled());
  EXPECT_FALSE(
      UnloadController::From(source)->is_attempting_to_close_browser());
  ASSERT_EQ(1, strip->count());
  ASSERT_NE(nullptr, tabs::TabHandle(page).Get());
  EXPECT_EQ(contents, tabs::TabHandle(page).Get()->GetContents());
  EXPECT_EQ(contents, strip->GetActiveWebContents());
  EXPECT_EQ("retained", content::EvalJs(contents, "liveMarker"));
  EXPECT_EQ("unsaved", content::EvalJs(contents, "draft.value"));
  EXPECT_EQ(1, barc_tab_select(source_id, page));
  const int32_t extra = barc_tab_create(source_id, "about:blank", 0);
  EXPECT_NE(0, extra);
  EXPECT_EQ(contents, strip->GetActiveWebContents());
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       BackgroundTransferCancellationPreservesSelectionAndPin) {
  const int32_t primary = browser()->GetSessionID().id();
  const int32_t source_id = barc_window_new_peer(primary);
  const int32_t destination_id = barc_window_new_peer(primary);
  ASSERT_GT(source_id, 0);
  ASSERT_GT(destination_id, 0);
  const int32_t selected = barc_tab_create(source_id, "about:blank", 1);
  const int32_t background = barc_tab_create(source_id, "about:blank", 0);
  ASSERT_NE(0, selected);
  ASSERT_NE(0, background);
  auto* source = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(source_id));
  ASSERT_NE(nullptr, source);
  auto* strip = source->GetTabStripModel();
  auto* selected_contents = tabs::TabHandle(selected).Get()->GetContents();
  auto* background_contents = tabs::TabHandle(background).Get()->GetContents();
  ASSERT_TRUE(content::WaitForLoadStop(background_contents));
  strip->SetTabPinned(strip->GetIndexOfWebContents(background_contents), true);
  ASSERT_EQ(selected_contents, strip->GetActiveWebContents());
  CloseTransferDestination cancellation(strip, destination_id);
  EXPECT_EQ(0, barc_tab_transfer(source_id, background, destination_id));
  ASSERT_TRUE(cancellation.called());
  EXPECT_FALSE(source->IsDeleteScheduled());
  EXPECT_FALSE(
      UnloadController::From(source)->is_attempting_to_close_browser());
  ASSERT_EQ(2, strip->count());
  ASSERT_NE(nullptr, tabs::TabHandle(background).Get());
  EXPECT_EQ(background_contents,
            tabs::TabHandle(background).Get()->GetContents());
  EXPECT_EQ(selected_contents, strip->GetActiveWebContents());
  const int restored = strip->GetIndexOfWebContents(background_contents);
  ASSERT_NE(TabStripModel::kNoTab, restored);
  EXPECT_TRUE(strip->IsTabPinned(restored));
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, BrowserLookupUsesLogicalOwner) {
  EXPECT_EQ(nullptr, BrowserView::GetBrowserViewForBrowser(nullptr));
  using Result = base::test::TestFuture<barc_profile_status, int32_t>;
  Result opened;
  barc_profile_open_window(
      "b482ffdf-5bb1-4f77-b176-12f17ae8f1af", BARC_PROFILE_SETTINGS,
      [](barc_profile_status status, int32_t window, void* data) {
        static_cast<Result*>(data)->SetValue(status, window);
      },
      &opened);
  ASSERT_EQ(BARC_PROFILE_OK, opened.Get<0>());
  const int32_t peer_id = opened.Get<1>();
  auto* peer = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(peer_id));
  ASSERT_NE(nullptr, peer);
  EXPECT_NE(browser()->GetProfile(), peer->GetProfile());
  auto* first_view = BrowserView::GetBrowserViewForBrowser(browser());
  auto* peer_view = BrowserView::GetBrowserViewForBrowser(peer);
  ASSERT_NE(nullptr, first_view);
  ASSERT_NE(nullptr, peer_view);
  ASSERT_NE(first_view, peer_view);
  auto* widget = first_view->GetWidget();
  void* original =
      widget->GetNativeWindowProperty(BrowserView::kBrowserViewKey);
  // Deliberately conflict physical metadata without sharing/moving widgets.
  // This is a lookup prerequisite regression, not a composition proof.
  widget->SetNativeWindowProperty(BrowserView::kBrowserViewKey, peer_view);
  EXPECT_EQ(peer_view, BrowserView::GetBrowserViewForNativeWindow(
                           widget->GetNativeWindow()));
  EXPECT_EQ(first_view, BrowserView::GetBrowserViewForBrowser(browser()));
  EXPECT_EQ(peer_view, BrowserView::GetBrowserViewForBrowser(peer));
  widget->SetNativeWindowProperty(BrowserView::kBrowserViewKey, original);

  ViewOwnerDeletionObserver view_deleted(peer, peer_view);
  ui_test_utils::BrowserDestroyedObserver peer_closed(peer);
  ASSERT_EQ(1, barc_window_close(peer_id));
  peer_closed.Wait();
  EXPECT_TRUE(view_deleted.deleted());
  EXPECT_EQ(0, barc_window_close(peer_id));
  EXPECT_EQ(first_view, BrowserView::GetBrowserViewForBrowser(browser()));
}

// Tests warning policy inputs using real isolated Browser/Profile/download
// objects. This does not establish shared native-window composition.
IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       GroupedOTRDownloadWarningCounting) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      &content::SlowDownloadHttpResponse::HandleSlowDownloadRequest));
  ASSERT_TRUE(embedded_test_server()->Start());
  auto* first = CreateIncognitoBrowser();
  auto* second = CreateIncognitoBrowser();
  ASSERT_EQ(first->GetProfile(), second->GetProfile());
  auto* manager = first->GetProfile()->GetDownloadManager();
  // Lazy OTR download UI initialization resets the prompting preference.
  auto* download_prefs = DownloadPrefs::FromDownloadManager(manager);
  first->GetProfile()->GetPrefs()->SetBoolean(prefs::kPromptForDownload, false);
  ASSERT_EQ(first->GetProfile(), manager->GetBrowserContext());
  ASSERT_FALSE(first->GetProfile()->GetPrefs()->GetBoolean(
      prefs::kPromptForDownload));
  ASSERT_FALSE(download_prefs->PromptForDownload());
  base::ScopedClosureRunner cleanup(
      base::BindLambdaForTesting([profile = first->GetProfile()->GetWeakPtr()] {
        if (!profile) {
          return;
        }
        content::DownloadManager::DownloadVector items;
        profile->GetDownloadManager()->GetAllDownloads(&items);
        for (const auto& item : items) {
          item->Cancel(/*user_cancel=*/true);
        }
      }));
  content::DownloadTestObserverInProgress progress(manager, 1);
  ui_test_utils::NavigateToURLWithDisposition(
      first,
      embedded_test_server()->GetURL(
          content::SlowDownloadHttpResponse::kKnownSizeUrl),
      WindowOpenDisposition::CURRENT_TAB, ui_test_utils::BROWSER_TEST_NO_WAIT);
  progress.WaitForFinished();
  ASSERT_EQ(1u, progress.NumDownloadsSeenInState(
                    download::DownloadItem::IN_PROGRESS));
  auto* controller = UnloadController::From(first);
  int count = -1;
  EXPECT_EQ(UnloadController::DownloadCloseType::kOk,
            controller->OkToCloseWithInProgressDownloads(&count));
  EXPECT_EQ(0, count);
  std::array<BrowserWindowInterface*, 2> group{first, second};
  EXPECT_EQ(UnloadController::DownloadCloseType::kLastWindowInIncognitoProfile,
            controller->OkToCloseWithInProgressDownloads(&count, group));
  EXPECT_EQ(1, count);
  auto* third = CreateIncognitoBrowser();
  ASSERT_EQ(first->GetProfile(), third->GetProfile());
  EXPECT_EQ(UnloadController::DownloadCloseType::kOk,
            controller->OkToCloseWithInProgressDownloads(&count, group));
  EXPECT_EQ(0, count);
  bool warned = false;
  EXPECT_EQ(UnloadController::WarnBeforeClosingResult::kOkToClose,
            UnloadController::From(browser())->MaybeWarnBeforeClosing(
                base::BindLambdaForTesting(
                    [&](UnloadController::WarnBeforeClosingResult) {
                      warned = true;
                    }),
                group));
  EXPECT_FALSE(warned);  // Regular macOS downloads continue after window close.
}

namespace {
constexpr char kSharedWork[] = "b482ffdf-5bb1-4f77-b176-12f17ae8f1af";
constexpr char kSharedPersonal[] = "c9c590de-4a1c-44ae-b110-ddf377cba483";
using SharedProfileResult =
    base::test::TestFuture<barc_profile_status, int32_t>;
void SharedProfileCompleted(barc_profile_status status,
                            int32_t window,
                            void* data) {
  static_cast<SharedProfileResult*>(data)->SetValue(status, window);
}
struct ReleasedProfileRequest {
  raw_ptr<SharedProfileResult> result;
  raw_ptr<std::unique_ptr<ReleasedProfileRequest>> owner;
  static void Completed(barc_profile_status status, int32_t window, void* data) {
    auto* request = static_cast<ReleasedProfileRequest*>(data);
    auto* owner = request->owner.get();
    request->result->SetValue(status, window);
    owner->reset();
  }
};
BrowserWindowInterface* SharedWindow(int32_t id) {
  return GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(id));
}

class RedirectNativeSelection : public TabStripModelObserver {
 public:
  RedirectNativeSelection(TabStripModel* strip, int32_t target)
      : target_(target) {
    strip->AddObserver(this);
  }
  void Arm() { armed_ = true; }
  void OnTabStripModelChanged(TabStripModel*,
                              const TabStripModelChange&,
                              const TabStripSelectionChange&) override {
    if (armed_) {
      armed_ = false;
      EXPECT_EQ(1, barc_window_select(target_));
    }
  }

 private:
  const int32_t target_;
  bool armed_ = false;
};
}  // namespace

class BarcSharedNativeWindowBrowserTest : public BarcBridgeBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    BarcBridgeBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-shared-native-window");
  }

 protected:
  int32_t Open(const char* uuid,
               int32_t owner = 0,
               barc_profile_destination destination = BARC_PROFILE_SETTINGS) {
    SharedProfileResult result;
    if (owner) {
      barc_profile_open_in_native_window(owner, uuid, destination,
                                         SharedProfileCompleted, &result);
    } else {
      barc_profile_open_window(uuid, destination, SharedProfileCompleted,
                               &result);
    }
    EXPECT_FALSE(result.IsReady());
    EXPECT_EQ(BARC_PROFILE_OK, result.Get<0>());
    return result.Get<1>();
  }
  void Navigate(BrowserWindowInterface* window, const GURL& url) {
    auto* contents = window->GetTabStripModel()->GetActiveWebContents();
    content::TestNavigationObserver navigated(contents);
    ASSERT_EQ(
        1, barc_tab_navigate(window->GetSessionID().id(),
                             barc_window_tab_at(window->GetSessionID().id(), 0),
                             url.spec().c_str()));
    navigated.Wait();
    ASSERT_TRUE(content::WaitForLoadStop(contents));
  }
};

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       UploadChooserFollowsLogicalOwnerWhilePhysicalInactive) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  Navigate(work, embedded_test_server()->GetURL("/file_input.html"));
  const int32_t work_tab = barc_window_tab_at(work_id, 0);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  const int32_t personal_tab = barc_window_tab_at(personal_id, 0);
  ASSERT_EQ(1, barc_tab_select(work_id, work_tab));
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  auto* tab = tabs::TabInterface::MaybeGetFromContents(contents);
  ASSERT_TRUE(tab);
  auto* factory = ui::FakeSelectFileDialog::RegisterFactory();
  base::ScopedClosureRunner reset_factory(base::BindOnce([] {
    ui::SelectFileDialog::SetFactory(nullptr);
  }));
  int opened = 0;
  factory->SetOpenCallback(base::BindLambdaForTesting([&] { ++opened; }));
  blink::mojom::FileChooserParams params;
  params.mode = blink::mojom::FileChooserParams::Mode::kOpen;

  // Deliberately use logical inactivity, independent of the locked console.
  // A native activation callback cannot cover this already-inactive owner.
  auto* active = BrowserActiveStateManager::From(work);
  active->DidBecomeInactive();
  int native_deselections = 0;
  auto deselected = work->RegisterNativeWindowSelectionChanged(
      base::BindLambdaForTesting([&] {
        if (!work->IsSelectedForNativeWindow()) {
          ++native_deselections;
        }
      }));
  auto pending = base::MakeRefCounted<UploadSelectionListener>();
  {
    base::ScopedThreadPoolExecutionFence delay_preparation;
    FileSelectHelper::RunFileChooser(contents->GetPrimaryMainFrame(), pending,
                                    params);
    EXPECT_EQ(0, opened);
    ASSERT_EQ(1, barc_tab_select(personal_id, personal_tab));
    EXPECT_TRUE(tab->IsActivated());
    EXPECT_EQ(1, pending->cancelled);
  }
  content::RunAllTasksUntilIdle();
  EXPECT_EQ(0, opened);
  EXPECT_EQ(1, pending->cancelled);
  EXPECT_EQ(1, native_deselections);

  // A fresh request from the now-inactive retained client is refused too.
  auto background = base::MakeRefCounted<UploadSelectionListener>();
  FileSelectHelper::RunFileChooser(contents->GetPrimaryMainFrame(), background,
                                  params);
  content::RunAllTasksUntilIdle();
  EXPECT_EQ(1, background->cancelled);
  EXPECT_EQ(0, opened);

  ASSERT_EQ(1, barc_tab_select(work_id, work_tab));
  active->DidBecomeInactive();
  auto shown = base::MakeRefCounted<UploadSelectionListener>();
  FileSelectHelper::RunFileChooser(contents->GetPrimaryMainFrame(), shown,
                                  params);
  ASSERT_TRUE(base::test::RunUntil([&] { return opened == 1; }));
  scoped_refptr<ui::FakeSelectFileDialog> dialog = factory->GetLastDialog();
  ASSERT_TRUE(dialog);
  ASSERT_TRUE(dialog->listener());
  ASSERT_EQ(1, barc_tab_select(personal_id, personal_tab));
  EXPECT_EQ(1, shown->cancelled);
  EXPECT_EQ(nullptr, dialog->listener());
  dialog->CallFileSelectionCanceled();
  EXPECT_EQ(1, shown->cancelled);
  EXPECT_EQ(0, shown->selected);
  EXPECT_EQ(2, native_deselections);

  // Destruction retains upstream RFH/WebContents cancellation authority.
  ASSERT_EQ(1, barc_tab_select(work_id, work_tab));
  auto closing = base::MakeRefCounted<UploadSelectionListener>();
  FileSelectHelper::RunFileChooser(contents->GetPrimaryMainFrame(), closing,
                                  params);
  ASSERT_TRUE(base::test::RunUntil([&] { return opened == 2; }));
  scoped_refptr<ui::FakeSelectFileDialog> closing_dialog = factory->GetLastDialog();
  ASSERT_TRUE(closing_dialog);
  deselected = {};
  ui_test_utils::BrowserDestroyedObserver closed(work);
  ASSERT_EQ(1, barc_window_close(work_id));
  closed.Wait();
  EXPECT_EQ(1, closing->cancelled);
  EXPECT_EQ(0, closing->selected);
  EXPECT_EQ(nullptr, closing_dialog->listener());
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       UploadChooserCancelsBeforeTransferOrDiscard) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t source_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* source = SharedWindow(source_id);
  ASSERT_TRUE(source);
  Navigate(source, embedded_test_server()->GetURL("/file_input.html"));
  const int32_t moving = barc_window_tab_at(source_id, 0);
  auto* moving_contents = source->GetTabStripModel()->GetActiveWebContents();
  const int32_t foreground = barc_tab_create(source_id, "about:blank", 1);
  ASSERT_GT(foreground, 0);
  ASSERT_EQ(1, barc_tab_select(source_id, foreground));
  const int32_t destination_id = barc_window_new_peer(source_id);
  auto* destination = SharedWindow(destination_id);
  ASSERT_TRUE(destination);
  ASSERT_EQ(source->GetProfile(), destination->GetProfile());
  auto* factory = ui::FakeSelectFileDialog::RegisterFactory();
  base::ScopedClosureRunner reset_factory(base::BindOnce([] {
    ui::SelectFileDialog::SetFactory(nullptr);
  }));
  int opened = 0;
  factory->SetOpenCallback(base::BindLambdaForTesting([&] { ++opened; }));
  blink::mojom::FileChooserParams params;
  params.mode = blink::mojom::FileChooserParams::Mode::kOpen;

  // A queued background request has no WillDeactivate notification on move.
  // Make it active at its destination before preparation resumes: it must still
  // cancel, rather than opening under a new native owner.
  ASSERT_EQ(1, barc_tab_select(source_id, foreground));
  EXPECT_FALSE(tabs::TabInterface::MaybeGetFromContents(moving_contents)->IsActivated());
  auto pending_move = base::MakeRefCounted<UploadSelectionListener>();
  {
    base::ScopedThreadPoolExecutionFence delay_preparation;
    FileSelectHelper::RunFileChooser(moving_contents->GetPrimaryMainFrame(),
                                    pending_move, params);
    ASSERT_EQ(1, barc_tab_transfer(source_id, moving, destination_id));
    ASSERT_EQ(1, barc_tab_select(destination_id, moving));
    EXPECT_EQ(moving_contents, destination->GetTabStripModel()->GetActiveWebContents());
    EXPECT_EQ(1, pending_move->cancelled);
  }
  content::RunAllTasksUntilIdle();
  EXPECT_EQ(0, opened);
  EXPECT_EQ(1, pending_move->cancelled);

  // The already-open dialog is cancelled before the real reverse transfer.
  auto shown_move = base::MakeRefCounted<UploadSelectionListener>();
  FileSelectHelper::RunFileChooser(moving_contents->GetPrimaryMainFrame(),
                                  shown_move, params);
  ASSERT_TRUE(base::test::RunUntil([&] { return opened == 1; }));
  scoped_refptr<ui::FakeSelectFileDialog> moved_dialog = factory->GetLastDialog();
  ASSERT_TRUE(moved_dialog);
  ASSERT_EQ(1, barc_tab_transfer(destination_id, moving, source_id));
  EXPECT_EQ(1, shown_move->cancelled);
  EXPECT_EQ(nullptr, moved_dialog->listener());
  ASSERT_EQ(1, barc_tab_select(source_id, moving));

  // Exercise the real TabStripModel/TabModel contents swap and deliberately
  // retain its old WebContents. Cancellation cannot rely on later destruction.
  auto pending_discard = base::MakeRefCounted<UploadSelectionListener>();
  std::unique_ptr<content::WebContents> old_contents;
  {
    base::ScopedThreadPoolExecutionFence delay_preparation;
    FileSelectHelper::RunFileChooser(moving_contents->GetPrimaryMainFrame(),
                                    pending_discard, params);
    auto replacement = content::WebContents::Create(
        content::WebContents::CreateParams(source->GetProfile()));
    old_contents = source->GetTabStripModel()->DiscardWebContents(
        moving_contents, std::move(replacement));
    EXPECT_EQ(moving_contents, old_contents.get());
    EXPECT_EQ(1, pending_discard->cancelled);
  }
  content::RunAllTasksUntilIdle();
  EXPECT_EQ(1, opened);
  EXPECT_EQ(1, pending_discard->cancelled);
  old_contents.reset();

  auto* current = source->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::NavigateToURL(
      current, embedded_test_server()->GetURL("/file_input.html")));
  auto shown_discard = base::MakeRefCounted<UploadSelectionListener>();
  FileSelectHelper::RunFileChooser(current->GetPrimaryMainFrame(), shown_discard,
                                  params);
  ASSERT_TRUE(base::test::RunUntil([&] { return opened == 2; }));
  scoped_refptr<ui::FakeSelectFileDialog> discarded_dialog = factory->GetLastDialog();
  ASSERT_TRUE(discarded_dialog);
  auto replacement = content::WebContents::Create(
      content::WebContents::CreateParams(source->GetProfile()));
  old_contents = source->GetTabStripModel()->DiscardWebContents(
      current, std::move(replacement));
  EXPECT_EQ(current, old_contents.get());
  EXPECT_EQ(1, shown_discard->cancelled);
  EXPECT_EQ(nullptr, discarded_dialog->listener());
  EXPECT_EQ(0, shown_discard->selected);
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       NativeDeselectionPreservesReentrantSelection) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  const int32_t third_id = Open(kSharedWork, work_id, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  auto* third = SharedWindow(third_id);
  ASSERT_TRUE(work);
  ASSERT_TRUE(personal);
  ASSERT_TRUE(third);
  const int32_t work_tab = barc_window_tab_at(work_id, 0);
  const int32_t personal_tab = barc_window_tab_at(personal_id, 0);
  const int32_t third_tab = barc_window_tab_at(third_id, 0);
  ASSERT_EQ(1, barc_tab_select(work_id, work_tab));
  int notifications = 0;
  auto deselected = work->RegisterNativeWindowSelectionChanged(
      base::BindLambdaForTesting([&] {
        if (work->IsSelectedForNativeWindow()) { return; }
        ++notifications;
        EXPECT_FALSE(work->IsSelectedForNativeWindow());
        EXPECT_TRUE(personal->IsSelectedForNativeWindow());
        EXPECT_EQ(1, barc_tab_select(third_id, third_tab));
      }));
  EXPECT_EQ(0, barc_tab_select(personal_id, personal_tab));
  EXPECT_EQ(1, notifications);
  EXPECT_TRUE(third->IsSelectedForNativeWindow());
  EXPECT_FALSE(personal->IsSelectedForNativeWindow());
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       PermissionRequestsWaitForActualLogicalOwner) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const auto url = embedded_test_server()->GetURL("/title1.html");
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  Navigate(work, url);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  const int32_t work_tab = barc_window_tab_at(work_id, 0);
  const int32_t personal_tab = barc_window_tab_at(personal_id, 0);
  ASSERT_EQ(1, barc_tab_select(personal_id, personal_tab));
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  auto* manager = permissions::PermissionRequestManager::FromWebContents(contents);
  ASSERT_TRUE(manager);
  permissions::MockPermissionPromptFactory prompts(manager);
  permissions::MockPermissionRequest::MockPermissionRequestState result;
  manager->AddRequest(contents->GetPrimaryMainFrame(),
      std::make_unique<permissions::MockPermissionRequest>(url,
          permissions::RequestType::kGeolocation, result.GetWeakPtr()));
  content::RunAllTasksUntilIdle();
  EXPECT_TRUE(tabs::TabInterface::MaybeGetFromContents(contents)->IsActivated());
  EXPECT_FALSE(prompts.is_visible());
  EXPECT_EQ(0, prompts.show_count());
  EXPECT_FALSE(result.finished);
  ASSERT_EQ(1, barc_tab_select(work_id, work_tab));
  ASSERT_TRUE(base::test::RunUntil([&] { return prompts.is_visible(); }));
  EXPECT_EQ(1, prompts.show_count());
  ASSERT_EQ(1, barc_tab_select(personal_id, personal_tab));
  EXPECT_FALSE(prompts.is_visible());
  EXPECT_FALSE(result.finished);
  EXPECT_FALSE(result.granted);
  ASSERT_EQ(1, barc_tab_select(work_id, work_tab));
  ASSERT_TRUE(base::test::RunUntil([&] { return prompts.is_visible(); }));
  EXPECT_EQ(2, prompts.show_count());

  // The prompt factory itself may reenter native selection. Its returned view
  // must not remain visible under Personal, nor create recursively on return.
  ASSERT_EQ(1, barc_tab_select(personal_id, personal_tab));
  bool supersede = true;
  manager->set_view_factory_for_testing(base::BindLambdaForTesting(
      [&](content::WebContents* page, permissions::PermissionPrompt::Delegate* delegate) {
        auto prompt = prompts.Create(page, delegate);
        if (supersede) {
          supersede = false;
          EXPECT_EQ(1, barc_tab_select(personal_id, personal_tab));
        }
        return prompt;
      }));
  EXPECT_EQ(0, barc_tab_select(work_id, work_tab));
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(prompts.is_visible());
  EXPECT_FALSE(result.finished);
  ASSERT_EQ(1, barc_tab_select(work_id, work_tab));
  EXPECT_TRUE(prompts.is_visible());
  EXPECT_FALSE(result.finished);
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       PrivatePermissionRequestEndsWithActualOwner) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t regular_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* regular = SharedWindow(regular_id);
  ASSERT_TRUE(regular);
  SharedProfileResult opened;
  barc_private_session_open_window(SharedProfileCompleted, &opened);
  ASSERT_EQ(BARC_PROFILE_OK, opened.Get<0>());
  const int32_t private_id = opened.Get<1>();
  auto* private_owner = SharedWindow(private_id);
  ASSERT_TRUE(private_owner);
  ASSERT_TRUE(private_owner->GetProfile()->IsOffTheRecord());
  ASSERT_NE(regular->GetProfile(), private_owner->GetProfile());
  const auto url = embedded_test_server()->GetURL("/title1.html");
  Navigate(private_owner, url);
  auto* contents = private_owner->GetTabStripModel()->GetActiveWebContents();
  auto* manager = permissions::PermissionRequestManager::FromWebContents(contents);
  ASSERT_TRUE(manager);
  permissions::MockPermissionPromptFactory prompts(manager);
  permissions::MockPermissionRequest::MockPermissionRequestState result;
  manager->AddRequest(contents->GetPrimaryMainFrame(),
      std::make_unique<permissions::MockPermissionRequest>(url,
          permissions::RequestType::kGeolocation, result.GetWeakPtr()));
  ASSERT_TRUE(base::test::RunUntil([&] { return prompts.is_visible(); }));
  ui_test_utils::BrowserDestroyedObserver closed(private_owner);
  ASSERT_EQ(1, barc_window_close(private_id));
  closed.Wait();
  EXPECT_FALSE(prompts.is_visible());
  EXPECT_TRUE(result.finished);
  EXPECT_FALSE(result.granted);
  EXPECT_EQ(regular, SharedWindow(regular_id));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       ThumbnailUsesVisibleExactDocumentAndBoundsOutput) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  const int32_t tab = barc_window_tab_at(work_id, 0);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  ASSERT_EQ(1, barc_tab_select(work_id, tab));
  work->GetWindow()->Show();
  content::WaitForCopyableViewInWebContents(work->GetTabStripModel()->GetActiveWebContents());
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  EXPECT_EQ(0, barc_tab_capture_thumbnail(0, 1, NavigationEvents::ReceiveThumbnail));
  ASSERT_EQ(1, barc_tab_capture_thumbnail(events.token, 1, NavigationEvents::ReceiveThumbnail));
  EXPECT_EQ(0, barc_tab_capture_thumbnail(events.token, 2, NavigationEvents::ReceiveThumbnail));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.thumbnail_calls == 1; }));
  EXPECT_EQ(1u, events.thumbnail_request);
  ASSERT_FALSE(events.thumbnail.empty());
  const SkBitmap image = gfx::PNGCodec::Decode(events.thumbnail);
  ASSERT_FALSE(image.drawsNothing());
  EXPECT_LE(image.width(), 400);
  EXPECT_LE(image.height(), 400);
  ASSERT_EQ(1, barc_tab_select(personal_id, barc_window_tab_at(personal_id, 0)));
  EXPECT_EQ(0, barc_tab_capture_thumbnail(events.token, 3, NavigationEvents::ReceiveThumbnail));
  EXPECT_FALSE(work->IsSelectedForNativeWindow());

  ASSERT_EQ(1, barc_tab_select(work_id, tab));
  ASSERT_EQ(1, barc_tab_capture_thumbnail(events.token, 4, NavigationEvents::ReceiveThumbnail));
  Navigate(work, embedded_test_server()->GetURL("/title2.html"));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.thumbnail_calls == 2; }));
  EXPECT_TRUE(events.thumbnail.empty());
  EXPECT_EQ(4u, events.thumbnail_request);
  const uint64_t stale = events.token;
  barc_tab_unobserve(stale);
  events.token = 0;
  EXPECT_EQ(0, barc_tab_capture_thumbnail(stale, 5, NavigationEvents::ReceiveThumbnail));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       ScreenshotCopiesHiddenRetainedViewportWithoutChangingOwner) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/shot-work" &&
            request.relative_url != "/shot-personal") return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK);
        response->set_content_type("text/html");
        response->set_content(request.relative_url == "/shot-work"
            ? "<!doctype html><style>html{background:rgb(180,40,60)}</style>"
            : "<!doctype html><style>html{background:rgb(30,70,190)}</style>");
        return response;
      }));
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  Navigate(work, embedded_test_server()->GetURL("/shot-work"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  const int32_t tab = barc_window_tab_at(work_id, 0);
  ASSERT_EQ(1, barc_tab_select(work_id, tab));
  work->GetWindow()->Show();
  content::WaitForCopyableViewInWebContents(page);
  const auto viewport = page->GetRenderWidgetHostView()->GetViewBounds().size();
  const double viewport_scale = page->GetRenderWidgetHostView()->GetDeviceScaleFactor();
  ASSERT_TRUE(content::ExecJs(page, R"(
    window.bootstraps=1;window.unsaved='draft';window.animationFrames=0;
    function animation(){animationFrames++;requestAnimationFrame(animation)}requestAnimationFrame(animation);
    document.addEventListener('visibilitychange',()=>{
      if(document.hidden){window.hiddenCount=animationFrames;domAutomationController.send('shot-hidden')}
    });
    document.addEventListener('freeze',()=>{window.frozenCount=animationFrames;domAutomationController.send('shot-frozen')});
    document.addEventListener('resume',()=>domAutomationController.send('shot-resumed:'+(animationFrames===frozenCount)));
  )"));
  content::DOMMessageQueue lifecycle(page);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  Navigate(personal, embedded_test_server()->GetURL("/shot-personal"));
  ASSERT_EQ(1, barc_tab_select(personal_id, barc_window_tab_at(personal_id, 0)));
  content::WaitForCopyableViewInWebContents(
      personal->GetTabStripModel()->GetActiveWebContents());
  ASSERT_EQ(content::Visibility::HIDDEN, page->GetVisibility());
  std::string message;
  ASSERT_TRUE(lifecycle.WaitForMessage(&message));
  ASSERT_EQ("\"shot-hidden\"", message);
  // The first copy is from an ordinary hidden, unfrozen document. Freezing it
  // here would hide a capture path that accidentally restarts hidden painting.
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  EXPECT_EQ(0, barc_tab_capture_screenshot(events.token, 1, 0, NavigationEvents::ReceiveThumbnail));
  EXPECT_EQ(0, barc_tab_capture_screenshot(events.token, 1, 4097, NavigationEvents::ReceiveThumbnail));
  EXPECT_EQ(0, barc_tab_capture_screenshot(0, 1, 1200, NavigationEvents::ReceiveThumbnail));
  personal->GetProfile()->GetPrefs()->SetBoolean(prefs::kDisableScreenshots, true);
  ASSERT_EQ(1, barc_tab_capture_screenshot(events.token, 2, 1200, NavigationEvents::ReceiveThumbnail));
  EXPECT_FALSE(page->IsBeingCaptured());
  EXPECT_EQ(content::Visibility::HIDDEN, page->GetVisibility());
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
  EXPECT_EQ(0, barc_tab_capture_screenshot(events.token, 3, 1200, NavigationEvents::ReceiveThumbnail));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.thumbnail_calls == 1; }));
  ASSERT_FALSE(events.thumbnail.empty());
  const auto image = gfx::JPEGCodec::Decode(events.thumbnail);
  ASSERT_FALSE(image.drawsNothing());
  EXPECT_LE(image.width(), 1200);
  EXPECT_GE(image.width(), std::min(1200.0, viewport.width() * viewport_scale) - 1);
  EXPECT_LE(image.height(), 4096);
  EXPECT_LE(image.width() * image.height(), 8 * 1024 * 1024);
  EXPECT_NEAR(static_cast<double>(image.width()) / image.height(),
              static_cast<double>(viewport.width()) / viewport.height(), 0.01);
  const auto center = image.getColor(image.width() / 2, image.height() / 2);
  EXPECT_NEAR(SkColorGetR(center), 180, 8);
  EXPECT_NEAR(SkColorGetG(center), 40, 8);
  EXPECT_NEAR(SkColorGetB(center), 60, 8); // Work page, never the blue selected profile.
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
  EXPECT_EQ(content::Visibility::HIDDEN, page->GetVisibility());
  EXPECT_FALSE(page->IsBeingCaptured());
  EXPECT_EQ(true, content::EvalJs(page, "animationFrames===hiddenCount"));
  // Also preserve an already-frozen document; this is additional coverage,
  // rather than the precondition that makes the ordinary-hidden test pass.
  page->SetPageFrozen(true);
  ASSERT_TRUE(lifecycle.WaitForMessage(&message));
  ASSERT_EQ("\"shot-frozen\"", message);
  ASSERT_EQ(1, barc_tab_capture_screenshot(events.token, 20, 1200, NavigationEvents::ReceiveThumbnail));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.thumbnail_calls == 2; }));
  ASSERT_FALSE(events.thumbnail.empty());
  EXPECT_FALSE(gfx::JPEGCodec::Decode(events.thumbnail).drawsNothing());
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_EQ(content::Visibility::HIDDEN, page->GetVisibility());
  EXPECT_FALSE(page->IsBeingCaptured());
  page->SetPageFrozen(false);
  ASSERT_TRUE(lifecycle.WaitForMessage(&message));
  EXPECT_EQ("\"shot-resumed:true\"", message);
  EXPECT_EQ("draft:1", content::EvalJs(page, "unsaved+':'+bootstraps"));
  // Policy is checked again after copying/encoding, not only at admission.
  ASSERT_EQ(1, barc_tab_capture_screenshot(events.token, 4, 1200, NavigationEvents::ReceiveThumbnail));
  work->GetProfile()->GetPrefs()->SetBoolean(prefs::kDisableScreenshots, true);
  ASSERT_TRUE(base::test::RunUntil([&] { return events.thumbnail_calls == 3; }));
  EXPECT_TRUE(events.thumbnail.empty());
  EXPECT_EQ(0, barc_tab_capture_screenshot(events.token, 5, 1200, NavigationEvents::ReceiveThumbnail));
  work->GetProfile()->GetPrefs()->SetBoolean(prefs::kDisableScreenshots, false);
  ASSERT_EQ(1, barc_tab_capture_screenshot(events.token, 6, 1200, NavigationEvents::ReceiveThumbnail));
  EXPECT_EQ(0, barc_tab_cancel_capture(events.token, 5));
  EXPECT_EQ(1, barc_tab_cancel_capture(events.token, 6));
  EXPECT_EQ(0, barc_tab_capture_screenshot(events.token, 7, 1200, NavigationEvents::ReceiveThumbnail));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return barc_tab_capture_screenshot(events.token, 7, 1200, NavigationEvents::ReceiveThumbnail) == 1;
  }));
  Navigate(work, embedded_test_server()->GetURL("/title2.html"));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.thumbnail_calls == 4; }));
  EXPECT_EQ(7u, events.thumbnail_request);
  EXPECT_TRUE(events.thumbnail.empty());
  const auto stale = events.token;
  barc_tab_unobserve(stale);events.token=0;
  EXPECT_EQ(0, barc_tab_capture_screenshot(stale, 8, 1200, NavigationEvents::ReceiveThumbnail));
}

class BarcFileDownloadBrowserTest : public BarcSharedNativeWindowBrowserTest {
 public:
  void SetUpOnMainThread() override {
    BarcSharedNativeWindowBrowserTest::SetUpOnMainThread();
    host_resolver()->AddRule("*","127.0.0.1");
    https_.SetSSLConfig(net::EmbeddedTestServer::CERT_TEST_NAMES);
    https_.ServeFilesFromSourceDirectory("chrome/test/data");
  }
 protected:
  net::EmbeddedTestServer https_{net::EmbeddedTestServer::TYPE_HTTPS};
};

IN_PROC_BROWSER_TEST_F(BarcFileDownloadBrowserTest, DocumentFileDownloadsKeepProfileCookiesAndRedirectAuthority) {
  base::ScopedAllowBlockingForTesting allow_blocking;
  https_.RegisterRequestHandler(base::BindRepeating(
      [](net::EmbeddedTestServer* server,const net::test_server::HttpRequest& request)
          ->std::unique_ptr<net::test_server::HttpResponse> {
        auto response=std::make_unique<net::test_server::BasicHttpResponse>();
        if (request.relative_url=="/redirect") {
          response->set_code(net::HTTP_FOUND);response->AddCustomHeader("Location",server->GetURL("b.test","/file.bin").spec());return response;
        }
        if (request.relative_url!="/file.bin") return nullptr;
        auto cookie=request.headers.find("Cookie"),referrer=request.headers.find("Referer");
        response->set_content((cookie==request.headers.end()?"":cookie->second)+"\n"+
            (referrer==request.headers.end()?"":referrer->second));
        response->set_content_type("application/octet-stream");
        response->AddCustomHeader("Set-Cookie","must-not-save=yes; Secure; SameSite=Lax");
        return response;
      },base::Unretained(&https_)));
  ASSERT_TRUE(https_.Start());
  const auto source=https_.GetURL("a.test","/title1.html?private-query=synthetic");
  const auto url=https_.GetURL("a.test","/file.bin");
  const int32_t work_id=Open(kSharedWork,0,BARC_PROFILE_BLANK);
  auto* work=SharedWindow(work_id);
  const int32_t personal_id=Open(kSharedPersonal,work_id,BARC_PROFILE_BLANK);
  auto* personal=SharedWindow(personal_id);
  Navigate(work,source);Navigate(personal,source);
  ASSERT_TRUE(content::SetCookie(work->GetProfile(),url,"auth=Work; Secure; SameSite=Strict"));
  ASSERT_TRUE(content::SetCookie(personal->GetProfile(),url,"auth=Personal; Secure; SameSite=Strict"));
  NavigationEvents a,b;
  a.token=barc_tab_observe(work_id,barc_window_tab_at(work_id,0),NavigationEvents::Receive,&a);
  b.token=barc_tab_observe(personal_id,barc_window_tab_at(personal_id,0),NavigationEvents::Receive,&b);
  ASSERT_NE(0u,a.token);ASSERT_NE(0u,b.token);
  base::ScopedTempDir temporary;ASSERT_TRUE(temporary.CreateUniqueTempDir());
  base::FilePath directory;ASSERT_TRUE(base::NormalizeFilePath(temporary.GetPath(),&directory));
  ASSERT_EQ(1,barc_tab_download_file(a.token,1,url.spec().c_str(),directory.value().c_str(),NavigationEvents::ReceiveFile));
  ASSERT_EQ(1,barc_tab_download_file(b.token,1,url.spec().c_str(),directory.value().c_str(),NavigationEvents::ReceiveFile));
  ASSERT_TRUE(base::test::RunUntil([&]{return a.files.size()==1 && b.files.size()==1;}));
  ASSERT_EQ(BARC_FILE_OK,a.files[0].result);ASSERT_EQ(BARC_FILE_OK,b.files[0].result);
  ASSERT_NE(a.files[0].path,b.files[0].path);
  std::string work_bytes,personal_bytes;
  ASSERT_TRUE(base::ReadFileToString(base::FilePath(a.files[0].path),&work_bytes));
  ASSERT_TRUE(base::ReadFileToString(base::FilePath(b.files[0].path),&personal_bytes));
  EXPECT_NE(std::string::npos,work_bytes.find("auth=Work"));
  EXPECT_EQ(std::string::npos,work_bytes.find("Personal"));
  EXPECT_NE(std::string::npos,personal_bytes.find("auth=Personal"));
  EXPECT_EQ(std::string::npos,content::GetCookies(work->GetProfile(),url).find("must-not-save"));
  const auto redirect=https_.GetURL("a.test","/redirect");
  ASSERT_EQ(1,barc_tab_download_file(a.token,2,redirect.spec().c_str(),directory.value().c_str(),NavigationEvents::ReceiveFile));
  ASSERT_TRUE(base::test::RunUntil([&]{return a.files.size()==2;}));
  ASSERT_EQ(BARC_FILE_OK,a.files.back().result);
  std::string redirected;ASSERT_TRUE(base::ReadFileToString(base::FilePath(a.files.back().path),&redirected));
  EXPECT_EQ(std::string::npos,redirected.find("auth=Work"));
  EXPECT_EQ(std::string::npos,redirected.find("private-query"));
  EXPECT_NE(std::string::npos,redirected.find(https_.GetURL("a.test","/").spec()));
  EXPECT_EQ(0,barc_tab_download_file(a.token,3,"http://a.test/file",directory.value().c_str(),NavigationEvents::ReceiveFile));
}

IN_PROC_BROWSER_TEST_F(BarcFileDownloadBrowserTest, StreamCancellationAndDocumentReplacementDeleteOnlyOwnedTemporary) {
  base::ScopedAllowBlockingForTesting allow_blocking;
  net::test_server::ControllableHttpResponse body(&https_,"/stream.bin");
  ASSERT_TRUE(https_.Start());
  const int32_t work_id=Open(kSharedWork,0,BARC_PROFILE_BLANK);
  auto* work=SharedWindow(work_id);Navigate(work,https_.GetURL("a.test","/title1.html"));
  NavigationEvents events;events.token=barc_tab_observe(work_id,barc_window_tab_at(work_id,0),NavigationEvents::Receive,&events);
  ASSERT_NE(0u,events.token);
  base::ScopedTempDir temporary;ASSERT_TRUE(temporary.CreateUniqueTempDir());
  base::FilePath root;ASSERT_TRUE(base::NormalizeFilePath(temporary.GetPath(),&root));
  const auto directory=root.AppendASCII("owned");ASSERT_TRUE(base::CreateDirectory(directory));
  const auto url=https_.GetURL("a.test","/stream.bin");
  ASSERT_EQ(1,barc_tab_download_file(events.token,1,url.spec().c_str(),directory.value().c_str(),NavigationEvents::ReceiveFile));
  body.WaitForRequest();body.Send("HTTP/1.1 200 OK\r\nContent-Length: 104857600\r\n\r\n");body.Send(std::string(65536,'x'));
  base::FileEnumerator owned(directory,false,base::FileEnumerator::FILES);
  const auto original=owned.Next();ASSERT_FALSE(original.empty());
  const auto moved=root.AppendASCII("moved");ASSERT_TRUE(base::Move(directory,moved));
  ASSERT_TRUE(base::CreateDirectory(directory));
  const auto rival=directory.Append(original.BaseName());ASSERT_TRUE(base::WriteFile(rival,"replacement"));
  EXPECT_EQ(1,barc_tab_cancel_file(events.token,1));
  ASSERT_EQ(1u,events.files.size());EXPECT_EQ(BARC_FILE_CANCELLED,events.files[0].result);
  EXPECT_TRUE(events.files[0].path.empty());body.Done();
  ASSERT_TRUE(base::test::RunUntil([&]{base::FileEnumerator files(moved,false,base::FileEnumerator::FILES);return files.Next().empty();}));
  std::string preserved;ASSERT_TRUE(base::ReadFileToString(rival,&preserved));EXPECT_EQ("replacement",preserved);
  // Directory preparation is asynchronous; replacing the document before its
  // reply must not start a stale request or publish a completed temporary.
  ASSERT_EQ(1,barc_tab_download_file(events.token,2,url.spec().c_str(),directory.value().c_str(),NavigationEvents::ReceiveFile));
  Navigate(work,https_.GetURL("a.test","/title2.html"));
  ASSERT_TRUE(base::test::RunUntil([&]{return events.files.size()==2;}));
  EXPECT_EQ(BARC_FILE_CANCELLED,events.files.back().result);
  const auto stale=events.token;barc_tab_unobserve(stale);events.token=0;
  EXPECT_EQ(0,barc_tab_download_file(stale,3,url.spec().c_str(),directory.value().c_str(),NavigationEvents::ReceiveFile));
}

namespace {
// One reusable 64KiB block and one send callback at a time; the functional
// response crosses the native 100MiB boundary without a giant test buffer.
class OversizedFileResponse final : public net::test_server::HttpResponse {
 public:
  void SendResponse(base::WeakPtr<net::test_server::HttpResponseDelegate> delegate) override {
    delegate->SendResponseHeaders(net::HTTP_OK,"OK",{{"Content-Length","104857601"}});
    Next(delegate);
  }
 private:
  void Next(base::WeakPtr<net::test_server::HttpResponseDelegate> delegate) {
    if (!delegate) return;
    if (!remaining_) {delegate->FinishResponse();return;}
    const size_t count=std::min(remaining_,chunk_.size());remaining_-=count;
    delegate->SendContents(std::string_view(chunk_).substr(0,count),
        base::BindOnce(&OversizedFileResponse::Next,weak_.GetWeakPtr(),delegate));
  }
  const std::string chunk_=std::string(65536,'x');
  size_t remaining_=104857601;
  base::WeakPtrFactory<OversizedFileResponse> weak_{this};
};
}
IN_PROC_BROWSER_TEST_F(BarcFileDownloadBrowserTest, NativeFileLimitStopsStreamingAndRemovesPartialFile) {
  base::ScopedAllowBlockingForTesting allow_blocking;
  https_.RegisterRequestHandler(base::BindRepeating([](const net::test_server::HttpRequest& request)
      ->std::unique_ptr<net::test_server::HttpResponse> {
    if (request.relative_url=="/large.bin") return std::make_unique<OversizedFileResponse>();
    return nullptr;
  }));
  ASSERT_TRUE(https_.Start());
  const int32_t id=Open(kSharedWork,0,BARC_PROFILE_BLANK);auto* work=SharedWindow(id);
  Navigate(work,https_.GetURL("a.test","/title1.html"));
  NavigationEvents events;events.token=barc_tab_observe(id,barc_window_tab_at(id,0),NavigationEvents::Receive,&events);
  ASSERT_NE(0u,events.token);
  base::ScopedTempDir temporary;ASSERT_TRUE(temporary.CreateUniqueTempDir());
  base::FilePath directory;ASSERT_TRUE(base::NormalizeFilePath(temporary.GetPath(),&directory));
  const auto url=https_.GetURL("a.test","/large.bin");
  ASSERT_EQ(1,barc_tab_download_file(events.token,1,url.spec().c_str(),directory.value().c_str(),NavigationEvents::ReceiveFile));
  ASSERT_TRUE(base::test::RunUntil([&]{return events.files.size()==1;}));
  EXPECT_EQ(BARC_FILE_TOO_LARGE,events.files[0].result);EXPECT_TRUE(events.files[0].path.empty());
  ASSERT_TRUE(base::test::RunUntil([&]{base::FileEnumerator files(directory,false,base::FileEnumerator::FILES);return files.Next().empty();}));
}
IN_PROC_BROWSER_TEST_F(BarcFileDownloadBrowserTest, ExplicitProfileDeletionCancelsFileBeforeCleanupAndLeavesSurvivor) {
  base::ScopedAllowBlockingForTesting allow_blocking;
  net::test_server::ControllableHttpResponse body(&https_,"/held.bin");ASSERT_TRUE(https_.Start());
  const int32_t work_id=Open(kSharedWork,0,BARC_PROFILE_BLANK);auto* work=SharedWindow(work_id);
  const int32_t personal_id=Open(kSharedPersonal,work_id,BARC_PROFILE_BLANK);auto* personal=SharedWindow(personal_id);
  Navigate(work,https_.GetURL("a.test","/title1.html"));
  NavigationEvents events;events.token=barc_tab_observe(work_id,barc_window_tab_at(work_id,0),NavigationEvents::Receive,&events);
  ASSERT_NE(0u,events.token);
  base::ScopedTempDir temporary;ASSERT_TRUE(temporary.CreateUniqueTempDir());
  base::FilePath directory;ASSERT_TRUE(base::NormalizeFilePath(temporary.GetPath(),&directory));
  const auto url=https_.GetURL("a.test","/held.bin");
  ASSERT_EQ(1,barc_tab_download_file(events.token,1,url.spec().c_str(),directory.value().c_str(),NavigationEvents::ReceiveFile));
  body.WaitForRequest();
  base::test::TestFuture<barc_profile_delete_result> deletion;
  barc_profile_delete_kept(kSharedWork,kSharedPersonal,0,[](barc_profile_delete_result result,void* data){
    static_cast<base::test::TestFuture<barc_profile_delete_result>*>(data)->SetValue(result);
  },&deletion);
  EXPECT_EQ(BARC_PROFILE_DELETED,deletion.Get());
  EXPECT_TRUE(events.Count(BARC_TAB_CLOSED) || (!events.files.empty() && events.files[0].result==BARC_FILE_CANCELLED));
  EXPECT_EQ(personal,SharedWindow(personal_id));
  body.Done();
  ASSERT_TRUE(base::test::RunUntil([&]{base::FileEnumerator files(directory,false,base::FileEnumerator::FILES);return files.Next().empty();}));
}

class BarcSiteDataBrowserTest : public BarcSharedNativeWindowBrowserTest {
 public:
  void SetUpOnMainThread() override {
    BarcSharedNativeWindowBrowserTest::SetUpOnMainThread();
    // BrowserTestBase freezes resolver rules before entering the test body.
    host_resolver()->AddRule("*", "127.0.0.1");
  }
};

IN_PROC_BROWSER_TEST_F(BarcSiteDataBrowserTest,
                       SiteCookiesPreserveDomainsPartitionsAndOtherProfiles) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const auto page_url = embedded_test_server()->GetURL("sub.a.test", "/title1.html");
  const GURL cookie_url("https://sub.a.test/");
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  Navigate(work, page_url);
  const int32_t tab = barc_window_tab_at(work_id, 0);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  SharedProfileResult private_result;
  barc_private_session_open_window(SharedProfileCompleted, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  auto* private_owner = SharedWindow(private_result.Get<1>());
  ASSERT_TRUE(private_owner);
  ASSERT_TRUE(private_owner->GetProfile()->IsOffTheRecord());
  ASSERT_TRUE(content::SetCookie(work->GetProfile(), cookie_url, "host=1; Path=/"));
  ASSERT_TRUE(content::SetCookie(work->GetProfile(), cookie_url, "domain=1; Domain=sub.a.test; Path=/"));
  ASSERT_TRUE(content::SetCookie(work->GetProfile(), cookie_url, "parent=1; Domain=a.test; Path=/"));
  ASSERT_TRUE(content::SetCookie(work->GetProfile(), GURL("https://sibling.a.test/"), "sibling=1; Path=/"));
  const auto current_key = net::CookiePartitionKey::FromURLForTesting(page_url);
  const auto other_key = net::CookiePartitionKey::FromURLForTesting(GURL("https://b.test"));
  const auto inclusive = net::CookieOptions::SameSiteCookieContext::MakeInclusive();
  ASSERT_TRUE(content::SetCookie(work->GetProfile(), cookie_url,
      "chip=1; Secure; SameSite=None; Partitioned; Path=/", inclusive, current_key));
  ASSERT_TRUE(content::SetCookie(work->GetProfile(), cookie_url,
      "otherchip=1; Secure; SameSite=None; Partitioned; Path=/", inclusive, other_key));
  ASSERT_TRUE(content::SetCookie(personal->GetProfile(), cookie_url, "personal=1; Path=/"));
  ASSERT_TRUE(content::SetCookie(private_owner->GetProfile(), cookie_url, "private=1; Path=/"));
  ASSERT_EQ(1, barc_tab_select(work_id, tab));
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  EXPECT_EQ(0, barc_tab_clear_site_data(events.token, 1, -1, NavigationEvents::SiteDataResult));
  ASSERT_EQ(1, barc_tab_clear_site_data(events.token, 1, BARC_SITE_COOKIES, NavigationEvents::SiteDataResult));
  EXPECT_EQ(0, barc_tab_clear_site_data(events.token, 2, BARC_SITE_CACHE, NavigationEvents::SiteDataResult));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.site_results.size() == 1; }));
  EXPECT_EQ(BARC_SITE_COMPLETED, events.site_results.back());
  const std::string remaining = content::GetCookies(work->GetProfile(), cookie_url);
  EXPECT_FALSE(remaining.contains("host=1"));
  EXPECT_FALSE(remaining.contains("domain=1"));
  EXPECT_FALSE(remaining.starts_with("chip=1"));
  EXPECT_FALSE(remaining.contains("; chip=1"));
  EXPECT_TRUE(remaining.contains("parent=1"));
  EXPECT_TRUE(remaining.contains("otherchip=1"));
  EXPECT_TRUE(content::GetCookies(work->GetProfile(), GURL("https://sibling.a.test/")).contains("sibling=1"));
  EXPECT_TRUE(content::GetCookies(personal->GetProfile(), cookie_url).contains("personal=1"));
  EXPECT_TRUE(content::GetCookies(private_owner->GetProfile(), cookie_url).contains("private=1"));
  Navigate(private_owner, page_url);
  const int32_t private_id = private_result.Get<1>();
  const int32_t private_tab = barc_window_tab_at(private_id, 0);
  ASSERT_EQ(1, barc_tab_select(private_id, private_tab));
  NavigationEvents private_events;
  private_events.token = barc_tab_observe(private_id, private_tab, NavigationEvents::Receive, &private_events);
  ASSERT_NE(0u, private_events.token);
  ASSERT_EQ(1, barc_tab_clear_site_data(private_events.token, 1, BARC_SITE_COOKIES, NavigationEvents::SiteDataResult));
  ASSERT_TRUE(base::test::RunUntil([&] { return private_events.site_results.size() == 1; }));
  EXPECT_EQ(BARC_SITE_COMPLETED, private_events.site_results.back());
  EXPECT_FALSE(content::GetCookies(private_owner->GetProfile(), cookie_url).contains("private=1"));
  EXPECT_TRUE(content::GetCookies(personal->GetProfile(), cookie_url).contains("personal=1"));
  EXPECT_TRUE(content::GetCookies(work->GetProfile(), cookie_url).contains("parent=1"));
  ASSERT_EQ(1, barc_tab_select(work_id, tab));
  ASSERT_TRUE(content::SetCookie(work->GetProfile(), cookie_url, "reload=1; Path=/"));
  content::TestNavigationObserver cookie_reload(work->GetTabStripModel()->GetActiveWebContents());
  ASSERT_EQ(1, barc_tab_clear_site_data(events.token, 2, BARC_SITE_COOKIES_AND_RELOAD, NavigationEvents::SiteDataResult));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.site_results.size() == 2; }));
  EXPECT_EQ(BARC_SITE_COMPLETED, events.site_results.back());
  cookie_reload.Wait();
  EXPECT_FALSE(content::GetCookies(work->GetProfile(), cookie_url).contains("reload=1"));

  // A real navigation before cookie enumeration completes must not reload its
  // replacement or even begin the deferred canonical-cookie deletions.
  ASSERT_TRUE(content::SetCookie(work->GetProfile(), cookie_url, "late=1; Path=/"));
  ASSERT_EQ(1, barc_tab_clear_site_data(events.token, 3, BARC_SITE_COOKIES_AND_RELOAD, NavigationEvents::SiteDataResult));
  Navigate(work, embedded_test_server()->GetURL("sub.a.test", "/title2.html"));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.site_results.size() == 3; }));
  EXPECT_EQ(BARC_SITE_CANCELLED, events.site_results.back());
  EXPECT_TRUE(content::GetCookies(work->GetProfile(), cookie_url).contains("late=1"));
  const int32_t peer_id = barc_window_new_peer(work_id);
  auto* peer = SharedWindow(peer_id);
  ASSERT_TRUE(peer);
  ASSERT_EQ(1, barc_tab_select(work_id, tab));
  ASSERT_EQ(1, barc_tab_clear_site_data(events.token, 4, BARC_SITE_COOKIES_AND_RELOAD, NavigationEvents::SiteDataResult));
  ASSERT_EQ(1, barc_tab_transfer(work_id, tab, peer_id));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.site_results.size() == 4; }));
  EXPECT_EQ(BARC_SITE_CANCELLED, events.site_results.back());
  EXPECT_TRUE(content::GetCookies(peer->GetProfile(), cookie_url).contains("late=1"));
  ASSERT_EQ(1, barc_tab_select(peer_id, tab));
  ASSERT_EQ(1, barc_tab_clear_site_data(events.token, 5, BARC_SITE_COOKIES_AND_RELOAD, NavigationEvents::SiteDataResult));
  ui_test_utils::BrowserDestroyedObserver closed(peer);
  ASSERT_EQ(1, barc_window_close(peer_id));
  closed.Wait();
  content::RunAllTasksUntilIdle();
  EXPECT_EQ(4u, events.site_results.size());
}

IN_PROC_BROWSER_TEST_F(BarcSiteDataBrowserTest,
                       SiteCacheIsOriginFilteredAndHardReloadPreservesStorage) {
  net::EmbeddedTestServer https_server(net::EmbeddedTestServer::TYPE_HTTPS);
  https_server.SetSSLConfig(net::EmbeddedTestServer::CERT_TEST_NAMES);
  https_server.ServeFilesFromSourceDirectory("chrome/test/data");
  auto counts = std::make_shared<std::array<std::atomic<int>, 2>>();
  https_server.RegisterRequestHandler(base::BindRepeating(
      [](std::shared_ptr<std::array<std::atomic<int>, 2>> counts,
         const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/cache-probe") return nullptr;
        const bool target = request.headers.at("Host").starts_with("a.test");
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK);
        response->AddCustomHeader("Cache-Control", "max-age=3600");
        response->set_content(std::string(target ? "A" : "B") +
            std::to_string(++(*counts)[target ? 0 : 1]));
        return response;
      }, counts));
  ASSERT_TRUE(https_server.Start());
  const int32_t window_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* window = SharedWindow(window_id);
  ASSERT_TRUE(window);
  Navigate(window, https_server.GetURL("a.test", "/title1.html"));
  const int32_t tab = barc_window_tab_at(window_id, 0);
  auto* contents = window->GetTabStripModel()->GetActiveWebContents();
  const auto other_url = https_server.GetURL("b.test", "/title1.html");
  const int32_t other = barc_tab_create(window_id, other_url.spec().c_str(), 0);
  ASSERT_GT(other, 0);
  auto* other_contents = window->GetTabStripModel()->GetWebContentsAt(1);
  ASSERT_TRUE(content::WaitForLoadStop(other_contents));
  ASSERT_TRUE(content::ExecJs(other_contents, "localStorage.keep='other'"));
  // Probe the actual HTTP cache via this Profile's browser factory, avoiding
  // renderer memory-cache hits which scoped removal deliberately does not flush.
  auto read_http_cache = [&](const GURL& url) {
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = url;
    request->credentials_mode = network::mojom::CredentialsMode::kOmit;
    request->trusted_params = network::ResourceRequest::TrustedParams();
    request->trusted_params->isolation_info = net::IsolationInfo::Create(
        net::IsolationInfo::RequestType::kOther, url::Origin::Create(url),
        url::Origin::Create(url), net::SiteForCookies::FromUrl(url));
    auto loader = network::SimpleURLLoader::Create(std::move(request), TRAFFIC_ANNOTATION_FOR_TESTS);
    auto factory = contents->GetPrimaryMainFrame()->GetStoragePartition()
                       ->GetURLLoaderFactoryForBrowserProcess();
    base::test::TestFuture<std::optional<std::string>> result;
    loader->DownloadToString(factory.get(), result.GetCallback(), 1024);
    const auto& body = result.Get();
    EXPECT_TRUE(body.has_value());
    return body.value_or("");
  };
  const auto target_cache = https_server.GetURL("a.test", "/cache-probe");
  const auto other_cache = https_server.GetURL("b.test", "/cache-probe");
  EXPECT_EQ("A1", read_http_cache(target_cache));
  EXPECT_EQ("B1", read_http_cache(other_cache));
  EXPECT_EQ("A1", read_http_cache(target_cache));
  ASSERT_TRUE(content::ExecJs(contents,
      "localStorage.keep='yes'; document.cookie='keep=yes'; caches.open('keep').then(c=>c.put('/keep',new Response('yes')));"));
  NavigationEvents events;
  events.token = barc_tab_observe(window_id, tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  ASSERT_EQ(1, barc_tab_clear_site_data(events.token, 1, BARC_SITE_CACHE, NavigationEvents::SiteDataResult));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.site_results.size() == 1; }));
  EXPECT_EQ(BARC_SITE_COMPLETED, events.site_results.back());
  EXPECT_EQ("A2", read_http_cache(target_cache));
  EXPECT_EQ("B1", read_http_cache(other_cache));
  EXPECT_EQ("yes", content::EvalJs(contents, "localStorage.keep"));
  EXPECT_EQ("other", content::EvalJs(other_contents, "localStorage.keep"));
  EXPECT_TRUE(content::EvalJs(contents, "document.cookie.includes('keep=yes')").ExtractBool());
  EXPECT_EQ("yes", content::EvalJs(contents, "caches.open('keep').then(c=>c.match('/keep')).then(r=>r.text())"));
  EXPECT_EQ(0, barc_tab_execute_command(window_id, other, BARC_PAGE_HARD_RELOAD));
  chrome::BrowserCommandController::From(window)->UpdateCommandEnabled(IDC_RELOAD_BYPASSING_CACHE, false);
  EXPECT_EQ(0, barc_tab_execute_command(window_id, tab, BARC_PAGE_HARD_RELOAD));
  chrome::BrowserCommandController::From(window)->UpdateCommandEnabled(IDC_RELOAD_BYPASSING_CACHE, true);
  content::TestNavigationObserver reloaded(contents);
  ASSERT_EQ(1, barc_tab_execute_command(window_id, tab, BARC_PAGE_HARD_RELOAD));
  reloaded.Wait();
  EXPECT_EQ("yes", content::EvalJs(contents, "localStorage.keep"));
  EXPECT_TRUE(content::EvalJs(contents, "document.cookie.includes('keep=yes')").ExtractBool());
}

// Use the same fake backend and sandboxed test service as Chromium's
// PrintPreviewBrowserTest. No real printer, destination file or OS panel.
class BarcPdfPrintBrowserTest : public BarcSharedNativeWindowBrowserTest {
 public:
  void SetUp() override {
    backend_ = base::MakeRefCounted<printing::TestPrintBackend>();
    printing::PrintBackend::SetPrintBackendForTesting(backend_.get());
    BarcSharedNativeWindowBrowserTest::SetUp();
  }
  void SetUpOnMainThread() override {
    BarcSharedNativeWindowBrowserTest::SetUpOnMainThread();
#if BUILDFLAG(ENABLE_OOP_PRINTING)
    if (printing::IsOopPrintingEnabled()) {
      service_ = printing::PrintBackendServiceTestImpl::LaunchForTesting(
          remote_, backend_, /*sandboxed=*/true);
    }
#endif
  }
  void TearDown() override {
    BarcSharedNativeWindowBrowserTest::TearDown();
    printing::PrintBackend::SetPrintBackendForTesting(nullptr);
  }

 private:
  scoped_refptr<printing::TestPrintBackend> backend_;
#if BUILDFLAG(ENABLE_OOP_PRINTING)
  mojo::Remote<printing::mojom::PrintBackendService> remote_;
  std::unique_ptr<printing::PrintBackendServiceTestImpl> service_;
#endif
};

IN_PROC_BROWSER_TEST_F(BarcPdfPrintBrowserTest,
                       PdfPrintPreviewKeepsExactProfileAndCleansUp) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  ASSERT_EQ(1, barc_window_select(work_id));
  const GURL pdf_url = embedded_test_server()->GetURL("/pdf/test.pdf");
  Navigate(work, pdf_url);
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return pdf_extension_test_util::GetOnlyPdfExtensionHost(contents) != nullptr;
  }));
  // Mechanical load proof, without hit-test/foreground requirements.
  pdf_extension_test_util::EnsurePDFHasLoadedOptions options;
  options.wait_for_hit_test_data = false;
  ASSERT_TRUE(pdf_extension_test_util::EnsurePDFHasLoadedWithOptions(
      contents, options));
  EXPECT_EQ(work->GetProfile(), contents->GetBrowserContext());
  EXPECT_EQ(work->GetProfile(),
      pdf_extension_test_util::GetOnlyPdfExtensionHost(contents)
          ->GetBrowserContext());
  const int32_t work_tab = barc_window_tab_at(work_id, 0);
  const int work_entry = contents->GetController().GetLastCommittedEntry()
                             ->GetUniqueID();

  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  Navigate(personal, embedded_test_server()->GetURL("/title1.html"));
  auto* personal_contents = personal->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(personal_contents, R"(
    document.body.innerHTML = '<input id="draft" value="unsaved Personal">';
    window.liveCounter = (() => { let count = 40; return () => ++count; })();
  )"));
  const int personal_entry = personal_contents->GetController()
                                 .GetLastCommittedEntry()->GetUniqueID();
  ASSERT_EQ(1, barc_window_select(personal_id));
  EXPECT_EQ(BrowserView::GetBrowserViewForBrowser(work)->GetWidget(),
            BrowserView::GetBrowserViewForBrowser(personal)->GetWidget());
  auto* controller = printing::PrintPreviewDialogController::GetInstance();
  ASSERT_TRUE(controller);
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_PRINT));
  EXPECT_EQ(0, barc_tab_execute_command(personal_id, work_tab, BARC_PAGE_PRINT));
  EXPECT_EQ(nullptr, controller->GetPrintPreviewForContents(contents));
  EXPECT_EQ(nullptr, controller->GetPrintPreviewForContents(personal_contents));

  ASSERT_EQ(1, barc_window_select(work_id));
  content::WebContents* preview = nullptr;
  {
    printing::TestPrintPreviewObserver observer(/*wait_for_loaded=*/true);
    ASSERT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_PRINT));
    preview = observer.WaitUntilPreviewIsReadyAndReturnPreviewDialog();
  }
  ASSERT_TRUE(preview);
  auto* preview_ui = preview->GetWebUI()->GetController()
                         ->GetAs<printing::PrintPreviewUI>();
  ASSERT_TRUE(preview_ui);
  // PDFs are nonmodifiable: preview completion need not emit per-page events.
  auto preview_data = preview_ui->GetPrintPreviewDataForIndex(
      printing::COMPLETE_PREVIEW_DOCUMENT_INDEX);
  ASSERT_TRUE(preview_data);
  EXPECT_GT(preview_data->size(), 0u);
  EXPECT_EQ(preview, controller->GetPrintPreviewForContents(contents));
  EXPECT_EQ(contents, controller->GetInitiator(preview));
  EXPECT_EQ(std::optional<bool>(true), controller->IsPrintingPdf(preview));
  EXPECT_EQ(work->GetProfile(), preview->GetBrowserContext());
  EXPECT_NE(personal->GetProfile(), preview->GetBrowserContext());
  EXPECT_EQ(nullptr, controller->GetPrintPreviewForContents(personal_contents));
  auto* work_dialogs = web_modal::WebContentsModalDialogManager::FromWebContents(
      contents);
  auto* personal_dialogs =
      web_modal::WebContentsModalDialogManager::FromWebContents(personal_contents);
  ASSERT_TRUE(work_dialogs);
  ASSERT_TRUE(personal_dialogs);
  EXPECT_TRUE(work_dialogs->IsDialogActive());
  EXPECT_FALSE(personal_dialogs->IsDialogActive());
  ASSERT_TRUE(work_dialogs->delegate());
  auto* work_host = work->GetWebContentsModalDialogHostForTab(
      tabs::TabInterface::GetFromContents(contents));
  ASSERT_TRUE(work_host);
  EXPECT_EQ(work_host, work_dialogs->delegate()->GetWebContentsModalDialogHost(
                           contents));
  EXPECT_NE(work_host, personal->GetWebContentsModalDialogHostForTab(
                           tabs::TabInterface::GetFromContents(personal_contents)));

  // Cancel the real preview UI; neither source document is recreated.
  auto* ui = preview->GetWebUI()->GetController()
                 ->GetAs<printing::PrintPreviewUI>();
  ASSERT_TRUE(ui);
  content::WebContentsDestroyedWatcher cancelled(preview);
  ui->OnClosePrintPreviewDialog();
  cancelled.Wait();
  EXPECT_EQ(nullptr, controller->GetPrintPreviewForContents(contents));
  EXPECT_FALSE(work_dialogs->IsDialogActive());
  EXPECT_EQ(pdf_url, contents->GetLastCommittedURL());
  EXPECT_EQ(work_entry,
            contents->GetController().GetLastCommittedEntry()->GetUniqueID());
  EXPECT_EQ(41, content::EvalJs(personal_contents, "liveCounter()"));
  EXPECT_EQ("unsaved Personal",
            content::EvalJs(personal_contents, "draft.value"));

  // A second real preview must also die when its exact initiating tab closes.
  {
    printing::TestPrintPreviewObserver observer(/*wait_for_loaded=*/true);
    ASSERT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_PRINT));
    preview = observer.WaitUntilPreviewIsReadyAndReturnPreviewDialog();
  }
  ASSERT_TRUE(preview);
  content::WebContentsDestroyedWatcher preview_closed(preview);
  content::WebContentsDestroyedWatcher initiator_closed(contents);
  ASSERT_EQ(1, barc_tab_close(work_id, work_tab));
  initiator_closed.Wait();
  preview_closed.Wait();
  EXPECT_EQ(nullptr, controller->GetPrintPreviewForContents(personal_contents));
  EXPECT_EQ(personal->GetProfile(), personal_contents->GetBrowserContext());
  EXPECT_EQ(personal_entry, personal_contents->GetController()
                                .GetLastCommittedEntry()->GetUniqueID());
  EXPECT_EQ(42, content::EvalJs(personal_contents, "liveCounter()"));
  EXPECT_EQ("unsaved Personal",
            content::EvalJs(personal_contents, "draft.value"));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       TranslationIsDocumentOwnedIsolatedAndMutationDriven) {
  ASSERT_TRUE(embedded_test_server()->Start());
  net::EmbeddedTestServer other_origin;
  other_origin.ServeFilesFromSourceDirectory("chrome/test/data");
  ASSERT_TRUE(other_origin.Start());
  const GURL url = embedded_test_server()->GetURL("/title1.html");
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  Navigate(work, url);
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(contents, content::JsReplace(R"(
    document.documentElement.lang='fr';
    document.body.innerHTML='<p id=text>Bonjour</p><input id=draft value=private-draft>';
    window.__nookTranslate={apply(){throw new Error('main-world spoof')}};
    window.webkit={messageHandlers:{nookTranslate:{postMessage(){throw new Error('spoof')}}}};
    window.retained=(()=>{let n=2;return()=>++n})();
    new Promise(resolve=>{const f=document.createElement('iframe'); f.onload=resolve;
      f.src=$1; document.body.append(f);});
  )", other_origin.GetURL("/title1.html"))));
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  Navigate(personal, url);
  ASSERT_EQ(1, barc_window_select(personal_id));
  NavigationEvents events;
  const int32_t tab = barc_window_tab_at(work_id, 0);
  events.token = barc_tab_observe(work_id, tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  auto dispatch = [&](uint64_t generation, uint64_t request, int32_t operation, const char* pairs) {
    return barc_tab_translate(events.token, generation, request, operation, pairs,
                              NavigationEvents::ReceiveTranslation);
  };
  auto replied = [&](uint64_t request) {
    return std::ranges::any_of(events.translations, [=](const auto& reply) { return reply.request == request; });
  };
  ASSERT_NE(content::Visibility::VISIBLE, contents->GetVisibility());
  contents->SetPageFrozen(true);
  // Test execution is an unfreezable renderer barrier; controller commands are
  // ordinary page work and must remain deferred until this exact page resumes.
  EXPECT_EQ("Bonjour", content::EvalJs(contents, "text.textContent"));
  ASSERT_EQ(1, dispatch(1, 1, 0, "[]"));
  EXPECT_EQ("Bonjour", content::EvalJs(contents, "text.textContent"));
  EXPECT_FALSE(replied(1));
  contents->SetPageFrozen(false);
  ASSERT_TRUE(base::test::RunUntil([&] { return replied(1); }));
  EXPECT_EQ(0, events.translations.back().result);
  EXPECT_NE(std::string::npos, events.translations.back().payload.find("Bonjour"));
  ASSERT_EQ(1, dispatch(1, 2, 1, "[]"));
  ASSERT_TRUE(base::test::RunUntil([&] { return replied(2); }));
  EXPECT_EQ(0, events.translations.back().result);
  ASSERT_EQ(1, dispatch(1, 3, 2, R"([{"id":"0","text":"Hello"}])"));
  ASSERT_TRUE(base::test::RunUntil([&] { return replied(3); }));
  EXPECT_EQ("Hello", content::EvalJs(contents, "text.textContent"));
  // Resuming the existing view must retain its live endpoint and translations.
  ASSERT_EQ(1, dispatch(1, 4, 1, "[]"));
  ASSERT_TRUE(base::test::RunUntil([&] { return replied(4); }));
  EXPECT_EQ(0, events.translations.back().result);
  EXPECT_EQ("Hello", content::EvalJs(contents, "text.textContent"));
  EXPECT_EQ("private-draft", content::EvalJs(contents, "draft.value"));
  EXPECT_EQ(3, content::EvalJs(contents, "retained()"));
  EXPECT_TRUE(BrowserView::GetBrowserViewForBrowser(personal)->IsSelectedForNativeWindow());
  auto* child = content::ChildFrameAt(contents->GetPrimaryMainFrame(), 0);
  ASSERT_TRUE(child);
  EXPECT_EQ("This page has no title.", content::EvalJs(child, "document.body.textContent.trim()"));
  mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> child_remote;
  child->GetRemoteAssociatedInterfaces()->GetInterface(&child_remote);
  base::test::TestFuture<bool, std::string, std::string,
      std::vector<chrome::mojom::NookTranslationNodePtr>> child_reply;
  child_remote->NookTranslate(child->GetDocumentToken(), 1, 0, {}, {}, child_reply.GetCallback<bool, const std::string&, const std::string&,
      std::vector<chrome::mojom::NookTranslationNodePtr>>());
  EXPECT_FALSE(child_reply.Get<0>());
  ASSERT_TRUE(content::ExecJs(contents, "const p=document.createElement('p');p.textContent='Salut';document.body.append(p);"));
  ASSERT_TRUE(base::test::RunUntil([&] { return replied(0); }));
  EXPECT_NE(std::string::npos, events.translations.back().payload.find("Salut"));
  // No Swift restore participates: mutation overflow must restore locally.
  EXPECT_EQ(true, content::EvalJs(contents, R"(
    new Promise(resolve => {
      const watch = new MutationObserver(() => {
        if (text.textContent === 'Bonjour') { watch.disconnect(); resolve(true); }
      });
      watch.observe(text, {subtree:true, characterData:true});
      const large=document.createElement('p');large.textContent='x'.repeat(32769);document.body.append(large);
    })
  )"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return std::ranges::any_of(events.translations, [](const auto& reply) {
      return reply.request == 0 && reply.result == 2;
    });
  }));
  ASSERT_EQ(1, dispatch(1, 5, 3, "[]"));
  ASSERT_TRUE(base::test::RunUntil([&] { return replied(5); }));
  EXPECT_EQ("Bonjour", content::EvalJs(contents, "text.textContent"));
  EXPECT_EQ("function", content::EvalJs(contents, "typeof window.__nookTranslate.apply"));
  SharedProfileResult private_result;
  barc_private_session_open_window(SharedProfileCompleted, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  const int32_t private_id = private_result.Get<1>();
  auto* private_browser = SharedWindow(private_id);
  ASSERT_TRUE(private_browser && private_browser->GetProfile()->IsOffTheRecord());
  Navigate(private_browser, url);
  auto* private_contents = private_browser->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(private_contents, "document.body.innerHTML='<p>Prive</p>'"));
  NavigationEvents private_events;
  private_events.token = barc_tab_observe(private_id, barc_window_tab_at(private_id, 0),
                                         NavigationEvents::Receive, &private_events);
  ASSERT_NE(0u, private_events.token);
  ASSERT_EQ(1, barc_tab_translate(private_events.token, 1, 1, 0, "[]", NavigationEvents::ReceiveTranslation));
  ASSERT_TRUE(base::test::RunUntil([&] { return !private_events.translations.empty(); }));
  EXPECT_NE(std::string::npos, private_events.translations.back().payload.find("Prive"));
  ASSERT_EQ(1, barc_tab_translate(private_events.token, 1, 2, 1, "[]", NavigationEvents::ReceiveTranslation));
  ASSERT_TRUE(base::test::RunUntil([&] { return private_events.translations.size() == 2; }));
  ASSERT_EQ(1, barc_tab_translate(private_events.token, 1, 3, 2,
      R"([{"id":"0","text":"Private translated"}])", NavigationEvents::ReceiveTranslation));
  ASSERT_TRUE(base::test::RunUntil([&] { return private_events.translations.size() == 3; }));
  EXPECT_EQ("Private translated", content::EvalJs(private_contents, "document.body.textContent"));
  barc_tab_unobserve(private_events.token);
  EXPECT_EQ(true, content::EvalJs(private_contents, R"(
    new Promise(resolve => {
      if (document.body.textContent === 'Prive') { resolve(true); return; }
      const watch = new MutationObserver(() => {
        if (document.body.textContent === 'Prive') { watch.disconnect(); resolve(true); }
      });
      watch.observe(document.body, {subtree:true, characterData:true});
    })
  )"));
  EXPECT_EQ("Bonjour", content::EvalJs(contents, "text.textContent"));
  // Initial overflow must also clear its partial map without a host restore.
  const int32_t limit_id = Open(kSharedWork, work_id, BARC_PROFILE_BLANK);
  auto* limit_browser = SharedWindow(limit_id);
  Navigate(limit_browser, url);
  auto* limit_contents = limit_browser->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(limit_contents,
      "document.body.replaceChildren(...Array.from({length:4097},()=>document.createTextNode('word')));"));
  NavigationEvents limit_events;
  limit_events.token = barc_tab_observe(limit_id, barc_window_tab_at(limit_id, 0),
                                       NavigationEvents::Receive, &limit_events);
  ASSERT_NE(0u, limit_events.token);
  auto limited = [&](uint64_t request, int32_t operation) {
    ASSERT_EQ(1, barc_tab_translate(limit_events.token, 1, request, operation, "[]",
                                   NavigationEvents::ReceiveTranslation));
    ASSERT_TRUE(base::test::RunUntil([&] {
      return std::ranges::any_of(limit_events.translations,
          [=](const auto& reply) { return reply.request == request; });
    }));
  };
  limited(1, 0); limited(2, 1);
  auto initial_overflow = std::ranges::find_if(limit_events.translations,
      [](const auto& reply) { return reply.request == 2; });
  ASSERT_NE(limit_events.translations.end(), initial_overflow);
  EXPECT_EQ(2, initial_overflow->result);
  ASSERT_TRUE(content::ExecJs(limit_contents, "document.body.innerHTML='<p>Recovered</p>'"));
  limited(3, 0); limited(4, 1);
  auto recovered = std::ranges::find_if(limit_events.translations,
      [](const auto& reply) { return reply.request == 4; });
  ASSERT_NE(limit_events.translations.end(), recovered);
  EXPECT_EQ(0, recovered->result);
  EXPECT_NE(std::string::npos, recovered->payload.find("Recovered"));
  limited(5, 3);

  Navigate(work, url);
  EXPECT_EQ(0, dispatch(1, 6, 2, R"([{"id":"0","text":"STALE"}])"));
  ASSERT_NE(content::Visibility::VISIBLE, contents->GetVisibility());
  contents->SetPageFrozen(true);
  EXPECT_EQ("This page has no title.", content::EvalJs(contents, "document.body.textContent.trim()"));
  ASSERT_EQ(1, dispatch(2, 7, 0, "[]"));
  ASSERT_EQ(1, dispatch(3, 8, 0, "[]"));
  EXPECT_EQ("This page has no title.", content::EvalJs(contents, "document.body.textContent.trim()"));
  EXPECT_FALSE(replied(7));
  EXPECT_FALSE(replied(8));
  contents->SetPageFrozen(false);
  ASSERT_TRUE(base::test::RunUntil([&] { return replied(7) && replied(8); }));
  const auto superseded = std::ranges::find_if(events.translations,
      [](const auto& reply) { return reply.request == 7; });
  const auto current = std::ranges::find_if(events.translations,
      [](const auto& reply) { return reply.request == 8; });
  ASSERT_NE(events.translations.end(), superseded);
  ASSERT_NE(events.translations.end(), current);
  EXPECT_EQ(1, superseded->result);
  EXPECT_EQ(0, current->result);
  EXPECT_EQ(0, dispatch(1, 9, 1, "[]"));
  EXPECT_EQ("This page has no title.", content::EvalJs(contents, "document.body.textContent.trim()"));
  barc_tab_unobserve(events.token);
  EXPECT_EQ(0, dispatch(3, 10, 0, "[]"));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       UserCSSIsDocumentOwnedMainFrameOnlyAndPrivateSafe) {
  ASSERT_TRUE(embedded_test_server()->Start());
  net::EmbeddedTestServer other_origin;
  other_origin.ServeFilesFromSourceDirectory("chrome/test/data");
  ASSERT_TRUE(other_origin.Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const GURL url = embedded_test_server()->GetURL("/title1.html");
  Navigate(work, url);
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  const int32_t work_tab = barc_window_tab_at(work_id, 0);
  ASSERT_TRUE(content::ExecJs(contents, content::JsReplace(R"(
    document.body.style.color = 'rgb(1, 1, 1)';
    document.body.style.fontSize = '17px';
    window.liveState = (() => { let n = 10; return () => ++n; })();
    const makeFrame = url => new Promise(resolve => {
      const frame = document.createElement('iframe');
      frame.onload = () => resolve(); frame.src = url; document.body.append(frame);
    });
    Promise.all([makeFrame($1), makeFrame($2)]);
  )", url, other_origin.GetURL("/title1.html"))));
  auto* same = content::ChildFrameAt(contents->GetPrimaryMainFrame(), 0);
  auto* cross = content::ChildFrameAt(contents->GetPrimaryMainFrame(), 1);
  ASSERT_TRUE(same); ASSERT_TRUE(cross);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  Navigate(personal, url);
  auto* personal_contents = personal->GetTabStripModel()->GetActiveWebContents();
  ASSERT_EQ(1, barc_window_select(personal_id));
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, work_tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  EXPECT_EQ(0, barc_tab_set_user_css(0, 1, url.spec().c_str(), "body{}", NavigationEvents::ReceiveStyle));
  EXPECT_EQ(0u, barc_tab_observe(personal_id, work_tab, NavigationEvents::Receive, &events));
  EXPECT_EQ(0, barc_tab_set_user_css(events.token, 1, "https://foreign.invalid/", "body{}", NavigationEvents::ReceiveStyle));
  ASSERT_EQ(1, barc_tab_set_user_css(events.token, 1, url.spec().c_str(),
      "body { color: rgb(3, 4, 5) !important; font-size: 42px !important; }", NavigationEvents::ReceiveStyle));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.style_results.size() == 1; }));
  EXPECT_EQ(0, events.style_results.back());
  EXPECT_EQ("rgb(3, 4, 5)", content::EvalJs(contents, "getComputedStyle(document.body).color"));
  EXPECT_EQ("42px", content::EvalJs(contents, "getComputedStyle(document.body).fontSize"));
  for (auto* frame : {same, cross}) {
    EXPECT_EQ("rgb(0, 0, 0)", content::EvalJs(frame, "getComputedStyle(document.body).color"));
    // Even a correctly addressed child token cannot broaden this CSS-only API.
    mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> remote;
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&remote);
    base::test::TestFuture<bool> refused;
    remote->SetNookBoostStyle(frame->GetDocumentToken(), "body{color:red!important}", refused.GetCallback());
    EXPECT_FALSE(refused.Get());
    EXPECT_EQ("rgb(0, 0, 0)", content::EvalJs(frame, "getComputedStyle(document.body).color"));
  }
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_EQ("rgb(0, 0, 0)", content::EvalJs(personal_contents, "getComputedStyle(document.body).color"));
  ASSERT_TRUE(content::ExecJs(contents, "history.pushState(null, '', '#same-document')"));
  const GURL current = contents->GetLastCommittedURL();
  EXPECT_EQ("rgb(3, 4, 5)", content::EvalJs(contents, "getComputedStyle(document.body).color"));
  ASSERT_EQ(1, barc_tab_set_user_css(events.token, 2, current.spec().c_str(),
      "body { color: rgb(9, 8, 7) !important; }", NavigationEvents::ReceiveStyle));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.style_results.size() == 2; }));
  EXPECT_EQ(0, events.style_results.back());
  EXPECT_EQ("rgb(9, 8, 7)", content::EvalJs(contents, "getComputedStyle(document.body).color"));
  EXPECT_EQ("17px", content::EvalJs(contents, "getComputedStyle(document.body).fontSize"));
  ASSERT_EQ(1, barc_tab_set_user_css(events.token, 3, current.spec().c_str(), "", NavigationEvents::ReceiveStyle));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.style_results.size() == 3; }));
  EXPECT_EQ(0, events.style_results.back());
  EXPECT_EQ("rgb(1, 1, 1)", content::EvalJs(contents, "getComputedStyle(document.body).color"));
  EXPECT_EQ(11, content::EvalJs(contents, "liveState()"));

  const auto stale_document = contents->GetPrimaryMainFrame()->GetDocumentToken();
  Navigate(work, url);
  mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> remote;
  auto* fresh = contents->GetPrimaryMainFrame();
  ASSERT_NE(stale_document, fresh->GetDocumentToken());
  fresh->GetRemoteAssociatedInterfaces()->GetInterface(&remote);
  base::test::TestFuture<bool> stale;
  remote->SetNookBoostStyle(stale_document, "body{color:red!important}", stale.GetCallback());
  EXPECT_FALSE(stale.Get());
  EXPECT_EQ("rgb(0, 0, 0)", content::EvalJs(contents, "getComputedStyle(document.body).color"));
  ASSERT_EQ(1, barc_tab_set_user_css(events.token, 4, url.spec().c_str(), "body{color:rgb(3,4,5)!important}", NavigationEvents::ReceiveStyle));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.style_results.size() == 4; }));
  EXPECT_EQ(0, events.style_results.back());
  EXPECT_EQ("rgb(3, 4, 5)", content::EvalJs(contents, "getComputedStyle(document.body).color"));

  SharedProfileResult private_result;
  barc_private_session_open_window(SharedProfileCompleted, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  const int32_t private_id = private_result.Get<1>();
  auto* private_window = SharedWindow(private_id);
  ASSERT_TRUE(private_window->GetProfile()->IsOffTheRecord());
  Navigate(private_window, url);
  auto* private_contents = private_window->GetTabStripModel()->GetActiveWebContents();
  NavigationEvents private_events;
  private_events.token = barc_tab_observe(private_id, barc_window_tab_at(private_id, 0), NavigationEvents::Receive, &private_events);
  ASSERT_NE(0u, private_events.token);
  ASSERT_EQ(1, barc_tab_set_user_css(private_events.token, 1, url.spec().c_str(), "body{color:rgb(6,7,8)!important}", NavigationEvents::ReceiveStyle));
  ASSERT_TRUE(base::test::RunUntil([&] { return private_events.style_results.size() == 1; }));
  EXPECT_EQ(0, private_events.style_results.back());
  EXPECT_EQ("rgb(6, 7, 8)", content::EvalJs(private_contents, "getComputedStyle(document.body).color"));
  EXPECT_EQ("rgb(3, 4, 5)", content::EvalJs(contents, "getComputedStyle(document.body).color"));
  EXPECT_EQ("rgb(0, 0, 0)", content::EvalJs(personal_contents, "getComputedStyle(document.body).color"));
  barc_tab_unobserve(private_events.token);
  EXPECT_EQ(0, barc_tab_set_user_css(private_events.token, 2, url.spec().c_str(), "", NavigationEvents::ReceiveStyle));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       PageCommandsRequireExactActiveOwnerAndRespectPolicy) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  const int32_t work_tab = barc_window_tab_at(work_id, 0);
  const int32_t background = barc_tab_create(work_id, "about:blank", 0);
  ASSERT_GT(background, 0);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  ASSERT_GT(personal_id, 0);
  ASSERT_EQ(1, barc_tab_select(personal_id, barc_window_tab_at(personal_id, 0)));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_IN));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_DEVTOOLS_INSPECT));
  ASSERT_EQ(1, barc_tab_select(work_id, work_tab));
  EXPECT_EQ(0, barc_tab_execute_command(personal_id, work_tab, BARC_PAGE_ZOOM_IN));
  EXPECT_EQ(0, barc_tab_execute_command(personal_id, work_tab, BARC_PAGE_DEVTOOLS_INSPECT));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, background, BARC_PAGE_ZOOM_IN));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, background, BARC_PAGE_DEVTOOLS_INSPECT));
  EXPECT_EQ(0, barc_tab_execute_command(-1, work_tab, BARC_PAGE_FIND));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, -1));
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  auto* zoom = zoom::ZoomController::FromWebContents(contents);
  ASSERT_TRUE(zoom);
  const double initial_zoom = zoom->GetZoomLevel();
  ASSERT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_IN));
  EXPECT_GT(zoom->GetZoomLevel(), initial_zoom);
  EXPECT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_OUT));
  EXPECT_DOUBLE_EQ(initial_zoom, zoom->GetZoomLevel());
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_RESET));
  ASSERT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_IN));
  EXPECT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_RESET));
  EXPECT_DOUBLE_EQ(initial_zoom, zoom->GetZoomLevel());
  ASSERT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_FIND));
  EXPECT_TRUE(FindBarController::From(work)->find_bar()->IsFindBarVisible());
  EXPECT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_FIND_NEXT));
  EXPECT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_FIND_PREVIOUS));
  EXPECT_EQ(nullptr, DevToolsWindow::GetInstanceForInspectedWebContents(contents));
  ASSERT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_DEVTOOLS_INSPECT));
  EXPECT_NE(nullptr, DevToolsWindow::GetInstanceForInspectedWebContents(contents));
  auto* commands = chrome::BrowserCommandController::From(work);
  commands->UpdateCommandEnabled(IDC_DEV_TOOLS_INSPECT, false);
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_DEVTOOLS_INSPECT));
  commands->UpdateCommandEnabled(IDC_DEV_TOOLS_INSPECT, true);
  commands->UpdateCommandEnabled(IDC_FIND, false);
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_FIND));
  commands->UpdateCommandEnabled(IDC_FIND, true);
  work->GetProfile()->GetPrefs()->SetBoolean(prefs::kPrintingEnabled, false);
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_PRINT));
  work->GetProfile()->GetPrefs()->SetInteger(
      prefs::kDevToolsAvailability,
      static_cast<int>(policy::DeveloperToolsAvailability::kDisallowed));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_DEVTOOLS));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_DEVTOOLS_INSPECT));
  // The old window/tab pair cannot act on a same-profile transferred document.
  const int32_t peer = barc_window_new_peer(work_id);
  ASSERT_GT(peer, 0);
  ASSERT_EQ(1, barc_tab_transfer(work_id, work_tab, peer));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_IN));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_DEVTOOLS_INSPECT));
  EXPECT_EQ(1, barc_tab_execute_command(peer, work_tab, BARC_PAGE_ZOOM_IN));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       DeveloperPanelsSwitchExistingInspectorAndRespectAdmission) {
  const int32_t owner = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* browser = SharedWindow(owner);
  ASSERT_TRUE(browser);
  const int32_t tab = barc_window_tab_at(owner, 0);
  auto* contents = browser->GetTabStripModel()->GetActiveWebContents();
  const int32_t background = barc_tab_create(owner, "about:blank", 0);
  ASSERT_GT(background, 0);
  EXPECT_EQ(0, barc_tab_execute_command(owner, background, BARC_PAGE_DEVTOOLS_NETWORK));
  EXPECT_EQ(nullptr, DevToolsWindow::GetInstanceForInspectedWebContents(contents));
  ASSERT_EQ(1, barc_tab_execute_command(owner, tab, BARC_PAGE_DEVTOOLS_NETWORK));
  auto* inspector = DevToolsWindow::GetInstanceForInspectedWebContents(contents);
  ASSERT_TRUE(inspector);
  // Navigation completion precedes DevTools' application/settings bootstrap.
  // Use its existing load-completed contract before inspecting the frontend.
  base::test::TestFuture<void> frontend_ready;
  inspector->SetLoadCompletedCallback(frontend_ready.GetCallback());
  ASSERT_TRUE(frontend_ready.Wait());
  auto* frontend = inspector->GetDevToolsWebContents().get();
  ASSERT_TRUE(frontend);
  ASSERT_TRUE(content::WaitForLoadStop(frontend));
  const auto selected_panel = [](content::WebContents* frontend,
                                 const char* expected) {
    return content::EvalJs(frontend, content::JsReplace(R"JS(
      (async () => {
        const UI = await import('./ui/legacy/legacy.js');
        const pane = UI.InspectorView.InspectorView.instance().tabbedPane;
        if (pane.selectedTabId === $1) return true;
        return await new Promise(resolve => {
          const listener = () => {
            if (pane.selectedTabId !== $1) return;
            pane.removeEventListener('TabSelected', listener);
            resolve(true);
          };
          pane.addEventListener('TabSelected', listener);
        });
      })()
    )JS", expected));
  };
  ASSERT_EQ(true, selected_panel(frontend, "network"));
  ASSERT_EQ(1, barc_tab_execute_command(owner, tab, BARC_PAGE_DEVTOOLS_PERFORMANCE));
  EXPECT_EQ(inspector, DevToolsWindow::GetInstanceForInspectedWebContents(contents));
  ASSERT_EQ(true, selected_panel(frontend, "timeline"));
  ASSERT_EQ(1, barc_tab_execute_command(owner, tab, BARC_PAGE_DEVTOOLS_CONSOLE));
  ASSERT_EQ(true, selected_panel(frontend, "console"));
  auto* commands = chrome::BrowserCommandController::From(browser);
  commands->UpdateCommandEnabled(IDC_DEV_TOOLS, false);
  EXPECT_EQ(0, barc_tab_execute_command(owner, tab, BARC_PAGE_DEVTOOLS_NETWORK));
  commands->UpdateCommandEnabled(IDC_DEV_TOOLS, true);
  browser->GetProfile()->GetPrefs()->SetInteger(
      prefs::kDevToolsAvailability,
      static_cast<int>(policy::DeveloperToolsAvailability::kDisallowed));
  EXPECT_EQ(0, barc_tab_execute_command(owner, tab, BARC_PAGE_DEVTOOLS_NETWORK));
  EXPECT_EQ(0, barc_tab_execute_command(owner, tab, BARC_PAGE_DEVTOOLS_PERFORMANCE));
  EXPECT_EQ(0, barc_tab_execute_command(owner, tab, BARC_PAGE_DEVTOOLS_CONSOLE));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       BackgroundTabMuteReportsActualStateWithoutSelection) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t active_tab = barc_window_tab_at(work_id, 0);
  const int32_t background = barc_tab_create(work_id, "about:blank", 0);
  ASSERT_GT(background, 0);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  const int32_t personal_tab = barc_window_tab_at(personal_id, 0);
  ASSERT_EQ(1, barc_tab_select(personal_id, personal_tab));
  auto* contents = tabs::TabHandle(background).Get()->GetContents();
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, background, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  ASSERT_FALSE(events.events.empty());
  EXPECT_EQ(contents->IsAudioMuted(), (events.events.back().flags & BARC_TAB_MUTED) != 0);
  EXPECT_EQ(contents->IsCurrentlyAudible(), (events.events.back().flags & BARC_TAB_AUDIBLE) != 0);
  const auto count = events.Count(BARC_TAB_STATE);
  EXPECT_EQ(0, barc_tab_set_muted(personal_id, background, 1));
  EXPECT_EQ(0, barc_tab_set_muted(work_id, background, 2));
  EXPECT_EQ(0, barc_tab_set_muted(-1, background, 1));
  ASSERT_EQ(1, barc_tab_set_muted(work_id, background, 1));
  EXPECT_TRUE(contents->IsAudioMuted());
  EXPECT_EQ(TabMutedReason::kAudioIndicator, GetTabAudioMutedReason(contents));
  EXPECT_GT(events.Count(BARC_TAB_STATE), count);
  EXPECT_NE(0u, events.events.back().flags & BARC_TAB_MUTED);
  ASSERT_EQ(1, barc_tab_set_muted(work_id, background, 0));
  EXPECT_FALSE(contents->IsAudioMuted());
  EXPECT_EQ(0u, events.events.back().flags & BARC_TAB_MUTED);
  EXPECT_EQ(active_tab, work->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
  EXPECT_EQ(personal_tab, SharedWindow(personal_id)->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
  EXPECT_TRUE(SharedWindow(personal_id)->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
  // A transferred background tab retains its observer and explicit identity.
  const int32_t peer = barc_window_new_peer(work_id);
  ASSERT_GT(peer, 0);
  ASSERT_EQ(1, barc_tab_transfer(work_id, background, peer));
  EXPECT_EQ(0, barc_tab_set_muted(work_id, background, 1));
  EXPECT_EQ(1, barc_tab_set_muted(peer, background, 1));
  EXPECT_EQ(peer, events.events.back().window);
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       AudioCallbackCannotRetargetCommandsDuringClose) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t active = barc_window_tab_at(work_id, 0);
  const int32_t background = barc_tab_create(work_id, "about:blank", 0);
  ASSERT_GT(background, 0);
  ASSERT_EQ(1, barc_tab_select(work_id, active));
  auto* contents = tabs::TabHandle(background).Get()->GetContents();
  auto weak_contents = contents->GetWeakPtr();
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, background, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  events.commands_on_audio_state = true;
  events.close_on_audio_state = true;
  EXPECT_EQ(1, barc_tab_set_muted(work_id, background, 1));
  EXPECT_TRUE(events.audio_commands_refused);
  ASSERT_TRUE(base::test::RunUntil([&] { return events.Count(BARC_TAB_CLOSED) == 1; }));
  ASSERT_TRUE(base::test::RunUntil([&] { return !weak_contents; }));
  EXPECT_EQ(active, barc_window_tab_at(work_id, 0));
  EXPECT_EQ(0, barc_tab_set_muted(work_id, background, 0));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, background, BARC_PAGE_FIND));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       NativeDownloadsScopePrivateManagersAndConfirmCancellation) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      &content::SlowDownloadHttpResponse::HandleSlowDownloadRequest));
  ASSERT_TRUE(embedded_test_server()->Start());
  base::ScopedTempDir targets;
  base::ScopedClosureRunner remove_targets(base::BindLambdaForTesting([&] {
    base::ScopedAllowBlockingForTesting allow_fixture_cleanup;
    if (targets.IsValid()) EXPECT_TRUE(targets.Delete());
  }));
  {
    base::ScopedAllowBlockingForTesting allow_fixture_setup;
    ASSERT_TRUE(targets.CreateUniqueTempDir());
  }
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  SharedProfileResult private_result;
  barc_private_session_open_window(SharedProfileCompleted, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  const int32_t private_id = private_result.Get<1>();
  std::array<char, 37> private_uuid{};
  ASSERT_EQ(37u, barc_window_private_session_uuid(private_id, private_uuid.data(), private_uuid.size()));
  const std::string private_identity(private_uuid.data());
  base::ScopedClosureRunner cleanup(base::BindLambdaForTesting(
      [work = SharedWindow(work_id)->GetProfile()->GetWeakPtr(),
       private_profile = SharedWindow(private_id)->GetProfile()->GetWeakPtr()] {
        for (const auto& profile : {work, private_profile}) {
          if (!profile) continue;
          content::DownloadManager::DownloadVector items;
          profile->GetDownloadManager()->GetAllDownloads(&items);
          for (const auto& item : items) item->Cancel(true);
        }
      }));
  NativeDownloadEvents events;
  events.token = barc_downloads_observe(NativeDownloadEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  EXPECT_EQ(0u, barc_downloads_observe(NativeDownloadEvents::Receive, &events));
  for (const int32_t id : {work_id, private_id}) {
    auto* profile = SharedWindow(id)->GetProfile();
    auto* manager = profile->GetDownloadManager();
    DownloadPrefs::FromDownloadManager(manager)->SetDownloadPath(targets.GetPath());
    profile->GetPrefs()->SetBoolean(prefs::kPromptForDownload, false);
    content::DownloadTestObserverInProgress progressing(manager, 1);
    ASSERT_EQ(1, barc_tab_navigate(id, barc_window_tab_at(id, 0),
        embedded_test_server()->GetURL(content::SlowDownloadHttpResponse::kKnownSizeUrl).spec().c_str()));
    progressing.WaitForFinished();
  }
  ASSERT_TRUE(base::test::RunUntil([&] {
    return events.Last(kSharedWork, BARC_DOWNLOAD_ITEM).has_value() &&
           events.Last(private_identity, BARC_DOWNLOAD_ITEM).has_value();
  }));
  const auto work = *events.Last(kSharedWork, BARC_DOWNLOAD_ITEM);
  const auto private_item = *events.Last(private_identity, BARC_DOWNLOAD_ITEM);
  EXPECT_EQ(0u, work.flags & BARC_DOWNLOAD_PRIVATE);
  EXPECT_NE(0u, private_item.flags & BARC_DOWNLOAD_PRIVATE);
  EXPECT_NE(work.manager, private_item.manager);
  EXPECT_EQ(0, barc_download_action(events.token, private_item.manager, work.guid.c_str(), BARC_DOWNLOAD_CANCEL));
  EXPECT_EQ(0u, barc_download_copy_safe_target(events.token, work.manager, work.guid.c_str(), nullptr, 0));
  EXPECT_EQ(1, barc_download_action(events.token, work.manager, work.guid.c_str(), BARC_DOWNLOAD_CANCEL));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.Last(kSharedWork, BARC_DOWNLOAD_ITEM, BARC_DOWNLOAD_CANCELLED).has_value(); }));
  EXPECT_EQ(BARC_DOWNLOAD_PROGRESS, events.Last(private_identity, BARC_DOWNLOAD_ITEM)->state);
  EXPECT_EQ(1, barc_download_action(events.token, private_item.manager, private_item.guid.c_str(), BARC_DOWNLOAD_CANCEL));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.Last(private_identity, BARC_DOWNLOAD_ITEM, BARC_DOWNLOAD_CANCELLED).has_value(); }));
  auto* private_window = SharedWindow(private_id);
  ui_test_utils::BrowserDestroyedObserver closed(private_window);
  ASSERT_EQ(1, barc_window_close(private_id));
  closed.Wait();
  ASSERT_TRUE(base::test::RunUntil([&] { return events.Last(private_identity, BARC_DOWNLOAD_MANAGER_ENDED).has_value(); }));
  EXPECT_EQ(0, barc_download_action(events.token, private_item.manager, private_item.guid.c_str(), BARC_DOWNLOAD_REMOVE));
  EXPECT_EQ(1, barc_download_action(events.token, work.manager, work.guid.c_str(), BARC_DOWNLOAD_REMOVE));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       NativeDownloadSafeTargetRemovalAndUnsubscribeLifetime) {
  net::test_server::ControllableHttpResponse response(embedded_test_server(), "/native-download");
  ASSERT_TRUE(embedded_test_server()->Start());
  base::ScopedTempDir target;
  base::ScopedClosureRunner remove_target(base::BindLambdaForTesting([&] {
    base::ScopedAllowBlockingForTesting allow_fixture_cleanup;
    if (target.IsValid()) EXPECT_TRUE(target.Delete());
  }));
  {
    base::ScopedAllowBlockingForTesting allow_fixture_setup;
    ASSERT_TRUE(target.CreateUniqueTempDir());
  }
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* profile = SharedWindow(work_id)->GetProfile();
  auto* manager = profile->GetDownloadManager();
  DownloadPrefs::FromDownloadManager(manager)->SetDownloadPath(target.GetPath());
  profile->GetPrefs()->SetBoolean(prefs::kPromptForDownload, false);
  base::ScopedClosureRunner cleanup(base::BindLambdaForTesting([profile = profile->GetWeakPtr()] {
    if (!profile) return;
    content::DownloadManager::DownloadVector items;
    profile->GetDownloadManager()->GetAllDownloads(&items);
    for (const auto& item : items) item->Cancel(true);
  }));
  NativeDownloadEvents events;
  events.token = barc_downloads_observe(NativeDownloadEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  content::DownloadTestObserverTerminal finished(manager, 1,
      content::DownloadTestObserver::ON_DANGEROUS_DOWNLOAD_FAIL);
  ASSERT_EQ(1, barc_tab_navigate(work_id, barc_window_tab_at(work_id, 0),
      embedded_test_server()->GetURL("/native-download").spec().c_str()));
  response.WaitForRequest();
  response.Send("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=fixture.txt\r\nContent-Length: 3\r\n\r\nabc");
  response.Done(); finished.WaitForFinished();
  ASSERT_TRUE(base::test::RunUntil([&] { return events.Last(kSharedWork, BARC_DOWNLOAD_ITEM, BARC_DOWNLOAD_COMPLETE).has_value(); }));
  const auto item = *events.Last(kSharedWork, BARC_DOWNLOAD_ITEM, BARC_DOWNLOAD_COMPLETE);
  EXPECT_NE(0u, item.flags & BARC_DOWNLOAD_SAFE_FILE);
  const auto size = barc_download_copy_safe_target(events.token, item.manager, item.guid.c_str(), nullptr, 0);
  ASSERT_GT(size, 1u);
  std::vector<char> path(size);
  ASSERT_EQ(size, barc_download_copy_safe_target(events.token, item.manager, item.guid.c_str(), path.data(), path.size()));
  EXPECT_EQ(item.target, path.data());
  EXPECT_EQ(0u, barc_download_copy_safe_target(events.token, item.manager, "foreign-guid", nullptr, 0));
  EXPECT_EQ(0, barc_download_action(events.token, item.manager, item.guid.c_str(), BARC_DOWNLOAD_CANCEL));
  const uint64_t stale_token = events.token;
  barc_downloads_unobserve(events.token);
  NativeDownloadEvents stopped;
  stopped.stop_first = true;
  stopped.token = barc_downloads_observe(NativeDownloadEvents::Receive, &stopped);
  ASSERT_NE(0u, stopped.token);
  ASSERT_TRUE(base::test::RunUntil([&] { return stopped.events.size() == 1; }));
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1u, stopped.events.size()); // Unsubscribe inside delivery is final.
  EXPECT_EQ(0, barc_download_action(stale_token, item.manager, item.guid.c_str(), BARC_DOWNLOAD_REMOVE));
  NativeDownloadEvents final;
  final.token = barc_downloads_observe(NativeDownloadEvents::Receive, &final);
  ASSERT_NE(0u, final.token);
  ASSERT_TRUE(base::test::RunUntil([&] { return final.Last(kSharedWork, BARC_DOWNLOAD_ITEM, BARC_DOWNLOAD_COMPLETE).has_value(); }));
  const auto replayed = *final.Last(kSharedWork, BARC_DOWNLOAD_ITEM, BARC_DOWNLOAD_COMPLETE);
  EXPECT_EQ(item.guid, replayed.guid);
  EXPECT_EQ(1, barc_download_action(final.token, replayed.manager, replayed.guid.c_str(), BARC_DOWNLOAD_REMOVE));
  ASSERT_TRUE(base::test::RunUntil([&] { return final.Last(kSharedWork, BARC_DOWNLOAD_REMOVED).has_value(); }));
  {
    base::ScopedAllowBlockingForTesting allow_fixture_check;
    EXPECT_TRUE(base::PathExists(base::FilePath(item.target))); // History removal never trashes a file.
  }
  EXPECT_EQ(0u, barc_download_copy_safe_target(final.token, replayed.manager, replayed.guid.c_str(), nullptr, 0));
  barc_downloads_unobserve(final.token);
  barc::StopBrowserDiscovery();
  EXPECT_EQ(0u, barc_downloads_observe(NativeDownloadEvents::Receive, &stopped));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       ProfilesShareNativeWindowAndRetainLivePage) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  auto* work_contents = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(work_contents));
  EXPECT_EQ(true, content::EvalJs(
                      work_contents,
                      "customElements.whenDefined('settings-ui').then(() => "
                      "!!document.querySelector('settings-ui').shadowRoot."
                      "querySelector('settings-main'))"));
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  const int32_t work_peer_id =
      Open(kSharedWork, work_id, BARC_PROFILE_EXTENSIONS);
  auto* work_peer = SharedWindow(work_peer_id);
  ASSERT_TRUE(work_peer);
  auto* view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  auto* peer_view = BrowserView::GetBrowserViewForBrowser(work_peer);
  auto* host = view->browser_widget();
  const auto native_window = host->GetNativeWindow();
  auto* work_frame = view->parent();
  EXPECT_EQ(host, personal_view->browser_widget());
  EXPECT_EQ(host, peer_view->browser_widget());
  EXPECT_EQ(native_window, personal->GetWindow()->GetNativeWindow());
  EXPECT_EQ(native_window, work_peer->GetWindow()->GetNativeWindow());
  EXPECT_NE(work->GetProfile(), personal->GetProfile());
  EXPECT_EQ(work->GetProfile(), work_peer->GetProfile());
  EXPECT_NE(view, personal_view);
  EXPECT_NE(view->parent(), personal_view->parent());
  work->GetProfile()->GetPrefs()->SetBoolean(prefs::kShowHomeButton, true);
  personal->GetProfile()->GetPrefs()->SetBoolean(prefs::kShowHomeButton, false);
  auto* personal_contents =
      personal->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(personal_contents));
  EXPECT_EQ(false,
            content::EvalJs(personal_contents,
                            "new "
                            "Promise(r=>chrome.settingsPrivate.getPref('"
                            "browser.show_home_button',p=>r(p.value)))"));
  auto* extensions = work_peer->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(extensions));
  EXPECT_EQ("object",
            content::EvalJs(extensions, "typeof chrome.developerPrivate"));
  EXPECT_EQ(work->GetProfile(), extensions->GetBrowserContext());
  ASSERT_NO_FATAL_FAILURE(
      Navigate(work, embedded_test_server()->GetURL("/title1.html")));
  ASSERT_EQ(1, barc_window_select(work_id));
  ASSERT_TRUE(content::ExecJs(
      work_contents,
      "window.nativeMarker='original'; document.body.innerHTML='<input "
      "id=draft>';"
      "draft.value='retained form'; document.body.style.height='6000px';"
      "history.pushState({kept:true},'', '#kept'); window.scrollTo(0,1200);"));
  const int history_count = work_contents->GetController().GetEntryCount();
  ASSERT_EQ(1200, content::EvalJs(work_contents, "scrollY"));
  for (int i = 0; i < 3; ++i) {
    ASSERT_EQ(1, barc_window_select(personal_id));
    EXPECT_EQ(personal,
              GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                  native_window));
    ASSERT_TRUE(base::test::RunUntil([&] {
      return content::EvalJs(personal_contents, "document.visibilityState")
                 .ExtractString() == "visible";
    }));
    ASSERT_TRUE(base::test::RunUntil([&] {
      return content::EvalJs(work_contents, "document.visibilityState")
                 .ExtractString() == "hidden";
    }));
    ASSERT_EQ(1, barc_window_select(work_id));
    EXPECT_EQ(work,
              GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                  native_window));
    ASSERT_TRUE(base::test::RunUntil([&] {
      return content::EvalJs(work_contents, "document.visibilityState")
                 .ExtractString() == "visible";
    }));
    EXPECT_EQ(work_contents, work->GetTabStripModel()->GetActiveWebContents());
    EXPECT_EQ(work_frame, view->parent());
    EXPECT_EQ(host, view->GetWidget());
    EXPECT_EQ("original", content::EvalJs(work_contents, "nativeMarker"));
    EXPECT_EQ("retained form", content::EvalJs(work_contents, "draft.value"));
    EXPECT_EQ(1200, content::EvalJs(work_contents, "scrollY"));
    EXPECT_EQ(history_count, work_contents->GetController().GetEntryCount());
  }
  host->Deactivate();
  EXPECT_EQ(work, GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                      native_window));
  host->Hide();
  EXPECT_EQ(work, GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                      native_window));
  ASSERT_EQ(1, barc_window_select(personal_id));
  EXPECT_EQ(personal,
            GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                native_window));
  host->Show();
  ASSERT_EQ(1, barc_tab_select(work_id, barc_window_tab_at(work_id, 0)));
  EXPECT_TRUE(work->IsSelectedForNativeWindow());
  EXPECT_FALSE(personal->IsSelectedForNativeWindow());
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       InactiveOwnerCloseTransfersPhysicalLifetime) {
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  ASSERT_TRUE(work_view);
  ASSERT_TRUE(personal_view);
  EXPECT_EQ(work_view->GetWidget(), personal_view->GetWidget());
  for (auto* view : {work_view, personal_view}) {
    auto* combo = views::AsViewClass<TabStripComboButton>(
        view->tab_strip_view()->GetViewByElementId(
            kTabStripComboButtonElementId));
    ASSERT_TRUE(combo);
    auto* bubble_host = view->GetTabSearchBubbleHost();
    ASSERT_TRUE(bubble_host);
    EXPECT_EQ(view->browser(), bubble_host->GetBrowser());
    ASSERT_TRUE(view->side_panel());
    EXPECT_TRUE(view->Contains(view->side_panel()));
    auto* anchor = view->GetFallbackPopupAnchor();
    ASSERT_TRUE(anchor);
    auto* subregion = anchor->AsA<views::ViewSubregionAnchor>();
    ASSERT_TRUE(subregion);
    EXPECT_EQ(view, &subregion->view());
    auto* menu_button = views::AsViewClass<AppMenuButton>(
        view->toolbar()->GetViewByElementId(kToolbarAppMenuButtonElementId));
    ASSERT_TRUE(menu_button);
    const bool was_visible = menu_button->GetVisible();
    menu_button->SetVisible(false);
    EXPECT_FALSE(menu_button->IsDrawn());
    EXPECT_EQ(anchor, menu_button->GetAnchor().GetIfElement());
    menu_button->SetVisible(was_visible);
    EXPECT_TRUE(combo->Contains(bubble_host->button()));
    EXPECT_TRUE(view->Contains(bubble_host->button()));
    auto* other_view = view == work_view ? personal_view : work_view;
    EXPECT_FALSE(other_view->Contains(bubble_host->button()));
    EXPECT_NE(bubble_host, other_view->GetTabSearchBubbleHost());
  }
  auto* host = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  auto* work_contents = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(work_contents);
  // Exercise retained inactive contents that still resolve to the shared host,
  // whose native metadata identifies the selected Personal BrowserView.
  ASSERT_EQ(host, views::Widget::GetTopLevelWidgetForNativeView(
                      work_contents->GetNativeView()));
  ASSERT_EQ(personal_view, BrowserView::GetBrowserViewForNativeWindow(
                               host->GetNativeWindow()));
  EXPECT_EQ(work_view,
            BrowserWindow::FindBrowserWindowWithWebContents(work_contents));
  EXPECT_EQ(personal_view, BrowserWindow::FindBrowserWindowWithWebContents(
                               personal->GetTabStripModel()
                                   ->GetActiveWebContents()));
  auto host_alive = host->GetWeakPtr();
  const auto native_window = host->GetNativeWindow();
  auto* contents = personal->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  ASSERT_TRUE(content::ExecJs(contents, "window.ownerSurvivor='live';"));
  ui_test_utils::BrowserDestroyedObserver work_closed(work);
  ASSERT_EQ(1, barc_window_close(work_id));
  work_closed.Wait();
  ASSERT_TRUE(host_alive);
  EXPECT_EQ(personal,
            GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                native_window));
  EXPECT_EQ("live", content::EvalJs(contents, "ownerSurvivor"));
  EXPECT_EQ(0, barc_window_select(work_id));
  ui_test_utils::BrowserDestroyedObserver personal_closed(personal);
  ASSERT_EQ(1, barc_window_close(personal_id));
  personal_closed.Wait();
  EXPECT_FALSE(host_alive);
  EXPECT_EQ(0, barc_window_close(personal_id));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       ForcedNativeCloseDestroysEveryLogicalBrowser) {
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  auto work_alive = work->GetWeakPtr();
  auto personal_alive = personal->GetWeakPtr();
  auto* host = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  auto host_alive = host->GetWeakPtr();
  NavigationEvents work_events, personal_events;
  ASSERT_NE(0u, barc_tab_observe(work_id, barc_window_tab_at(work_id, 0),
                               NavigationEvents::Receive, &work_events));
  ASSERT_NE(0u, barc_tab_observe(personal_id, barc_window_tab_at(personal_id, 0),
                               NavigationEvents::Receive, &personal_events));
  work_events.on_closed = base::BindLambdaForTesting([&] {
    if (personal_alive) {
      EXPECT_TRUE(UnloadController::From(personal_alive.get())->owner_close_admitted());
      EXPECT_EQ(personal_alive->GetTabStripModel()->count(),
                static_cast<int>(barc_window_tab_count(personal_id)));
    }
  });
  ui_test_utils::BrowserDestroyedObserver work_closed(work);
  ui_test_utils::BrowserDestroyedObserver personal_closed(personal);
  host->CloseNow();
  for (const auto* events : {&work_events, &personal_events}) {
    ASSERT_EQ(1u, events->Count(BARC_TAB_CLOSED));
    const auto terminal = std::find_if(events->events.begin(), events->events.end(),
        [](const auto& event) { return event.kind == BARC_TAB_CLOSED; });
    EXPECT_TRUE(terminal->flags & BARC_TAB_OWNER_ENDED);
  }
  work_closed.Wait();
  personal_closed.Wait();
  EXPECT_FALSE(work_alive);
  EXPECT_FALSE(personal_alive);
  EXPECT_FALSE(host_alive);
  EXPECT_EQ(nullptr, SharedWindow(work_id));
  EXPECT_EQ(nullptr, SharedWindow(personal_id));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       PromptFreePhysicalCloseDoesNotActivateOtherProfiles) {
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  int intermediate_activations = 0;
  auto count = base::BindLambdaForTesting(
      [&](BrowserWindowInterface*) { ++intermediate_activations; });
  auto first =
      BrowserActiveStateManager::From(work)->RegisterDidBecomeActive(count);
  auto second =
      BrowserActiveStateManager::From(personal)->RegisterDidBecomeActive(count);
  auto* host = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  ui_test_utils::BrowserDestroyedObserver work_closed(work);
  ui_test_utils::BrowserDestroyedObserver personal_closed(personal);
  host->Close();
  work_closed.Wait();
  personal_closed.Wait();
  EXPECT_EQ(0, intermediate_activations);
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       TabSelectionRespectsCallbackDrivenProfileChange) {
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  const int32_t target_tab = barc_tab_create(work_id, "about:blank", 0);
  ASSERT_NE(0, target_tab);
  RedirectNativeSelection redirect(work->GetTabStripModel(), personal_id);
  redirect.Arm();
  EXPECT_EQ(0, barc_tab_select(work_id, target_tab));
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
}

namespace {
class ConstructionSessionService : public SessionService {
 public:
  explicit ConstructionSessionService(Profile* profile)
      : SessionService(profile) {}
  void WindowOpened(BrowserWindowInterface* window) override {
    ++opened;
    SessionService::WindowOpened(window);
  }
  void WindowClosed(SessionID window) override {
    ++closed;
    SessionService::WindowClosed(window);
  }
  int opened = 0;
  int closed = 0;
};

class CandidateCreationEvents : public BrowserCollectionObserver {
 public:
  CandidateCreationEvents() {
    observation_.Observe(GlobalBrowserCollection::GetInstance());
  }
  void SetCandidate(int32_t id) { candidate_ = id; }
  void OnBrowserCreated(BrowserWindowInterface* window) override {
    if (window->GetSessionID().id() == candidate_) {
      ++created;
    }
  }
  void OnBrowserClosed(BrowserWindowInterface* window) override {
    if (window->GetSessionID().id() == candidate_) {
      ++closed;
    }
  }
  int created = 0;
  int closed = 0;

 private:
  int32_t candidate_ = 0;
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver>
      observation_{this};
};
}  // namespace

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       FeatureInitHostClosureAbortsUnpublishedBrowser) {
  const int32_t host_id = Open(kSharedWork);
  auto* host = SharedWindow(host_id);
  ASSERT_TRUE(host);
  auto host_alive = host->GetWeakPtr();
  const size_t browsers_before =
      GlobalBrowserCollection::GetInstance()->GetSize();
  auto* manager = g_browser_process->profile_manager();
  base::test::TestFuture<Profile*> initialized;
  manager->CreateProfileAsync(manager->user_data_dir().AppendASCII(
                                  std::string("Barc-") + kSharedPersonal),
                              initialized.GetCallback());
  auto* profile = initialized.Get();
  ASSERT_TRUE(profile);
  auto profile_alive = ScopedProfileKeepAlive::TryAcquire(
      profile, ProfileKeepAliveOrigin::kProfileCreationFlow);
  ASSERT_TRUE(profile_alive);
  auto* sessions =
      SessionServiceFactory::GetInstance()
          ->SetTestingSubclassFactoryAndUse<ConstructionSessionService>(
              profile, base::BindOnce([](content::BrowserContext* context) {
                return std::make_unique<ConstructionSessionService>(
                    Profile::FromBrowserContext(context));
              }));
  ASSERT_TRUE(sessions);
  CandidateCreationEvents events;
  base::WeakPtr<BrowserWindowInterface> candidate_alive;
  int32_t candidate_id = 0;
  bool closed_in_factory = false;
  auto feature_override =
      BrowserWindowFeatures::GetUserDataFactoryForTesting()
          .AddOverrideForTesting<EmbedderBrowserWindowFeatures>(
              base::BindLambdaForTesting(
                  [&](BrowserWindowInterface& candidate) {
                    const auto& params =
                        BrowserInitState::From(&candidate)->create_params();
                    if (params.native_window_owner &&
                        params.native_window_owner->id() == host_id &&
                        !closed_in_factory) {
                      closed_in_factory = true;
                      candidate_id = candidate.GetSessionID().id();
                      candidate_alive = candidate.GetWeakPtr();
                      events.SetCandidate(candidate_id);
                      // Existing production feature factory callout, not a
                      // custom or test-only BrowserWindow. The host dies before
                      // factory admission.
                      BrowserManagerService::SynchronouslyDestroyBrowser(
                          host_alive.get());
                    }
                    return std::make_unique<EmbedderBrowserWindowFeatures>(
                        &candidate);
                  }));
  SharedProfileResult result;
  barc_profile_open_in_native_window(host_id, kSharedPersonal,
                                     BARC_PROFILE_SETTINGS,
                                     SharedProfileCompleted, &result);
  EXPECT_EQ(BARC_PROFILE_UNAVAILABLE, result.Get<0>());
  EXPECT_EQ(0, result.Get<1>());
  EXPECT_TRUE(closed_in_factory);
  EXPECT_FALSE(host_alive);
  EXPECT_FALSE(candidate_alive);
  EXPECT_GT(candidate_id, 0);
  EXPECT_EQ(nullptr, SharedWindow(candidate_id));
  EXPECT_EQ(0, events.created);
  EXPECT_EQ(0, events.closed);
  EXPECT_EQ(0, sessions->opened);
  EXPECT_EQ(0, sessions->closed);
  EXPECT_EQ(browsers_before - 1,
            GlobalBrowserCollection::GetInstance()->GetSize());
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       GroupedBeforeUnloadCancellationRetainsEveryDocument) {
  const int32_t work_id = Open(kSharedWork);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  ASSERT_TRUE(embedded_test_server()->Start());
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work);
  ASSERT_TRUE(personal);
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  Navigate(personal, embedded_test_server()->GetURL("/title2.html"));
  auto work_alive = work->GetWeakPtr();
  auto personal_alive = personal->GetWeakPtr();
  auto* host = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  auto host_alive = host->GetWeakPtr();
  std::array<content::WebContents*, 2> pages{
      work->GetTabStripModel()->GetActiveWebContents(),
      personal->GetTabStripModel()->GetActiveWebContents()};
  for (auto* page : pages) {
    ASSERT_TRUE(
        content::ExecJs(page, "document.body.innerHTML = '<input id=draft>';"
                              "draft.value = 'unsaved'; window.liveMarker = {};"
                              "onbeforeunload = () => 'keep draft';"));
    content::PrepContentsForBeforeUnloadTest(page);
  }
  NavigationEvents work_events, personal_events;
  ASSERT_NE(0u, barc_tab_observe(work_id, barc_window_tab_at(work_id, 0),
                                NavigationEvents::Receive, &work_events));
  ASSERT_NE(0u, barc_tab_observe(personal_id, barc_window_tab_at(personal_id, 0),
                                NavigationEvents::Receive, &personal_events));
  bool cancelled_application_quit = false;
  auto quit_observation = chrome::AddClosingAllBrowsersCallback(
      base::BindLambdaForTesting([&](bool closing) {
        cancelled_application_quit |= !closing;
      }));
  host->Close();
  auto* first = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(first->is_before_unload_dialog());
  EXPECT_EQ(0u, work_events.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(0u, personal_events.Count(BARC_TAB_CLOSE_CANCELLED));
  auto* first_page = first->web_contents();
  ASSERT_TRUE(first_page == pages[0] || first_page == pages[1]);
  EXPECT_TRUE((first_page == pages[0] ? work : personal)
                  ->IsSelectedForNativeWindow());
  first->view()->AcceptAppModalDialog();
  auto* second = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(second->is_before_unload_dialog());
  ASSERT_TRUE(second->web_contents() == pages[0] ||
              second->web_contents() == pages[1]);
  EXPECT_NE(first_page, second->web_contents());
  EXPECT_TRUE((second->web_contents() == pages[0] ? work : personal)
                  ->IsSelectedForNativeWindow());
  second->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return work_alive && personal_alive &&
           !UnloadController::From(work_alive.get())
                ->is_attempting_to_close_browser() &&
           !UnloadController::From(personal_alive.get())
                ->is_attempting_to_close_browser();
  }));
  EXPECT_FALSE(cancelled_application_quit);
  EXPECT_EQ(1u, work_events.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(1u, personal_events.Count(BARC_TAB_CLOSE_CANCELLED));

  EXPECT_EQ(0u, work_events.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(0u, personal_events.Count(BARC_TAB_CLOSED));
  const size_t work_titles = work_events.Count(BARC_TAB_TITLE);
  const size_t personal_titles = personal_events.Count(BARC_TAB_TITLE);
  ASSERT_TRUE(content::ExecJs(pages[0], "document.title='Work stays live'"));
  ASSERT_TRUE(content::ExecJs(pages[1], "document.title='Personal stays live'"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return work_events.Count(BARC_TAB_TITLE) > work_titles &&
           personal_events.Count(BARC_TAB_TITLE) > personal_titles;
  }));

  ASSERT_TRUE(host_alive);
  EXPECT_EQ(host, BrowserView::GetBrowserViewForBrowser(work_alive.get())
                      ->browser_widget());
  EXPECT_EQ(host, BrowserView::GetBrowserViewForBrowser(personal_alive.get())
                      ->browser_widget());
  EXPECT_EQ(pages[0], work_alive->GetTabStripModel()->GetActiveWebContents());
  EXPECT_EQ(pages[1],
            personal_alive->GetTabStripModel()->GetActiveWebContents());
  for (auto* page : pages) {
    EXPECT_EQ("unsaved", content::EvalJs(page, "draft.value"));
    EXPECT_EQ("object", content::EvalJs(page, "typeof liveMarker"));
    ASSERT_TRUE(content::ExecJs(page, "onbeforeunload = null;"));
  }
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       ProfileClosePreemptsPendingLocalDownloadWarning) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      &content::SlowDownloadHttpResponse::HandleSlowDownloadRequest));
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  auto work_alive = work->GetWeakPtr();
  Profile* otr_profile = work->GetProfile()->GetPrimaryOTRProfile(true);
  BrowserWindowCreateParams params(otr_profile, true);
  params.native_window_owner = work->GetSessionID();
  auto* otr = CreateBrowserWindow(std::move(params));
  ASSERT_TRUE(otr);
  auto otr_alive = otr->GetWeakPtr();
  const int32_t otr_id = otr->GetSessionID().id();
  ASSERT_NE(0, barc_tab_create(otr_id, "about:blank", 1));
  Navigate(otr, embedded_test_server()->GetURL("/title1.html"));
  auto* page = otr->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(
      page,
      "document.body.innerHTML = '<input id=draft>'; draft.value='unsaved';"
      "onbeforeunload = () => 'keep draft';"));
  content::PrepContentsForBeforeUnloadTest(page);
  const auto otr_path = otr_profile->GetPath();
  auto otr_profile_alive = otr_profile->GetWeakPtr();
  auto* manager = otr_profile->GetDownloadManager();
  // Initialize the OTR default before overriding it for this warning fixture.
  auto* download_prefs = DownloadPrefs::FromDownloadManager(manager);
  otr_profile->GetPrefs()->SetBoolean(prefs::kPromptForDownload, false);
  ASSERT_EQ(otr_profile, manager->GetBrowserContext());
  ASSERT_FALSE(otr_profile->GetPrefs()->GetBoolean(prefs::kPromptForDownload));
  ASSERT_FALSE(download_prefs->PromptForDownload());
  base::ScopedClosureRunner cleanup(
      base::BindLambdaForTesting([otr_profile_alive] {
        if (!otr_profile_alive) {
          return;
        }
        content::DownloadManager::DownloadVector items;
        otr_profile_alive->GetDownloadManager()->GetAllDownloads(&items);
        for (const auto& item : items) {
          item->Cancel(/*user_cancel=*/true);
        }
      }));
  content::DownloadTestObserverInProgress progress(manager, 1);
  ASSERT_NE(0,
            barc_tab_create(
                otr_id,
                embedded_test_server()
                    ->GetURL(content::SlowDownloadHttpResponse::kKnownSizeUrl)
                    .spec()
                    .c_str(),
                0));
  progress.WaitForFinished();
  content::DownloadManager::DownloadVector initial_downloads;
  manager->GetAllDownloads(&initial_downloads);
  ASSERT_EQ(1u, initial_downloads.size());
  const std::string download_guid = initial_downloads.front()->GetGuid();
  auto* host = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  ASSERT_EQ(host, BrowserView::GetBrowserViewForBrowser(otr)->browser_widget());
  auto children_before =
      views::Widget::GetAllOwnedWidgets(host->GetNativeView());
  host->Close();
  base::WeakPtr<views::Widget> warning;
  ASSERT_TRUE(base::test::RunUntil([&] {
    for (const auto& child :
         views::Widget::GetAllOwnedWidgets(host->GetNativeView())) {
      if (!children_before.contains(child) && child->IsVisible() &&
          views::AsViewClass<DownloadInProgressDialogView>(child->GetClientContentsView())) {
        warning = child->GetWeakPtr();
        return true;
      }
    }
    return false;
  }));
  base::test::TestFuture<base::FilePath> aborted;
  chrome::CloseAllBrowsersWithProfile(
      otr_profile, false, base::NullCallback(),
      aborted.GetRepeatingCallback<const base::FilePath&>());
  // The replacement owner must dismiss only its stale download warning, before
  // its beforeunload prompt can own the same physical modal anchor.
  EXPECT_TRUE(
      base::test::RunUntil([&] { return !warning || !warning->IsVisible(); }));
  // Keep a failing cancellation regression clean enough to finish, rather than
  // leaving the old modal blocking the profile-close cancellation below.
  if (warning && warning->IsVisible()) {
    warning->Close();
  }
  auto* dialog = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(dialog->is_before_unload_dialog());
  dialog->view()->CancelAppModalDialog();
  EXPECT_EQ(otr_path, aborted.Get());
  ASSERT_TRUE(work_alive);
  ASSERT_TRUE(otr_alive);
  EXPECT_EQ(page, otr_alive->GetTabStripModel()->GetWebContentsAt(0));
  EXPECT_EQ("unsaved", content::EvalJs(page, "draft.value"));
  EXPECT_FALSE(UnloadController::From(otr_alive.get())
                   ->is_attempting_to_close_browser());
  ASSERT_TRUE(otr_profile_alive);
  content::DownloadManager::DownloadVector remaining_downloads;
  otr_profile_alive->GetDownloadManager()->GetAllDownloads(
      &remaining_downloads);
  ASSERT_EQ(1u, remaining_downloads.size());
  EXPECT_EQ(download_guid, remaining_downloads.front()->GetGuid());
  EXPECT_EQ(download::DownloadItem::IN_PROGRESS,
            remaining_downloads.front()->GetState());
  NavigationEvents wait_work, wait_otr;
  ASSERT_NE(0u, barc_tab_observe(work_id, barc_window_tab_at(work_id, 0),
                                NavigationEvents::Receive, &wait_work));
  ASSERT_NE(0u, barc_tab_observe(otr_id, barc_window_tab_at(otr_id, 0),
                                NavigationEvents::Receive, &wait_otr));
  // A second local group accepts its download warning. Preempt at its actual
  // dismissal, while accepted continuation is still pending, not by a timer.
  content::PrepContentsForBeforeUnloadTest(page);
  host->Close();
  ASSERT_TRUE(base::test::RunUntil([&] {
    for (const auto& child : views::Widget::GetAllOwnedWidgets(host->GetNativeView())) {
      if (child->IsVisible() && views::AsViewClass<DownloadInProgressDialogView>(
                                    child->GetClientContentsView())) {
        warning = child->GetWeakPtr();
        return true;
      }
    }
    return false;
  }));
  base::test::TestFuture<base::FilePath> second_aborted;
  bool preempted_during_wait = false;
  PreemptOnDownloadWarningDismissal preempt_on_dismissal(
      warning.get(), base::BindLambdaForTesting([&] {
        preempted_during_wait = true;
        EXPECT_TRUE(host->HasPhysicalClosePending());
        EXPECT_FALSE(host->IsPhysicalCloseCommitted());
        ASSERT_TRUE(otr_profile_alive);
        chrome::CloseAllBrowsersWithProfile(
            otr_profile_alive.get(), false, base::NullCallback(),
            second_aborted.GetRepeatingCallback<const base::FilePath&>());
      }));
  warning->widget_delegate()->AsDialogDelegate()->AcceptDialog();
  auto* second_dialog = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(second_dialog->is_before_unload_dialog());
  EXPECT_TRUE(preempted_during_wait);
  EXPECT_EQ(page, second_dialog->web_contents());
  // Local group cancellation is complete before the replacement profile-family
  // close is refused. That later abort resets both regular and OTR controllers.
  EXPECT_EQ(1u, wait_work.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(1u, wait_otr.Count(BARC_TAB_CLOSE_CANCELLED));
  second_dialog->view()->CancelAppModalDialog();
  EXPECT_EQ(otr_path, second_aborted.Get());
  ASSERT_TRUE(work_alive);
  ASSERT_TRUE(otr_alive);
  EXPECT_FALSE(host->HasPhysicalClosePending());
  EXPECT_EQ(2u, wait_work.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(2u, wait_otr.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(0u, wait_work.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(0u, wait_otr.Count(BARC_TAB_CLOSED));
  base::RunLoop().RunUntilIdle();
  EXPECT_FALSE(host->HasPhysicalClosePending());
  EXPECT_EQ(2u, wait_work.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(2u, wait_otr.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(0u, wait_work.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(0u, wait_otr.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(page, otr_alive->GetTabStripModel()->GetWebContentsAt(0));
  EXPECT_EQ("unsaved", content::EvalJs(page, "draft.value"));
  ASSERT_TRUE(content::ExecJs(page, "onbeforeunload = null;"));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       RendererFailurePreservesOtherProfileDocument) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  const GURL work_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_NO_FATAL_FAILURE(Navigate(work, work_url));
  ASSERT_NO_FATAL_FAILURE(
      Navigate(personal, embedded_test_server()->GetURL("/title2.html")));
  auto* work_contents = work->GetTabStripModel()->GetActiveWebContents();
  auto* personal_contents = personal->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(work_contents);
  ASSERT_TRUE(personal_contents);
  auto* personal_process = personal_contents->GetPrimaryMainFrame()->GetProcess();
  auto* work_process = work_contents->GetPrimaryMainFrame()->GetProcess();
  ASSERT_NE(work_process, personal_process);
  ASSERT_NE(work_process->GetProcess().Pid(),
            personal_process->GetProcess().Pid());
  const auto personal_pid = personal_process->GetProcess().Pid();
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  ASSERT_TRUE(work_view);
  ASSERT_TRUE(personal_view);
  auto* host = work_view->GetWidget();
  ASSERT_EQ(host, personal_view->GetWidget());
  const auto native_window = host->GetNativeWindow();
  ASSERT_NE(work->GetProfile(), personal->GetProfile());
  ASSERT_TRUE(personal->IsSelectedForNativeWindow());
  ASSERT_FALSE(work->IsSelectedForNativeWindow());
  ASSERT_TRUE(content::ExecJs(personal_contents, R"JS(
    document.body.innerHTML = '<input id="draft">';
    document.getElementById('draft').value = 'unsaved-personal';
    window.personalProbe = (() => {
      const state = {count: 7};
      const originalBody = document.body;
      return () => [++state.count, originalBody === document.body,
                    document.getElementById('draft').value];
    })();
  )JS"));
  {
    content::ScopedAllowRendererCrashes allow_expected_crash(work_process);
    // Upstream helper targets only this process, waits for its exit, asserts
    // abnormal termination, and verifies WebContents::IsCrashed().
    content::CrashTab(work_contents);
  }
  ASSERT_TRUE(work_contents->IsCrashed());
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
  EXPECT_FALSE(work_contents->GetPrimaryMainFrame()->IsRenderFrameLive());
  EXPECT_FALSE(personal_contents->IsCrashed());
  EXPECT_EQ("[8,true,\"unsaved-personal\"]",
            content::EvalJs(personal_contents, "JSON.stringify(personalProbe())"));
  EXPECT_EQ(personal_process,
            personal_contents->GetPrimaryMainFrame()->GetProcess());
  EXPECT_EQ(personal_pid, personal_process->GetProcess().Pid());
  EXPECT_EQ(work_view, BrowserView::GetBrowserViewForBrowser(work));
  EXPECT_EQ(personal_view, BrowserView::GetBrowserViewForBrowser(personal));
  EXPECT_EQ(host, work_view->GetWidget());
  EXPECT_EQ(host, personal_view->GetWidget());
  EXPECT_EQ(native_window, personal->GetWindow()->GetNativeWindow());
  EXPECT_EQ(personal, GlobalBrowserCollection::GetInstance()
                          ->FindBrowserWithWindow(native_window));
  // The existing bridge has navigation, not a dedicated Reload entry point.
  // Recover the crashed tab by loading its same committed URL through it.
  ASSERT_NO_FATAL_FAILURE(Navigate(work, work_url));
  EXPECT_FALSE(work_contents->IsCrashed());
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
  EXPECT_TRUE(work_contents->GetPrimaryMainFrame()->IsRenderFrameLive());
  EXPECT_EQ("This page has no title.",
            content::EvalJs(work_contents, "document.body.textContent.trim()"));
  EXPECT_EQ("[9,true,\"unsaved-personal\"]",
            content::EvalJs(personal_contents, "JSON.stringify(personalProbe())"));
  EXPECT_EQ(personal_process,
            personal_contents->GetPrimaryMainFrame()->GetProcess());
  EXPECT_EQ(personal_pid, personal_process->GetProcess().Pid());
  EXPECT_EQ(personal->GetProfile(), personal_contents->GetBrowserContext());
  EXPECT_EQ(work->GetProfile(), work_contents->GetBrowserContext());
  EXPECT_EQ(host, BrowserView::GetBrowserViewForBrowser(work)->GetWidget());
  EXPECT_EQ(host, BrowserView::GetBrowserViewForBrowser(personal)->GetWidget());
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       PopupOpenerSurvivesSameProfileLiveTransfer) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  const GURL url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_NO_FATAL_FAILURE(Navigate(work, url));
  auto* source = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_EQ(1, barc_window_select(personal_id));
  ASSERT_TRUE(personal->IsSelectedForNativeWindow());
  ASSERT_FALSE(work->IsSelectedForNativeWindow());
  ASSERT_TRUE(content::ExecJs(source, R"JS(
    window.addEventListener('message', e => {
      if (e.origin === location.origin && e.source === window.openedPopup &&
          e.data === 'reverse') e.source.postMessage('reverse-ack', e.origin);
    });
  )JS"));
  BrowserWindowInterface* popup_browser = nullptr;
  content::WebContents* popup = nullptr;
  {
    ui_test_utils::BrowserCreatedObserver popup_created;
    content::WebContentsAddedObserver popup_contents_added;
    // ExecJs defaults to a normal test user gesture; no popup/security bypass.
    ASSERT_TRUE(content::ExecJs(source, content::JsReplace(
        "window.openedPopup = window.open($1, 'barc-popup', 'popup,width=400,height=300');"
        "if (!openedPopup) throw Error('popup blocked');", url)));
    popup_browser = popup_created.Wait();
    popup = popup_contents_added.GetWebContents();
  }
  ASSERT_TRUE(popup_browser);
  ASSERT_TRUE(popup);
  ASSERT_EQ(popup, popup_browser->GetTabStripModel()->GetActiveWebContents());
  ASSERT_TRUE(content::WaitForLoadStop(popup));
  ASSERT_EQ(url, popup->GetLastCommittedURL());
  EXPECT_EQ(work->GetProfile(), popup_browser->GetProfile());
  EXPECT_EQ(work->GetProfile(), popup->GetBrowserContext());
  EXPECT_NE(personal->GetProfile(), popup->GetBrowserContext());
  const auto shared_native = work->GetWindow()->GetNativeWindow();
  EXPECT_NE(shared_native, popup_browser->GetWindow()->GetNativeWindow());
  ASSERT_TRUE(content::ExecJs(popup, R"JS(
    if (!window.opener) throw Error('missing JS opener');
    document.body.innerHTML = '<input id="draft">';
    document.getElementById('draft').value = 'unsaved-popup';
    window.liveProbe = (() => {
      let count = 10;
      const body = document.body;
      return () => [++count, body === document.body,
                    document.getElementById('draft').value];
    })();
    window.addEventListener('message', e => {
      if (e.origin === location.origin && e.source === window.opener &&
          e.data === 'forward') e.source.postMessage('forward-ack', e.origin);
    });
  )JS"));
  auto exchange = [&] {
    EXPECT_EQ("forward-ack", content::EvalJs(source, R"JS(
      new Promise(resolve => {
        function onReply(e) {
          if (e.origin === location.origin && e.source === openedPopup &&
              e.data === 'forward-ack') {
            removeEventListener('message', onReply); resolve(e.data);
          }
        }
        addEventListener('message', onReply);
        openedPopup.postMessage('forward', location.origin);
      })
    )JS"));
    EXPECT_EQ("reverse-ack", content::EvalJs(popup, R"JS(
      new Promise(resolve => {
        function onReply(e) {
          if (e.origin === location.origin && e.source === opener &&
              e.data === 'reverse-ack') {
            removeEventListener('message', onReply); resolve(e.data);
          }
        }
        addEventListener('message', onReply);
        opener.postMessage('reverse', location.origin);
      })
    )JS"));
  };
  exchange();
  EXPECT_EQ("[11,true,\"unsaved-popup\"]",
            content::EvalJs(popup, "JSON.stringify(liveProbe())"));
  auto* original_frame = popup->GetPrimaryMainFrame();
  const int32_t popup_id = popup_browser->GetSessionID().id();
  const int32_t popup_tab = barc_window_tab_at(popup_id, 0);
  ASSERT_NE(0, popup_tab);
  const int32_t peer_id = barc_window_new_peer(popup_id);
  ASSERT_NE(0, peer_id);
  ui_test_utils::BrowserDestroyedObserver popup_closed(popup_browser);
  ASSERT_EQ(1, barc_tab_transfer(popup_id, popup_tab, peer_id));
  popup_closed.Wait();
  auto* peer = SharedWindow(peer_id);
  ASSERT_TRUE(peer);
  EXPECT_EQ(work->GetProfile(), peer->GetProfile());
  EXPECT_EQ(popup, peer->GetTabStripModel()->GetActiveWebContents());
  EXPECT_EQ(original_frame, popup->GetPrimaryMainFrame());
  EXPECT_EQ(popup_tab, barc_window_tab_at(peer_id, 0));
  exchange();
  EXPECT_EQ("[12,true,\"unsaved-popup\"]",
            content::EvalJs(popup, "JSON.stringify(liveProbe())"));
  // TabStripModel opener metadata may change at detach; JS opener must not.
  BrowserWindowInterface* noopener_browser = nullptr;
  content::WebContents* noopener = nullptr;
  {
    ui_test_utils::BrowserCreatedObserver noopener_created;
    content::WebContentsAddedObserver noopener_contents_added;
    EXPECT_EQ(true, content::EvalJs(source, content::JsReplace(
        "window.open($1, '_blank', 'noopener,popup,width=400,height=300') === null",
        url)));
    noopener_browser = noopener_created.Wait();
    noopener = noopener_contents_added.GetWebContents();
  }
  ASSERT_TRUE(noopener_browser);
  ASSERT_TRUE(noopener);
  ASSERT_TRUE(content::WaitForLoadStop(noopener));
  ASSERT_EQ(url, noopener->GetLastCommittedURL());
  EXPECT_EQ(work->GetProfile(), noopener_browser->GetProfile());
  EXPECT_EQ(work->GetProfile(), noopener->GetBrowserContext());
  EXPECT_EQ(true, content::EvalJs(noopener, "window.opener === null"));
  EXPECT_TRUE(SharedWindow(personal_id));
}


IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, NavigationCommandsAndEvents) {
  net::test_server::ControllableHttpResponse slow(embedded_test_server(), "/slow");
  ASSERT_TRUE(embedded_test_server()->Start());
  const auto window = browser()->GetSessionID().id();
  const auto tab = barc_window_tab_at(window, 0);
  auto* contents = browser()->tab_strip_model()->GetWebContentsAt(0);
  NavigationEvents observed;
  ASSERT_NE(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &observed));
  ASSERT_EQ(1u, observed.events.size());
  EXPECT_EQ(BARC_TAB_INITIAL, observed.events.front().kind);
  EXPECT_EQ(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &observed));
  const GURL first = embedded_test_server()->GetURL("/title1.html");
  const GURL second = embedded_test_server()->GetURL("/title2.html");
  ASSERT_EQ(1, barc_tab_navigate(window, tab, first.spec().c_str()));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  ASSERT_EQ(1, barc_tab_navigate(window, tab,
      embedded_test_server()->GetURL("/server-redirect?" + second.spec()).spec().c_str()));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_EQ(second, contents->GetLastCommittedURL());
  ASSERT_TRUE(base::test::RunUntil([&] { return observed.Count(BARC_TAB_FINISHED) == 2; }));
  EXPECT_EQ(second.spec(), observed.events.back().url);
  EXPECT_TRUE(observed.events.back().flags & BARC_TAB_BACK);
  ASSERT_EQ(1, barc_tab_go_back(window, tab));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_EQ(first, contents->GetLastCommittedURL());
  EXPECT_TRUE(observed.events.back().flags & BARC_TAB_FORWARD);
  ASSERT_EQ(1, barc_tab_go_forward(window, tab));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_EQ(second, contents->GetLastCommittedURL());
  const size_t before_reload = observed.events.size();
  ASSERT_EQ(1, barc_tab_reload(window, tab));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_TRUE(std::any_of(observed.events.begin() + before_reload,
                         observed.events.end(), [&](const auto& event) {
    return event.kind == BARC_TAB_FINISHED &&
           (event.flags & BARC_TAB_RELOAD) && event.url == second.spec() &&
           !(event.flags & BARC_TAB_LOADING);
  }));
  const size_t before_same_document = observed.events.size();
  const size_t starts_before_same_document = observed.Count(BARC_TAB_STARTED);
  const size_t finishes_before_same_document = observed.Count(BARC_TAB_FINISHED);
  ASSERT_TRUE(content::ExecJs(contents, "document.title='Observed title'; history.pushState({}, '', '#same')"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return std::any_of(observed.events.begin() + before_same_document,
                       observed.events.end(), [&](const auto& event) {
      return event.kind == BARC_TAB_COMMITTED &&
             (event.flags & BARC_TAB_SAME_DOCUMENT) &&
             event.url == second.spec() + "#same";
    });
  }));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return std::any_of(observed.events.begin() + before_same_document,
                       observed.events.end(), [](const auto& event) {
      return event.kind == BARC_TAB_TITLE && event.title == "Observed title";
    });
  }));
  EXPECT_EQ(starts_before_same_document, observed.Count(BARC_TAB_STARTED));
  EXPECT_EQ(finishes_before_same_document, observed.Count(BARC_TAB_FINISHED));
  ASSERT_EQ(1, barc_tab_navigate(window, tab,
      embedded_test_server()->GetURL("/slow").spec().c_str()));
  slow.WaitForRequest();
  ASSERT_EQ(1, barc_tab_stop(window, tab));
  ASSERT_TRUE(base::test::RunUntil([&] { return observed.Count(BARC_TAB_FAILED) == 1; }));
  const auto& failed = *std::find_if(observed.events.begin(), observed.events.end(),
      [](const auto& e) { return e.kind == BARC_TAB_FAILED; });
  EXPECT_TRUE(failed.flags & BARC_TAB_ABORTED);
  EXPECT_TRUE(failed.flags & BARC_TAB_PROVISIONAL);
  const size_t finished = observed.Count(BARC_TAB_FINISHED);
  slow.Done();
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(finished, observed.Count(BARC_TAB_FINISHED));
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, NavigationObserverLifetimeAndTransfer) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const auto window = browser()->GetSessionID().id();
  const auto tab = barc_window_tab_at(window, 0);
  NavigationEvents cancelled;
  cancelled.unsubscribe_initial = true;
  EXPECT_EQ(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &cancelled));
  auto self_releasing = std::make_unique<NavigationEvents>();
  self_releasing->release_owner = &self_releasing;
  EXPECT_EQ(0u, barc_tab_observe(window, tab, NavigationEvents::Receive,
                                self_releasing.get()));
  EXPECT_EQ(nullptr, self_releasing);
  NavigationEvents observed;
  ASSERT_NE(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &observed));
  const auto peer = barc_window_new_peer(window);
  ASSERT_GT(peer, 0);
  // Keep the source alive, independently of the moving observed tab.
  ASSERT_NE(0, barc_tab_create(window, "about:blank", 0));
  ASSERT_EQ(1, barc_tab_transfer(window, tab, peer));
  EXPECT_EQ(peer, observed.events.back().window);
  EXPECT_EQ(0, barc_tab_reload(window, tab));
  auto* owner = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(peer));
  ASSERT_NE(nullptr, owner);
  auto* contents = owner->GetTabStripModel()->GetWebContentsAt(0);
  observed.transfer_destination = window;
  ASSERT_EQ(1, barc_tab_navigate(peer, tab,
      embedded_test_server()->GetURL("/title1.html").spec().c_str()));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_TRUE(observed.transfer_refused);
  EXPECT_EQ(owner, tabs::TabHandle(tab).Get()->GetBrowserWindowInterface());
  EXPECT_EQ(1u, cancelled.events.size());
  EXPECT_EQ(peer, observed.events.back().window);
  barc_tab_unobserve(observed.token);
  const size_t count = observed.events.size();
  ASSERT_EQ(1, barc_tab_reload(peer, tab));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_EQ(count, observed.events.size());
  NavigationEvents closing;
  closing.close_started = true;
  ASSERT_NE(0u, barc_tab_observe(peer, tab, NavigationEvents::Receive, &closing));
  ASSERT_EQ(1, barc_tab_navigate(peer, tab,
      embedded_test_server()->GetURL("/title2.html").spec().c_str()));
  ASSERT_TRUE(base::test::RunUntil([&] { return closing.Count(BARC_TAB_CLOSED) == 1; }));
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1u, closing.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(BARC_TAB_CLOSED, closing.events.back().kind);
  auto* source_page = browser()->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(source_page, "window.unrelatedMarker = 'live'"));
  for (bool unsubscribe : {false, true}) {
    const auto close_window = barc_window_new_peer(window);
    const auto close_tab = barc_tab_create(close_window, "about:blank", 1);
    ASSERT_NE(0, close_tab);
    auto* close_owner = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
        SessionID::FromSerializedValue(close_window));
    ASSERT_NE(nullptr, close_owner);
    auto alive = close_owner->GetWeakPtr();
    ASSERT_TRUE(content::WaitForLoadStop(
        close_owner->GetTabStripModel()->GetActiveWebContents()));
    NavigationEvents window_closing;
    window_closing.close_window_started = true;
    window_closing.unsubscribe_before_close = unsubscribe;
    ASSERT_NE(0u, barc_tab_observe(close_window, close_tab,
                                  NavigationEvents::Receive, &window_closing));
    ASSERT_EQ(1, barc_tab_navigate(close_window, close_tab,
        embedded_test_server()->GetURL("/title2.html").spec().c_str()));
    ASSERT_TRUE(base::test::RunUntil([&] { return !alive; }));
    EXPECT_EQ(unsubscribe ? 0u : 1u, window_closing.Count(BARC_TAB_CLOSED));
    const size_t delivered = window_closing.events.size();
    base::RunLoop().RunUntilIdle();
    EXPECT_EQ(delivered, window_closing.events.size());
    EXPECT_EQ("live", content::EvalJs(source_page, "unrelatedMarker"));
  }

}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       NavigationBindingDuringLoadAndContentsReplacement) {
  net::test_server::ControllableHttpResponse pending(embedded_test_server(),
                                                    "/pending");
  net::test_server::ControllableHttpResponse superseded(embedded_test_server(),
                                                       "/superseded");
  net::test_server::ControllableHttpResponse tail(embedded_test_server(), "/tail");
  ASSERT_TRUE(embedded_test_server()->Start());
  const auto window = browser()->GetSessionID().id();
  const auto tab = barc_window_tab_at(window, 0);
  auto* contents = browser()->tab_strip_model()->GetWebContentsAt(0);
  ASSERT_EQ(1, barc_tab_navigate(window, tab,
      embedded_test_server()->GetURL("/pending").spec().c_str()));
  pending.WaitForRequest();
  NavigationEvents observed;
  ASSERT_NE(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &observed));
  EXPECT_TRUE(observed.events.front().flags & BARC_TAB_LOADING);
  pending.Send("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<title>Pending</title><img src='/tail'>");
  pending.Done();
  tail.WaitForRequest();
  const size_t before_same_document = observed.events.size();
  ASSERT_TRUE(content::ExecJs(contents, "history.pushState({}, '', '#during-load')"));
  EXPECT_TRUE(contents->IsLoading());
  EXPECT_EQ(0u, observed.Count(BARC_TAB_FINISHED));
  EXPECT_TRUE(std::any_of(observed.events.begin() + before_same_document,
                         observed.events.end(), [&](const auto& event) {
    return event.kind == BARC_TAB_COMMITTED &&
           (event.flags & BARC_TAB_SAME_DOCUMENT) &&
           (event.flags & BARC_TAB_LOADING) &&
           event.url == embedded_test_server()->GetURL("/pending#during-load").spec();
  }));
  barc_tab_unobserve(observed.token);
  ASSERT_NE(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &observed));
  EXPECT_EQ(BARC_TAB_INITIAL, observed.events.back().kind);
  EXPECT_TRUE(observed.events.back().flags & BARC_TAB_LOADING);
  tail.Send("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n");
  tail.Done();
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  ASSERT_EQ(0u, observed.Count(BARC_TAB_FINISHED));
  EXPECT_EQ(0u, observed.Count(BARC_TAB_STARTED));
  EXPECT_FALSE(observed.events.back().flags & BARC_TAB_LOADING);
  EXPECT_EQ(contents->GetVisibleURL().spec(), observed.events.back().url);
  ASSERT_EQ(1, barc_tab_navigate(window, tab,
      embedded_test_server()->GetURL("/superseded").spec().c_str()));
  superseded.WaitForRequest();
  ASSERT_EQ(1, barc_tab_navigate(window, tab,
      embedded_test_server()->GetURL("/title1.html").spec().c_str()));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  superseded.Done();
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(0u, observed.Count(BARC_TAB_FAILED));
  EXPECT_EQ(1u, observed.Count(BARC_TAB_FINISHED));
  // Discard is supported only in the background; the TabHandle survives while
  // observation leaves the old contents before their destruction.
  ASSERT_NE(0, barc_tab_create(window, "about:blank", 1));
  auto replacement = content::WebContents::Create(
      content::WebContents::CreateParams(browser()->GetProfile()));
  auto* new_contents = replacement.get();
  auto old = browser()->tab_strip_model()->DiscardWebContents(
      contents, std::move(replacement));
  old.reset();
  EXPECT_EQ(0u, observed.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(BARC_TAB_STATE, observed.events.back().kind);
  ASSERT_EQ(1, barc_tab_navigate(window, tab,
      embedded_test_server()->GetURL("/title2.html").spec().c_str()));
  ASSERT_TRUE(content::WaitForLoadStop(new_contents));
  EXPECT_EQ(2u, observed.Count(BARC_TAB_FINISHED));
  EXPECT_EQ("Title Of Awesomeness", observed.events.back().title);
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       TabCloseCancellationAllowsUnsubscribeAndRetry) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),
      embedded_test_server()->GetURL("/title1.html")));
  const int32_t window = browser()->GetSessionID().id();
  const int32_t tab = barc_window_tab_at(window, 0);
  auto* page = tabs::TabHandle(tab).Get()->GetContents();
  ASSERT_NE(0, barc_tab_create(window, "about:blank", 0));
  ASSERT_TRUE(content::ExecJs(page,
      "document.body.innerHTML='<input id=draft>'; draft.value='keep';"
      "onbeforeunload=()=> 'keep';"));
  content::PrepContentsForBeforeUnloadTest(page);
  NavigationEvents events;
  events.retry_cancelled = true;
  events.unsubscribe_cancelled = true;
  ASSERT_NE(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &events));
  content::WebContentsDestroyedWatcher destroyed(page);
  ASSERT_EQ(1, barc_tab_close(window, tab));
  auto* first = ui_test_utils::WaitForAppModalDialog();
  EXPECT_EQ(0u, events.Count(BARC_TAB_CLOSE_CANCELLED));
  first->view()->CancelAppModalDialog();
  auto* second = ui_test_utils::WaitForAppModalDialog();
  EXPECT_EQ(page, second->web_contents());
  EXPECT_EQ(1u, events.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(0u, events.Count(BARC_TAB_CLOSED));
  auto second_alive = second->GetWeakPtr();
  second->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !second_alive && events.Count(BARC_TAB_CLOSE_CANCELLED) == 2;
  }));
  EXPECT_EQ(page, tabs::TabHandle(tab).Get()->GetContents());
  EXPECT_EQ("keep", content::EvalJs(page, "draft.value"));
  ASSERT_TRUE(content::ExecJs(page, "onbeforeunload=null;"));
  barc_tab_unobserve(events.token);
  const size_t delivered = events.events.size();
  ASSERT_EQ(1, barc_tab_close(window, tab));
  destroyed.Wait();
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(nullptr, tabs::TabHandle(tab).Get());
  EXPECT_EQ(delivered, events.events.size());
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       WindowCloseCancellationFollowsTransferredObservation) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),
      embedded_test_server()->GetURL("/title1.html")));
  const int32_t source = browser()->GetSessionID().id();
  const int32_t tab = barc_window_tab_at(source, 0);
  auto* page = tabs::TabHandle(tab).Get()->GetContents();
  ASSERT_NE(0, barc_tab_create(source, "about:blank", 0));
  ASSERT_TRUE(content::ExecJs(page, "onbeforeunload=()=> 'keep';"));
  content::PrepContentsForBeforeUnloadTest(page);
  NavigationEvents events;
  ASSERT_NE(0u, barc_tab_observe(source, tab, NavigationEvents::Receive, &events));
  const int32_t peer = barc_window_new_peer(source);
  ASSERT_EQ(1, barc_tab_transfer(source, tab, peer));
  ASSERT_EQ(1, barc_window_close(peer));
  auto* dialog = ui_test_utils::WaitForAppModalDialog();
  EXPECT_EQ(0u, events.Count(BARC_TAB_CLOSE_CANCELLED));
  dialog->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return events.Count(BARC_TAB_CLOSE_CANCELLED) == 1;
  }));
  EXPECT_EQ(peer, events.events.back().window);
  EXPECT_EQ(0u, events.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(page, tabs::TabHandle(tab).Get()->GetContents());
  ASSERT_TRUE(content::ExecJs(page, "onbeforeunload=null;"));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       BlankConstructionWaitsForModelAdmission) {
  SharedProfileResult first;
  auto request = std::make_unique<ReleasedProfileRequest>();
  request->result = &first;
  request->owner = &request;
  barc_profile_open_window(kSharedWork, BARC_PROFILE_BLANK,
                           ReleasedProfileRequest::Completed, request.get());
  ASSERT_EQ(BARC_PROFILE_OK, first.Get<0>());
  EXPECT_EQ(nullptr, request);
  auto* work = SharedWindow(first.Get<1>());
  ASSERT_NE(nullptr, work);
  EXPECT_FALSE(work->GetWindow()->IsVisible());
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(page));
  EXPECT_EQ(GURL("about:blank"), page->GetLastCommittedURL());
  SharedProfileResult second;
  barc_profile_open_in_native_window(first.Get<1>(), kSharedPersonal,
      BARC_PROFILE_BLANK, SharedProfileCompleted, &second);
  ASSERT_EQ(BARC_PROFILE_OK, second.Get<0>());
  auto* personal = SharedWindow(second.Get<1>());
  ASSERT_NE(nullptr, personal);
  EXPECT_EQ(work->GetWindow()->GetNativeWindow(),
            personal->GetWindow()->GetNativeWindow());
  EXPECT_TRUE(work->IsSelectedForNativeWindow());
  EXPECT_FALSE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(personal->GetWindow()->IsVisible());
  NSView* shell = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
  ASSERT_EQ(1, barc_window_attach_native_shell(second.Get<1>(), (__bridge void*)shell));
  ASSERT_EQ(1, barc_window_select(second.Get<1>()));
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
  // The startup completion path uses this same normal Show only after caller
  // admission/attachment. This is a construction test, not native-focus proof.
  auto alive = personal->GetWeakPtr();
  ASSERT_EQ(1, barc_window_show(second.Get<1>()));
  EXPECT_EQ(0, barc_window_show(-1));
  ASSERT_TRUE(alive);
  EXPECT_TRUE(alive->GetWindow()->IsVisible());
  BarcReentrantNativeView* switching = [[BarcReentrantNativeView alloc] init];
  const int32_t work_id = first.Get<1>();
  switching.onMove = ^(NSView*) { EXPECT_EQ(1, barc_window_select(work_id)); };
  EXPECT_EQ(0, barc_window_attach_native_shell(second.Get<1>(),
                                               (__bridge void*)switching));
  EXPECT_TRUE(work->IsSelectedForNativeWindow());
  EXPECT_FALSE(personal->IsSelectedForNativeWindow());
  // Inactive detach remains supported and must not steal the newer selection.
  EXPECT_EQ(1, barc_window_attach_native_shell(second.Get<1>(), nullptr));
  EXPECT_TRUE(work->IsSelectedForNativeWindow());
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       DownloadWarningCancelsOnlyAfterRefusal) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      &content::SlowDownloadHttpResponse::HandleSlowDownloadRequest));
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_NE(nullptr, work);
  Profile* otr_profile = work->GetProfile()->GetPrimaryOTRProfile(true);
  auto profile_alive = otr_profile->GetWeakPtr();
  BrowserWindowCreateParams params(otr_profile, true);
  params.native_window_owner = work->GetSessionID();
  auto* otr = CreateBrowserWindow(std::move(params));
  ASSERT_NE(nullptr, otr);
  const int32_t otr_id = otr->GetSessionID().id();
  ASSERT_NE(0, barc_tab_create(otr_id, "about:blank", 1));
  auto* manager = otr_profile->GetDownloadManager();
  auto* prefs_for_download = DownloadPrefs::FromDownloadManager(manager);
  otr_profile->GetPrefs()->SetBoolean(prefs::kPromptForDownload, false);
  ASSERT_FALSE(prefs_for_download->PromptForDownload());
  base::ScopedClosureRunner cleanup(base::BindLambdaForTesting([profile_alive] {
    if (!profile_alive) return;
    content::DownloadManager::DownloadVector items;
    profile_alive->GetDownloadManager()->GetAllDownloads(&items);
    for (const auto& item : items) item->Cancel(true);
  }));
  content::DownloadTestObserverInProgress progress(manager, 1);
  ASSERT_NE(0, barc_tab_create(otr_id,
      embedded_test_server()->GetURL(content::SlowDownloadHttpResponse::kKnownSizeUrl)
          .spec().c_str(), 0));
  progress.WaitForFinished();
  std::vector<std::unique_ptr<NavigationEvents>> observations;
  std::vector<int32_t> observed_windows;
  std::vector<int32_t> observed_tabs;
  for (auto* owner : {work, otr}) {
    for (int index = 0; index < owner->GetTabStripModel()->count(); ++index) {
      auto events = std::make_unique<NavigationEvents>();
      ASSERT_NE(0u, barc_tab_observe(owner->GetSessionID().id(),
          owner->GetTabStripModel()->GetTabAtIndex(index)->GetHandle().raw_value(),
          NavigationEvents::Receive, events.get()));
      observed_tabs.push_back(owner->GetTabStripModel()->GetTabAtIndex(index)
                                  ->GetHandle().raw_value());
      observed_windows.push_back(owner->GetSessionID().id());
      observations.push_back(std::move(events));
    }
  }
  auto* host = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  auto host_alive = host->GetWeakPtr();
  auto children_before = views::Widget::GetAllOwnedWidgets(host->GetNativeView());
  auto find_warning = [&]() -> base::WeakPtr<views::Widget> {
    for (const auto& child : views::Widget::GetAllOwnedWidgets(host->GetNativeView())) {
      if (!children_before.contains(child) && child->IsVisible() &&
          views::AsViewClass<DownloadInProgressDialogView>(child->GetClientContentsView()))
        return child->GetWeakPtr();
    }
    return {};
  };
  base::WeakPtr<views::Widget> warning;
  const char* phase = "logical-refusal";
  auto describe = [&] {
    std::ostringstream state;
    state << "phase=" << phase << " host alive=" << !!host_alive;
    if (host_alive) {
      auto* browser_host = static_cast<BrowserWidget*>(host_alive.get());
      state << " pending=" << browser_host->HasPhysicalClosePending()
            << " committed=" << browser_host->IsPhysicalCloseCommitted();
      if (host_alive->GetNativeView()) {
        for (const auto& child : views::Widget::GetAllOwnedWidgets(
                 host_alive->GetNativeView())) {
          state << " widget visible=" << child->IsVisible()
                << " closed=" << child->IsClosed();
          if (child->GetClientContentsView())
            state << " type=" << child->GetClientContentsView()->GetClassMetaData()->type_name();
        }
      }
    }
    for (size_t index = 0; index < observations.size(); ++index) {
      state << " window=" << observed_windows[index] << " tab=" << observed_tabs[index]
            << " CLOSED=" << observations[index]->Count(BARC_TAB_CLOSED)
            << " CANCEL=" << observations[index]->Count(BARC_TAB_CLOSE_CANCELLED);
      auto* tab = tabs::TabHandle(observed_tabs[index]).Get();
      auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
      if (owner) {
        auto* controller = UnloadController::From(owner);
        state << " owner=" << owner->GetSessionID().id()
              << " tabs=" << owner->GetTabStripModel()->count()
              << " delete=" << owner->IsDeleteScheduled();
        if (controller)
          state << " attempt=" << controller->is_attempting_to_close_browser()
                << " warning=" << controller->IsWaitingForDownloadCloseConfirmation()
                << " status=" << static_cast<int>(controller->GetBrowserClosingStatus());
      }
    }
    return state.str();
  };
  // Logical close uses HandleBeforeClose, whose initial DeniedByUser status
  // still means a pending warning. It must not complete a cancellation yet.
  ASSERT_EQ(1, barc_window_close(otr_id));
  ASSERT_TRUE(base::test::RunUntil([&] { warning = find_warning(); return !!warning; }))
      << describe();
  for (const auto& events : observations)
    EXPECT_EQ(0u, events->Count(BARC_TAB_CLOSE_CANCELLED));
  warning->widget_delegate()->AsDialogDelegate()->CancelDialog();
  std::vector<size_t> prior_cancellations;
  for (int32_t owner : observed_windows)
    prior_cancellations.push_back(owner == otr_id ? 1u : 0u);
  auto cancellation_counts_match = [&](size_t group_cancellations) {
    for (size_t index = 0; index < observations.size(); ++index) {
      if (observations[index]->Count(BARC_TAB_CLOSE_CANCELLED) !=
          prior_cancellations[index] + group_cancellations) return false;
    }
    return true;
  };
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !warning && cancellation_counts_match(0);
  })) << describe();
  phase = "group-refusal";
  children_before = views::Widget::GetAllOwnedWidgets(host->GetNativeView());
  host->Close();
  ASSERT_TRUE(base::test::RunUntil([&] { warning = find_warning(); return !!warning; }))
      << describe();
  EXPECT_TRUE(cancellation_counts_match(0)) << describe();
  warning->widget_delegate()->AsDialogDelegate()->CancelDialog();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !warning && cancellation_counts_match(1);
  })) << describe();
  for (const auto& events : observations) EXPECT_EQ(0u, events->Count(BARC_TAB_CLOSED));
  ASSERT_TRUE(profile_alive);
  content::DownloadManager::DownloadVector downloads;
  profile_alive->GetDownloadManager()->GetAllDownloads(&downloads);
  ASSERT_EQ(1u, downloads.size());
  EXPECT_EQ(download::DownloadItem::IN_PROGRESS, downloads.front()->GetState());
  downloads.clear();
  phase = "group-acceptance";
  children_before = views::Widget::GetAllOwnedWidgets(host->GetNativeView());
  host->Close();
  ASSERT_TRUE(base::test::RunUntil([&] { warning = find_warning(); return !!warning; }))
      << describe();
  EXPECT_TRUE(cancellation_counts_match(1)) << describe();
  auto* accept = warning->widget_delegate()->AsDialogDelegate();
  children_before.clear();
  accept->AcceptDialog();
  const bool closed = base::test::RunUntil([&] {
    return std::all_of(observations.begin(), observations.end(),
        [](const auto& e) { return e->Count(BARC_TAB_CLOSED) == 1; });
  });

  ASSERT_TRUE(closed) << describe();
  EXPECT_TRUE(cancellation_counts_match(1)) << describe();
}


namespace {
struct DiscoveryEvents {
  std::vector<uint64_t> revisions;
  bool unsubscribe = false;
  int32_t close_window = 0;
  static void Receive(void* context, uint64_t token, uint64_t revision) {
    auto* self = static_cast<DiscoveryEvents*>(context);
    self->revisions.push_back(revision);
    const int32_t close_window = self->close_window;
    if (self->unsubscribe)
      barc_discovery_unobserve(token);
    if (close_window)
      EXPECT_EQ(1, barc_window_close(close_window));
  }
};
struct DiscoveryRows {
  std::vector<BarcDiscoveryWindow> windows;
  std::vector<BarcDiscoveryTab> tabs;
  BarcDiscoverySnapshot snapshot{};
  void Read() {
    const auto result = barc_discovery_snapshot(nullptr, 0, nullptr, 0, &snapshot);
    ASSERT_TRUE(result == BARC_DISCOVERY_READ_CAPACITY ||
                result == BARC_DISCOVERY_READ_OK);
    windows.resize(snapshot.window_count);
    tabs.resize(snapshot.tab_count);
    ASSERT_EQ(BARC_DISCOVERY_READ_OK,
              barc_discovery_snapshot(windows.data(), windows.size(),
                                      tabs.data(), tabs.size(), &snapshot));
  }
};
void ExpectNoStockChrome(BrowserView* view) {
  view->browser_widget()->LayoutRootViewIfNecessary();
  EXPECT_FALSE(view->toolbar()->IsDrawn());
  EXPECT_FALSE(view->tab_strip_view()->IsDrawn());
  if (auto* bookmarks = view->bookmark_bar()) {
    EXPECT_FALSE(bookmarks->IsDrawn());
  }
}
void ExpectPageBelowOnlyNativeTop(BrowserView* view, int top) {
  ExpectNoStockChrome(view);
  auto* multi = view->multi_contents_view();
  const gfx::Rect contents = multi->ConvertRectToWidget(multi->GetLocalBounds());
  EXPECT_EQ(top, contents.y());
  EXPECT_EQ(view->browser_widget()->GetClientAreaBoundsInScreen().height(),
            contents.bottom());
}
void ExpectSubtreeInvisibleToAccessibility(views::View* view) {
  ui::AXNodeData data;
  view->GetViewAccessibility().GetAccessibleNodeData(&data);
  EXPECT_TRUE(data.IsInvisible()) << view->GetClassName();
  for (views::View* child : view->children()) {
    ExpectSubtreeInvisibleToAccessibility(child);
  }
}
void ExpectViewportHeight(content::WebContents* page, int height) {
  EXPECT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(page, "innerHeight").ExtractInt() == height;
  })) << "innerHeight=" << content::EvalJs(page, "innerHeight").ExtractInt()
      << " expected=" << height;
}
}  // namespace

class BarcDiscoveryBrowserTest : public BarcSharedNativeWindowBrowserTest {
 public:
  void SetUp() override {
    barc_set_runtime_ready_callback([](void*) {
      int32_t initial = 0;
      GlobalBrowserCollection::GetInstance()->ForEach(
          [&](BrowserWindowInterface* window) {
            if (window->GetType() == BrowserWindowInterface::TYPE_NORMAL) {
              initial = window->GetSessionID().id();
              return false;
            }
            return true;
          });
      CHECK_GT(initial, 0);
      NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
      CHECK(barc_window_attach_native_shell(initial, (__bridge void*)header));
      CHECK(barc_window_admit_discovered(initial, (__bridge void*)header));
      barc_runtime_complete_startup(initial);
    }, nullptr);
    BarcSharedNativeWindowBrowserTest::SetUp();
  }
 protected:
  BrowserWindowInterface* NewNormal() {
    return CreateBrowserWindow(BrowserWindowCreateParams(
        BrowserWindowInterface::TYPE_NORMAL, browser()->GetProfile(), false));
  }
  NSView* Attach(int32_t id) {
    NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
    EXPECT_EQ(1, barc_window_attach_native_shell(id, (__bridge void*)header));
    return header;
  }
};

// Empty-peer admission requires the same startup resolver registration as the
// native app. This fixture dispatches no app-model actions: explicitly refuse
// target resolution rather than infer a default Chrome profile/window.
class BarcPromotionDiscoveryBrowserTest : public BarcDiscoveryBrowserTest {
 public:
  void SetUp() override {
    barc_set_runtime_browser_target_callback(
        [](int32_t, const char*, int32_t, int32_t,
           BarcApplicationTarget* output, void*) -> int32_t {
          if (output) *output = {};
          return 0;
        }, nullptr);
    BarcDiscoveryBrowserTest::SetUp();
  }
};

IN_PROC_BROWSER_TEST_F(BarcPromotionDiscoveryBrowserTest,
                       EmptyPromotionPeerRetainsExactProfileAndNativeSelection) {
  ASSERT_TRUE(barc::CanResolveApplicationBrowser());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work);
  ASSERT_TRUE(personal);
  ASSERT_EQ(1, barc_window_select(personal_id));
  const int32_t peer_id = barc_window_new_peer_in_native_window(work_id, personal_id);
  auto* peer = SharedWindow(peer_id);
  ASSERT_TRUE(peer);
  EXPECT_EQ(work->GetProfile(), peer->GetProfile());
  EXPECT_TRUE(peer->GetTabStripModel()->empty());
  EXPECT_EQ(personal->GetWindow()->GetNativeWindow(), peer->GetWindow()->GetNativeWindow());
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(peer->IsSelectedForNativeWindow());
  EXPECT_TRUE(BrowserView::GetBrowserViewForBrowser(peer)->barc_app_factory_origin());
  EXPECT_EQ(0, barc_window_new_peer_in_native_window(browser()->GetSessionID().id(), personal_id));
  EXPECT_EQ(0, barc_window_new_peer_in_native_window(work_id, -1));
  ASSERT_EQ(1, barc_window_close(peer_id));
  SharedProfileResult private_result;
  barc_private_session_open_window(SharedProfileCompleted, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  const int32_t private_id = private_result.Get<1>();
  std::array<char, 37> original{}, child{};
  ASSERT_EQ(37u, barc_window_private_session_uuid(private_id, original.data(), original.size()));
  EXPECT_EQ(0, barc_window_new_peer_in_native_window(private_id, personal_id));
  const int32_t private_peer = barc_window_new_peer_in_native_window(private_id, private_id);
  ASSERT_GT(private_peer, 0);
  EXPECT_EQ(37u, barc_window_private_session_uuid(private_peer, child.data(), child.size()));
  EXPECT_EQ(original, child);
  EXPECT_EQ(0u, barc_window_profile_uuid(private_peer, child.data(), child.size()));
  EXPECT_TRUE(SharedWindow(private_peer)->GetTabStripModel()->empty());
  EXPECT_EQ(SharedWindow(private_id)->GetProfile(), SharedWindow(private_peer)->GetProfile());
  EXPECT_TRUE(SharedWindow(private_id)->IsSelectedForNativeWindow());
  EXPECT_FALSE(SharedWindow(private_peer)->IsSelectedForNativeWindow());
  EXPECT_EQ(1, barc_window_close(private_peer));
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       AdmissionPreservesIndependentPresentationAndHide) {
  auto* first = NewNormal();
  auto* second = NewNormal();
  ASSERT_TRUE(first);
  ASSERT_TRUE(second);
  const int32_t first_id = first->GetSessionID().id();
  const int32_t second_id = second->GetSessionID().id();
  chrome::AddAndReturnTabAt(first, GURL("about:blank"), -1, true);
  chrome::AddAndReturnTabAt(second, GURL("about:blank"), -1, true);
  first->GetWindow()->Show();
  second->GetWindow()->ShowInactive();
  EXPECT_FALSE(first->GetWindow()->IsVisible());
  EXPECT_FALSE(second->GetWindow()->IsVisible());
  // Active-tab mutation must not consume a deferred first Show.
  chrome::AddAndReturnTabAt(first, GURL("about:blank"), -1, true);
  NSView* first_header = Attach(first_id);
  NSView* second_header = Attach(second_id);
  ASSERT_EQ(1, barc_window_admit_discovered(first_id,
                                           (__bridge void*)first_header));
  ASSERT_EQ(1, barc_window_admit_discovered(second_id,
                                           (__bridge void*)second_header));
  EXPECT_TRUE(first->GetWindow()->IsVisible());
  EXPECT_TRUE(second->GetWindow()->IsVisible());
  BarcDiscoveryWindow row{};
  ASSERT_EQ(1, barc_window_discovery_state(second_id, &row));
  EXPECT_FALSE(row.flags & BARC_DISCOVERY_AWAITING_ADMISSION);
  EXPECT_FALSE(row.flags & BARC_DISCOVERY_PHYSICAL_ACTIVE);
  // Hide explicitly cancels presentation, while admission may still succeed.
  auto* hidden = NewNormal();
  ASSERT_TRUE(hidden);
  chrome::AddAndReturnTabAt(hidden, GURL("about:blank"), -1, true);
  hidden->GetWindow()->Show();
  hidden->GetWindow()->Hide();
  const int32_t hidden_id = hidden->GetSessionID().id();
  NSView* hidden_header = Attach(hidden_id);
  ASSERT_EQ(1, barc_window_admit_discovered(hidden_id,
                                           (__bridge void*)hidden_header));
  EXPECT_FALSE(hidden->GetWindow()->IsVisible());
  EXPECT_EQ(0, barc_window_admit_discovered(hidden_id,
                                           (__bridge void*)first_header));
  // Popups retain their ordinary Chrome presentation and no product header.
  auto* popup = CreateBrowserWindow(BrowserWindowCreateParams(
      BrowserWindowInterface::TYPE_POPUP, browser()->GetProfile(), false));
  ASSERT_TRUE(popup);
  chrome::AddAndReturnTabAt(popup, GURL("about:blank"), -1, true);
  popup->GetWindow()->ShowInactive();
  EXPECT_TRUE(popup->GetWindow()->IsVisible());
  EXPECT_EQ(1, barc_window_select(popup->GetSessionID().id()));
  EXPECT_EQ(nullptr, BrowserView::GetBrowserViewForBrowser(popup)->barc_native_shell());
  EXPECT_EQ(0, barc_window_admit_discovered(popup->GetSessionID().id(),
                                           (__bridge void*)first_header));
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       NativeWindowPageStartsBelowHeaderWithoutStockChrome) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  NSView* sidebar = Attach(work_id);
  ASSERT_EQ(1, barc_window_show(work_id));
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  auto* view = BrowserView::GetBrowserViewForBrowser(work);
  auto* widget = view->browser_widget();
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  widget->SetSize(gfx::Size(1400, 900));
  const auto client_height = [&] {
    return widget->GetClientAreaBoundsInScreen().height();
  };
  ExpectPageBelowOnlyNativeTop(view, 0);
  ExpectViewportHeight(page, client_height());

  NSView* page_bar = [[NSView alloc] init];
  ASSERT_EQ(1, barc_window_set_native_header(work_id, (__bridge void*)sidebar,
      nullptr, (__bridge void*)page_bar, 40));
  ExpectPageBelowOnlyNativeTop(view, 40);
  ExpectViewportHeight(page, client_height() - 40);

  widget->SetSize(gfx::Size(1200, 700));
  ExpectPageBelowOnlyNativeTop(view, 40);
  ExpectViewportHeight(page, client_height() - 40);

  chrome::ExecuteCommand(work, IDC_SHOW_BOOKMARK_BAR);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return view->bookmark_bar() && !view->IsBookmarkBarAnimating() &&
           view->bookmark_bar()->GetPreferredSize().height() > 0;
  }));
  ExpectPageBelowOnlyNativeTop(view, 40);
  ExpectViewportHeight(page, client_height() - 40);

  ASSERT_EQ(1, barc_window_set_native_header(work_id, (__bridge void*)sidebar,
      (__bridge void*)page_bar, nullptr, 0));
  ExpectPageBelowOnlyNativeTop(view, 0);
  ExpectViewportHeight(page, client_height());
  EXPECT_EQ(HTCLIENT, view->NonClientHitTest(gfx::Point(view->width() / 2, 0)));

  const int32_t settings_id = Open(kSharedPersonal, 0, BARC_PROFILE_SETTINGS);
  auto* settings = SharedWindow(settings_id);
  ASSERT_TRUE(settings);
  Attach(settings_id);
  ASSERT_EQ(1, barc_window_show(settings_id));
  ExpectPageBelowOnlyNativeTop(BrowserView::GetBrowserViewForBrowser(settings), 0);

  auto* popup = CreateBrowserWindow(BrowserWindowCreateParams(
      BrowserWindowInterface::TYPE_POPUP, browser()->GetProfile(), false));
  ASSERT_TRUE(popup);
  chrome::AddAndReturnTabAt(popup, GURL("about:blank"), -1, true);
  popup->GetWindow()->ShowInactive();
  auto* popup_view = BrowserView::GetBrowserViewForBrowser(popup);
  popup_view->browser_widget()->LayoutRootViewIfNecessary();
  EXPECT_TRUE(popup_view->toolbar()->IsDrawn());
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       NativeWindowStockChromeIsGoneForKeyboardAndAccessibility) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  Attach(work_id);
  ASSERT_EQ(1, barc_window_show(work_id));
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  auto* view = BrowserView::GetBrowserViewForBrowser(work);
  view->browser_widget()->LayoutRootViewIfNecessary();
  auto* focus = view->GetFocusManager();
  const auto expect_focus_outside_stock_chrome = [&] {
    auto* focused = focus->GetFocusedView();
    EXPECT_FALSE(focused && view->toolbar()->Contains(focused));
    EXPECT_FALSE(focused && view->tab_strip_view()->Contains(focused));
  };
  for (int i = 0; i < 40; ++i) {
    focus->AdvanceFocus(/*reverse=*/false);
    expect_focus_outside_stock_chrome();
  }
  for (int i = 0; i < 12; ++i) {
    chrome::ExecuteCommand(work, IDC_FOCUS_NEXT_PANE);
    expect_focus_outside_stock_chrome();
  }
  for (int command : {IDC_FOCUS_TOOLBAR, IDC_FOCUS_LOCATION, IDC_FOCUS_SEARCH,
                      IDC_FOCUS_MENU_BAR}) {
    chrome::ExecuteCommand(work, command);
    expect_focus_outside_stock_chrome();
  }

  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  page->Focus();
  auto* page_focus = focus->GetFocusedView();
  ASSERT_TRUE(page_focus);
  view->SetFocusToLocationBar(/*is_user_initiated=*/false);
  EXPECT_EQ(page_focus, focus->GetFocusedView());

  ExpectSubtreeInvisibleToAccessibility(view->toolbar());
  ExpectSubtreeInvisibleToAccessibility(view->tab_strip_view());
}

class BarcWebUIToolbarBrowserTest : public BarcDiscoveryBrowserTest {
 public:
  BarcWebUIToolbarBrowserTest() {
    features_.InitWithFeatures(
        {features::kInitialWebUI, features::kWebUIReloadButton}, {});
  }

 private:
  base::test::ScopedFeatureList features_;
};

void CollectAccessibilityNodes(gfx::NativeViewAccessible element,
                               std::set<ui::AXPlatformNode*>* nodes) {
  auto* node = ui::AXPlatformNode::FromNativeViewAccessible(element);
  if (!node || !nodes->insert(node).second) {
    return;
  }
  auto* delegate = node->GetDelegate();
  for (size_t i = 0; i < delegate->GetChildCount(); ++i) {
    CollectAccessibilityNodes(delegate->ChildAtIndex(i), nodes);
  }
}

IN_PROC_BROWSER_TEST_F(BarcWebUIToolbarBrowserTest,
                       HiddenWebUIToolbarLeavesTheAccessibilityTree) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  Attach(work_id);
  ASSERT_EQ(1, barc_window_show(work_id));
  auto* view = BrowserView::GetBrowserViewForBrowser(work);
  view->browser_widget()->LayoutRootViewIfNecessary();
  auto* webui_toolbar = view->toolbar()->GetWebUIToolbarViewForTesting();
  ASSERT_TRUE(webui_toolbar);
  std::set<ui::AXPlatformNode*> reachable;
  CollectAccessibilityNodes(
      view->GetWidget()->GetRootView()->GetNativeViewAccessible(), &reachable);
  EXPECT_FALSE(reachable.contains(ui::AXPlatformNode::FromNativeViewAccessible(
      webui_toolbar->GetNativeViewAccessible())));
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       NativeWindowFullscreenKeepsPageBelowOnlyNativeTop) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  NSView* sidebar = Attach(work_id);
  ASSERT_EQ(1, barc_window_show(work_id));
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  NSView* page_bar = [[NSView alloc] init];
  ASSERT_EQ(1, barc_window_set_native_header(work_id, (__bridge void*)sidebar,
      nullptr, (__bridge void*)page_bar, 40));
  auto* view = BrowserView::GetBrowserViewForBrowser(work);
  auto* widget = view->browser_widget();
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  for (bool fullscreen : {true, false}) {
    SCOPED_TRACE(fullscreen ? "entered" : "exited");
    ui_test_utils::ToggleFullscreenModeAndWait(work);
    EXPECT_EQ(fullscreen, view->IsFullscreen());
    ExpectPageBelowOnlyNativeTop(view, 40);
    ExpectViewportHeight(page, widget->GetClientAreaBoundsInScreen().height() - 40);
  }
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       SnapshotCoalescesAndTracksFactoryMembership) {
  DiscoveryEvents events;
  const uint64_t token = barc_discovery_observe(DiscoveryEvents::Receive, &events);
  ASSERT_NE(0u, token);
  EXPECT_EQ(0u, barc_discovery_observe(DiscoveryEvents::Receive, &events));
  EXPECT_TRUE(events.revisions.empty());
  base::RunLoop().RunUntilIdle();
  ASSERT_EQ(1u, events.revisions.size());
  const int32_t id = browser()->GetSessionID().id();
  BarcDiscoveryWindow direct{};
  ASSERT_EQ(1, barc_window_discovery_state(id, &direct));
  const int32_t created = barc_tab_create(id, "about:blank", 1);
  ASSERT_GT(created, 0);
  DiscoveryRows rows;
  rows.Read();
  auto found = std::ranges::find(rows.tabs, created, &BarcDiscoveryTab::tab);
  ASSERT_NE(rows.tabs.end(), found);
  EXPECT_TRUE(found->flags & BARC_DISCOVERY_TAB_APP_FACTORY);
  EXPECT_TRUE(found->flags & BARC_DISCOVERY_ACTIVE_TAB);
  ASSERT_EQ(1, barc_window_discovery_state(id, &direct));
  EXPECT_EQ(created, direct.active_tab);
  // Capacity refusal must not expose partial rows.
  BarcDiscoveryWindow untouched{};
  untouched.window = -123;
  BarcDiscoverySnapshot counts{};
  EXPECT_EQ(BARC_DISCOVERY_READ_CAPACITY,
            barc_discovery_snapshot(&untouched, 1, nullptr, 0, &counts));
  EXPECT_EQ(-123, untouched.window);
  base::RunLoop().RunUntilIdle();
  const size_t settled = events.revisions.size();
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(settled, events.revisions.size());
  // Same-count replacement is structural, even though both count queries match.
  const size_t previous_count = rows.tabs.size();
  ASSERT_EQ(1, barc_tab_close(id, created));
  const int32_t replacement = barc_tab_create(id, "about:blank", 0);
  ASSERT_GT(replacement, 0);
  rows.Read();
  EXPECT_EQ(previous_count, rows.tabs.size());
  EXPECT_EQ(rows.tabs.end(), std::ranges::find(rows.tabs, created, &BarcDiscoveryTab::tab));
  EXPECT_NE(rows.tabs.end(), std::ranges::find(rows.tabs, replacement, &BarcDiscoveryTab::tab));
  base::RunLoop().RunUntilIdle();
  EXPECT_GT(events.revisions.size(), settled);
  // Pending delivery is canceled, and self-unsubscription admits a new owner.
  events.unsubscribe = true;
  auto* closing = NewNormal();
  ASSERT_TRUE(closing);
  chrome::AddAndReturnTabAt(closing, GURL("about:blank"), -1, true);
  events.close_window = closing->GetSessionID().id();
  auto closing_alive = closing->GetWeakPtr();
  base::RunLoop().RunUntilIdle();
  ASSERT_TRUE(base::test::RunUntil([&] { return !closing_alive; }));
  const size_t canceled = events.revisions.size();
  chrome::AddAndReturnTabAt(browser(), GURL("about:blank"), -1, false);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(canceled, events.revisions.size());
  const uint64_t pending = barc_discovery_observe(DiscoveryEvents::Receive, &events);
  ASSERT_NE(0u, pending);
  barc_discovery_unobserve(pending);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(canceled, events.revisions.size());
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       PhysicalIdentitySurvivesOwnerAndOpenerStaysNative) {
  const int32_t work = Open("5a33ed34-5816-4a1c-b20c-eed936e4ee73", 0,
                            BARC_PROFILE_BLANK);
  ASSERT_GT(work, 0);
  const int32_t personal = Open("74446f9e-12fc-45d8-bb7f-33640823fe44", work,
                                BARC_PROFILE_BLANK);
  ASSERT_GT(personal, 0);
  BarcDiscoveryWindow work_row{}, personal_row{};
  ASSERT_EQ(1, barc_window_discovery_state(work, &work_row));
  ASSERT_EQ(1, barc_window_discovery_state(personal, &personal_row));
  const uint64_t group = work_row.physical_group;
  EXPECT_EQ(group, personal_row.physical_group);
  EXPECT_EQ(work, personal_row.selected_client);
  EXPECT_EQ(BARC_DISCOVERY_REGULAR, personal_row.profile_kind);
  EXPECT_STREQ("74446f9e-12fc-45d8-bb7f-33640823fe44",
               personal_row.regular_profile_uuid);
  EXPECT_TRUE(work_row.flags & BARC_DISCOVERY_WINDOW_APP_FACTORY);
  EXPECT_FALSE(personal_row.flags & BARC_DISCOVERY_AWAITING_ADMISSION);
  const int32_t initial_tab = barc_window_tab_at(personal, 0);
  DiscoveryRows rows;
  rows.Read();
  auto initial = std::ranges::find(rows.tabs, initial_tab, &BarcDiscoveryTab::tab);
  ASSERT_NE(rows.tabs.end(), initial);
  EXPECT_TRUE(initial->flags & BARC_DISCOVERY_TAB_APP_FACTORY);
  auto* work_owner = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(work));
  ui_test_utils::BrowserDestroyedObserver closed(work_owner);
  ASSERT_EQ(1, barc_window_close(work));
  closed.Wait();
  EXPECT_EQ(0, barc_window_discovery_state(work, &work_row));
  ASSERT_EQ(1, barc_window_discovery_state(personal, &personal_row));
  EXPECT_EQ(group, personal_row.physical_group);
  EXPECT_EQ(personal, personal_row.selected_client);
  // A Chrome-created popup is not an app-factory tab/window. Its actual JS
  // opener is reported without selecting or showing a product header.
  auto* opener = browser()->GetTabStripModel()->GetActiveWebContents();
  content::WebContentsAddedObserver added;
  ASSERT_TRUE(content::ExecJs(opener,
      "window.open('about:blank', 'catalog-popup', 'popup,width=400,height=300')"));
  auto* popup_contents = added.GetWebContents();
  ASSERT_TRUE(popup_contents);
  auto* popup_tab = tabs::TabInterface::GetFromContents(popup_contents);
  ASSERT_TRUE(popup_tab);
  auto* popup_owner = popup_tab->GetBrowserWindowInterface();
  ASSERT_TRUE(popup_owner);
  BarcDiscoveryWindow popup_row{};
  ASSERT_EQ(1, barc_window_discovery_state(popup_owner->GetSessionID().id(),
                                          &popup_row));
  EXPECT_EQ(BARC_DISCOVERY_POPUP, popup_row.kind);
  EXPECT_FALSE(popup_row.flags & BARC_DISCOVERY_WINDOW_APP_FACTORY);
  rows.Read();
  auto popup = std::ranges::find(rows.tabs, popup_tab->GetHandle().raw_value(),
                                 &BarcDiscoveryTab::tab);
  ASSERT_NE(rows.tabs.end(), popup);
  EXPECT_FALSE(popup->flags & BARC_DISCOVERY_TAB_APP_FACTORY);
  EXPECT_EQ(tabs::TabInterface::GetFromContents(opener)->GetHandle().raw_value(),
            popup->opener_tab);
}

// Native accepted-close delivery is distinct from the initial quit attempt.
class BarcAcceptedQuitBrowserTest : public BarcDiscoveryBrowserTest {
 public:
  void SetUp() override {
    barc_set_runtime_close_callback(
        [](int32_t accepted, void* pointer) {
          auto* self = static_cast<BarcAcceptedQuitBrowserTest*>(pointer);
          self->phases.push_back(accepted);
          if (accepted && self->on_accepted) {
            self->on_accepted.Run();
          }
        },
        this);
    BarcDiscoveryBrowserTest::SetUp();
  }
 protected:
  std::vector<int32_t> phases;
  base::RepeatingClosure on_accepted;
};

IN_PROC_BROWSER_TEST_F(BarcAcceptedQuitBrowserTest,
                       InitialBeforeUnloadVetoNeverSignalsAcceptedClose) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), GURL("data:text/html,initial")));
  auto* page = browser()->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(page, "onbeforeunload=()=> 'keep';"));
  content::PrepContentsForBeforeUnloadTest(page);
  chrome::CloseAllBrowsersAndQuit();
  auto* dialog = ui_test_utils::WaitForAppModalDialog();
  EXPECT_TRUE(phases.empty());
  dialog->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([] { return !browser_shutdown::IsTryingToQuit(); }));
  EXPECT_TRUE(phases.empty());
  ASSERT_TRUE(content::ExecJs(page, "onbeforeunload=null;"));
}

IN_PROC_BROWSER_TEST_F(BarcAcceptedQuitBrowserTest,
                       LateWindowVetoReversesAcceptedCloseAndKeepsBrowserUsable) {
  auto* profile = browser()->GetProfile();
  auto keep_alive = ScopedProfileKeepAlive::TryAcquire(
      profile, ProfileKeepAliveOrigin::kProfileCreationFlow);
  ASSERT_TRUE(keep_alive);
  const int32_t original = browser()->GetSessionID().id();
  base::WeakPtr<BrowserWindowInterface> late;
  content::WebContents* late_page = nullptr;
  bool prepared = false;
  on_accepted = base::BindLambdaForTesting([&] {
    // The accepted notification precedes even the first native owner teardown.
    EXPECT_GT(barc_window_tab_count(original), 0u);
    auto* created = CreateBrowser(profile);
    late = created->GetWeakPtr();
    ASSERT_TRUE(ui_test_utils::NavigateToURL(created, GURL("data:text/html,late")));
    late_page = created->GetTabStripModel()->GetActiveWebContents();
    prepared = content::ExecJs(late_page, "onbeforeunload=()=> 'keep';");
    content::PrepContentsForBeforeUnloadTest(late_page);
  });
  base::ScopedClosureRunner clear_handler(base::BindLambdaForTesting([&] {
    on_accepted.Reset();
  }));
  chrome::CloseAllBrowsersAndQuit();
  ASSERT_TRUE(late);
  ASSERT_TRUE(prepared);
  auto* dialog = ui_test_utils::WaitForAppModalDialog();
  EXPECT_EQ(late_page, dialog->web_contents());
  EXPECT_EQ(std::vector<int32_t>({1}), phases);
  dialog->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return phases == std::vector<int32_t>({1, 0}) &&
           !browser_shutdown::IsTryingToQuit();
  }));
  ASSERT_TRUE(late);
  EXPECT_GT(barc_tab_create(late->GetSessionID().id(), "about:blank", 0), 0);
  ASSERT_TRUE(content::ExecJs(late_page, "onbeforeunload=null;"));
  chrome::OnClosingAllBrowsers(false);
  EXPECT_EQ(std::vector<int32_t>({1, 0}), phases); // No duplicate cancellation.
}

// An early ChromeMain return must release borrowed application callbacks even
// when the browser main loop never reaches RuntimeStopped().
class BarcEarlyRegisteredReturnBrowserTest : public InProcessBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    // These early-return cases never admit or present a startup window.
    command_line->AppendSwitch(switches::kNoStartupWindow);
  }
  void SetUp() override {
    barc_set_runtime_ready_callback(
        [](void* context) { ++static_cast<BarcEarlyRegisteredReturnBrowserTest*>(context)->deliveries; }, this);
    barc_set_runtime_close_callback(
        [](int32_t, void* context) { ++static_cast<BarcEarlyRegisteredReturnBrowserTest*>(context)->deliveries; }, this);
    barc_set_runtime_browser_target_callback(
        [](int32_t, const char*, int32_t, int32_t, BarcApplicationTarget*, void* context) {
          ++static_cast<BarcEarlyRegisteredReturnBrowserTest*>(context)
                ->deliveries;
          return 0;
        },
        this);
    ASSERT_FALSE(barc::RuntimeCallbacksClearedForTesting());
    if (AbortBeforeMain()) {
      barc_runtime_complete_startup(0);
      ASSERT_TRUE(barc::RuntimeCallbacksClearedForTesting());
    }
    InProcessBrowserTest::SetUp();
  }
 protected:
  virtual bool AbortBeforeMain() const { return true; }
  int deliveries = 0;
};

IN_PROC_BROWSER_TEST_F(BarcEarlyRegisteredReturnBrowserTest,
                       ReleasesBothBorrowedContextsAndSubscriptions) {
  EXPECT_TRUE(barc::RuntimeCallbacksClearedForTesting());
  EXPECT_FALSE(barc::IsNativeApplicationRegistered());
  chrome::OnAllBrowsersCloseAccepted();
  chrome::OnClosingAllBrowsers(false);
  EXPECT_EQ(0, deliveries);
}

class BarcEarlyPostedReturnBrowserTest : public BarcEarlyRegisteredReturnBrowserTest {
 protected:
  bool AbortBeforeMain() const override { return false; }
  class AbortBeforeReadyDrain : public ChromeBrowserMainExtraParts {
   public:
    void PostBrowserStart() override {
      if (!barc::IsNativeApplicationMode()) {
        barc::SetApplicationLaunchReadyCallback(base::BindRepeating([] {}));
      }
      // ChromeBrowserMainParts calls barc::PostRuntimeReady immediately after
      // all PostBrowserStart parts. This task therefore runs with kPosted,
      // before the subsequently posted runtime-ready callback can drain.
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce([] {
            EXPECT_TRUE(barc::IsNativeApplicationRegistered());
            EXPECT_FALSE(barc::RuntimeCallbacksClearedForTesting());
            barc_runtime_complete_startup(0);
            EXPECT_TRUE(barc::RuntimeCallbacksClearedForTesting());
          }));
    }
  };
  void CreatedBrowserMainParts(content::BrowserMainParts* parts) override {
    InProcessBrowserTest::CreatedBrowserMainParts(parts);
    static_cast<ChromeBrowserMainParts*>(parts)->AddParts(
        std::make_unique<AbortBeforeReadyDrain>());
  }
};

IN_PROC_BROWSER_TEST_F(BarcEarlyPostedReturnBrowserTest,
                       ReleasesBeforeQueuedReadyDelivery) {
  EXPECT_TRUE(barc::RuntimeCallbacksClearedForTesting());
  EXPECT_FALSE(barc::IsNativeApplicationRegistered());
  EXPECT_EQ(0, deliveries);
}

// Mechanical handler/ownership tests, using Chromium's ordinary browser-test
// focus helpers. These do not qualify native AppleEvent delivery or key focus.
@interface AppController (BarcLaunchTests)
- (void)openStartupUrls;
@end

class BarcApplicationLaunchBrowserTest
    : public BarcSharedNativeWindowBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command) override {
    BarcSharedNativeWindowBrowserTest::SetUpCommandLine(command);
    command->AppendSwitch("no-startup-window");
    command->AppendArg("data:text/plain,cli-once");
    command->AppendArg("javascript:document.title='forbidden'");
  }
  void SetUp() override {
    barc_set_runtime_browser_target_callback(
        [](int32_t kind, const char*, int32_t pending_window, int32_t pending_tab,
           BarcApplicationTarget* output, void* pointer) {
          auto* self = static_cast<BarcApplicationLaunchBrowserTest*>(pointer);
          ++self->target_reads;
          *output = {};
          if (kind == 0 && self->opening) return int32_t{-1};
          if (kind == 3) {
            self->pending_window = pending_window;
            self->pending_tab = pending_tab;
            if (self->hold_admission) return int32_t{-1};
            output->presentation = self->mini ? BARC_APPLICATION_MINI : BARC_APPLICATION_CURRENT_SPACE;
            output->window = pending_window;
            return int32_t{1};
          }
          output->presentation = self->mini ? BARC_APPLICATION_MINI : BARC_APPLICATION_CURRENT_SPACE;
          // Synthetic model space is only a one-shot routing hint. No fixture
          // URL is navigated until the exact pending native page is admitted.
          if (!self->mini) {
            base::span(output->space_uuid).copy_from(base::span_with_nul_from_cstring("12345678-1234-4234-8234-123456789abc"));
          }
          if (self->target > 0) {
            output->window = self->target;
            return int32_t{1};
          }
          if (self->fallback) {
            base::span(output->regular_profile_uuid).first<36>().copy_from(base::span(self->uuid));
            return int32_t{1};
          }
          return int32_t{0};
        },
        this);
    barc_set_runtime_ready_callback(
        [](void* pointer) {
          auto* self = static_cast<BarcApplicationLaunchBrowserTest*>(pointer);
          // The default test browser is only startup scaffolding; requested
          // URLs must go into the real Barc Work profile created below.
          GlobalBrowserCollection::GetInstance()->ForEach(
              [](BrowserWindowInterface* browser) {
                NSView* header =
                    [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
                CHECK(barc_window_attach_native_shell(
                    browser->GetSessionID().id(), (__bridge void*)header));
                CHECK(barc_window_admit_discovered(browser->GetSessionID().id(),
                                                   (__bridge void*)header));
                return true;
              });
          barc_profile_open_window(
              kSharedWork, BARC_PROFILE_BLANK,
              [](barc_profile_status status, int32_t window, void* pointer) {
                auto* self =
                    static_cast<BarcApplicationLaunchBrowserTest*>(pointer);
                CHECK_EQ(BARC_PROFILE_OK, status);
                self->target = window;
                NSView* header =
                    [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
                CHECK(barc_window_attach_native_shell(window,
                                                      (__bridge void*)header));
                // This exact C-factory blank is excluded from discovery
                // admission. The fixture binds its target before explicit
                // startup presentation.
                barc_runtime_complete_startup(window);
              },
              self);
        },
        this);
    BarcSharedNativeWindowBrowserTest::SetUp();
  }

 protected:
  int32_t target = 0;
  bool fallback = false;
  int target_reads = 0;
  bool opening = false;
  bool mini = false;
  bool hold_admission = false;
  int32_t pending_window = 0;
  int32_t pending_tab = 0;
  int32_t created_during_resolution = 0;
  std::string uuid = kSharedWork;
  class OpeningOnCreation : public BrowserCollectionObserver {
   public:
    explicit OpeningOnCreation(BarcApplicationLaunchBrowserTest* owner)
        : owner_(owner) {
      observation_.Observe(GlobalBrowserCollection::GetInstance());
    }
    void OnBrowserCreated(BrowserWindowInterface* browser) override {
      if (browser->GetProfile()->GetPath().BaseName().MaybeAsASCII() ==
          "Barc-" + owner_->uuid) {
        owner_->created_during_resolution = browser->GetSessionID().id();
        owner_->opening = true;
      }
    }

   private:
    raw_ptr<BarcApplicationLaunchBrowserTest> owner_;
    base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver>
        observation_{this};
  };
  bool InitialURLsReady() {
    return target > 0 && CountURL(GURL("data:text/plain,cli-once")) == 1 &&
           CountURL(GURL("data:text/plain,early-once")) == 1;
  }
  class EarlyURL : public ChromeBrowserMainExtraParts {
   public:
    void PostBrowserStart() override {
      [AppController.sharedController
          application:NSApp
             openURLs:@[ [NSURL URLWithString:@"data:text/plain,early-once"] ]];
    }
  };
  void CreatedBrowserMainParts(content::BrowserMainParts* parts) override {
    InProcessBrowserTest::CreatedBrowserMainParts(parts);
    static_cast<ChromeBrowserMainParts*>(parts)->AddParts(
        std::make_unique<EarlyURL>());
  }
  void Admit(int32_t window) {
    NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
    ASSERT_EQ(1,
              barc_window_attach_native_shell(window, (__bridge void*)header));
    BarcDiscoveryWindow row{};
    ASSERT_EQ(1, barc_window_discovery_state(window, &row));
    if (row.flags & BARC_DISCOVERY_WINDOW_APP_FACTORY) {
      ASSERT_EQ(1, barc_window_show(window));
    } else {
      ASSERT_EQ(1,
                barc_window_admit_discovered(window, (__bridge void*)header));
    }
  }
  int CountURL(const GURL& url) {
    auto* browser = SharedWindow(target);
    if (!browser) {
      return 0;
    }
    int count = 0;
    for (int i = 0; i < browser->GetTabStripModel()->count(); ++i) {
      if (browser->GetTabStripModel()->GetWebContentsAt(i)->GetVisibleURL() ==
          url) {
        ++count;
      }
    }
    return count;
  }
};

IN_PROC_BROWSER_TEST_F(BarcApplicationLaunchBrowserTest,
                       MiniWaitsForExactAdmissionAndCancelsOnlyClosedFrontURL) {
  ASSERT_TRUE(base::test::RunUntil([&] { return InitialURLsReady(); }));
  std::atomic<int> first_requests{0}, cancelled_requests{0}, next_requests{0};
  embedded_test_server()->RegisterRequestMonitor(base::BindRepeating(
      [](std::atomic<int>* first, std::atomic<int>* cancelled,
         std::atomic<int>* next, const net::test_server::HttpRequest& request) {
        if (request.relative_url == "/title1.html?mini") ++*first;
        if (request.relative_url == "/title2.html?cancelled") ++*cancelled;
        if (request.relative_url == "/title2.html?next") ++*next;
      }, &first_requests, &cancelled_requests, &next_requests));
  ASSERT_TRUE(embedded_test_server()->Start());
  base::ScopedClosureRunner stop_server(base::BindLambdaForTesting([&] {
    EXPECT_TRUE(embedded_test_server()->ShutdownAndWaitUntilComplete());
  }));
  mini = true;
  pending_window = 0;
  pending_tab = 0;
  hold_admission = true;
  auto deliver = [&](const GURL& url) {
    [AppController.sharedController application:NSApp openURLs:@[ [NSURL URLWithString:base::SysUTF8ToNSString(url.spec())] ]];
  };
  const GURL first = embedded_test_server()->GetURL("/title1.html?mini");
  deliver(first);
  ASSERT_TRUE(base::test::RunUntil([&] { return pending_window > 0; }));
  const int32_t popup = pending_window, tab = pending_tab;
  auto* native = SharedWindow(popup);
  ASSERT_TRUE(native);
  auto* contents = native->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(contents);
  EXPECT_TRUE(contents->GetVisibleURL().is_empty() || contents->GetVisibleURL() == GURL("about:blank"));
  EXPECT_EQ(0, first_requests.load());
  BarcDiscoveryWindow row{};
  ASSERT_EQ(1, barc_window_discovery_state(popup, &row));
  EXPECT_EQ(BARC_DISCOVERY_POPUP, row.kind);
  EXPECT_NE(0u, row.flags & BARC_DISCOVERY_COMPACT_MINI);
  EXPECT_NE(0u, row.flags & BARC_DISCOVERY_AWAITING_ADMISSION);
  int starts = 0;
  const uint64_t observation = barc_tab_observe(popup, tab,
      [](void* context, uint64_t, int32_t event, int32_t, int32_t,
         const char*, const char*, int32_t, uint32_t) {
        if (event == BARC_TAB_STARTED) ++*static_cast<int*>(context);
      }, &starts);
  ASSERT_NE(0u, observation);
  Admit(popup);
  hold_admission = false;
  barc::NotifyApplicationBrowserAvailable();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents->GetLastCommittedURL() == first && !contents->IsLoading();
  }));
  ExpectNoStockChrome(BrowserView::GetBrowserViewForBrowser(native));
  EXPECT_EQ(contents, SharedWindow(popup)->GetTabStripModel()->GetActiveWebContents());
  EXPECT_EQ(1, starts);
  EXPECT_EQ(1, first_requests.load());
  barc_tab_unobserve(observation);

  hold_admission = true;
  const int32_t previous = pending_window;
  deliver(embedded_test_server()->GetURL("/title2.html?cancelled"));
  deliver(embedded_test_server()->GetURL("/title2.html?next"));
  ASSERT_TRUE(base::test::RunUntil([&] { return pending_window != previous; }));
  const int32_t closed = pending_window;
  ASSERT_EQ(1, barc_window_close(closed));
  ASSERT_TRUE(base::test::RunUntil([&] { return !SharedWindow(closed); }));
  hold_admission = false;
  barc::NotifyApplicationBrowserAvailable();
  ASSERT_TRUE(base::test::RunUntil([&] { return pending_window != closed; }));
  Admit(pending_window);
  barc::NotifyApplicationBrowserAvailable();
  ASSERT_TRUE(base::test::RunUntil([&] { return next_requests.load() == 1; }));
  EXPECT_EQ(0, cancelled_requests.load());
  EXPECT_EQ(1, first_requests.load());
}

IN_PROC_BROWSER_TEST_F(BarcApplicationLaunchBrowserTest,
                       ShowTransferClearsUnreturnedRequestWithoutClosingPage) {
  ASSERT_TRUE(base::test::RunUntil([&] { return InitialURLsReady(); }));
  const int32_t destination = barc_window_new_peer(target);
  ASSERT_GT(destination, 0);
  ASSERT_GT(barc_tab_create(destination, "about:blank", 0), 0);
  Admit(destination);
  auto* source = SharedWindow(target);
  ASSERT_TRUE(source);
  auto* view = BrowserView::GetBrowserViewForBrowser(source);
  ASSERT_TRUE(view);
  view->GetWidget()->Hide();
  class TransferOnShow : public views::WidgetObserver {
   public:
    TransferOnShow(views::Widget* widget, int32_t source, int32_t destination)
        : source_(source), destination_(destination) { observation_.Observe(widget); }
    void OnWidgetVisibilityChanged(views::Widget*, bool visible) override {
      if (!visible) return;
      for (size_t index = 0; index < barc_window_tab_count(source_); ++index) {
        const int32_t candidate = barc_window_tab_at(source_, index);
        if (!barc_tab_application_pending(source_, candidate)) continue;
        tab = candidate;
        contents = tabs::TabHandle(tab).Get()->GetContents()->GetWeakPtr();
        observation_.Reset();
        transferred = barc_tab_transfer(source_, tab, destination_);
        return;
      }
    }
    void OnWidgetDestroying(views::Widget*) override { observation_.Reset(); }
    int32_t tab = 0;
    int transferred = 0;
    base::WeakPtr<content::WebContents> contents;
   private:
    const int32_t source_, destination_;
    base::ScopedObservation<views::Widget, views::WidgetObserver> observation_{this};
  } transfer(view->GetWidget(), target, destination);
  BarcApplicationTarget policy{};
  policy.window = target;
  const auto result = barc::CreateApplicationPage(source->GetProfile(), source, policy, 9901);
  EXPECT_EQ(0, result.window);
  EXPECT_EQ(0, result.tab);
  ASSERT_EQ(1, transfer.transferred);
  ASSERT_GT(transfer.tab, 0);
  ASSERT_TRUE(transfer.contents);
  EXPECT_GT(barc_tab_copy_title(destination, transfer.tab, nullptr, 0), 0u);
  EXPECT_EQ(0u, barc_tab_copy_title(target, transfer.tab, nullptr, 0));
  EXPECT_EQ(0, barc_tab_application_pending(destination, transfer.tab));
  EXPECT_EQ(0u, barc_tab_copy_launch_space(destination, transfer.tab, nullptr, 0));
  EXPECT_TRUE(transfer.contents->GetVisibleURL().is_empty() ||
              transfer.contents->GetVisibleURL() == GURL("about:blank"));
}

IN_PROC_BROWSER_TEST_F(BarcApplicationLaunchBrowserTest,
                       CommandLineAndEarlyURLDrainOnceIntoExactModelProfile) {
  ASSERT_TRUE(base::test::RunUntil([&] { return InitialURLsReady(); }));
  std::array<char, 37> identity{};
  ASSERT_EQ(37u,
            barc_window_profile_uuid(target, identity.data(), identity.size()));
  EXPECT_EQ(kSharedWork, std::string(identity.data()));
  const GURL cli("data:text/plain,cli-once");
  const GURL early("data:text/plain,early-once");
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return CountURL(cli) == 1 && CountURL(early) == 1; }));
  EXPECT_EQ(3u, barc_window_tab_count(target));
  [AppController.sharedController openStartupUrls];
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1, CountURL(cli));
  EXPECT_EQ(1, CountURL(early));
  EXPECT_EQ(3u, barc_window_tab_count(target));
  DiscoveryRows rows;
  rows.Read();
  EXPECT_EQ(1u, rows.windows.size());
}

IN_PROC_BROWSER_TEST_F(BarcApplicationLaunchBrowserTest,
                       URLUsesExactOwnerRatherThanAnotherSameProfileWindow) {
  ASSERT_TRUE(base::test::RunUntil([&] { return InitialURLsReady(); }));
  auto* work = SharedWindow(target);
  ASSERT_TRUE(work);
  const int32_t peer = barc_window_new_peer(target);
  ASSERT_GT(peer, 0);
  Admit(peer);
  ASSERT_EQ(work->GetProfile(), SharedWindow(peer)->GetProfile());
  ASSERT_EQ(1, barc_window_select(peer));
  SharedWindow(peer)->GetWindow()->Activate();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return ProfileBrowserCollection::GetForProfile(work->GetProfile())
               ->FindTabbedBrowser() == SharedWindow(peer);
  }));  // Prove the profile-only heuristic would choose the wrong owner.
  const size_t peer_tabs = barc_window_tab_count(peer);
  const size_t work_tabs = barc_window_tab_count(target);
  [AppController.sharedController
      application:NSApp
         openURLs:@[ [NSURL URLWithString:@"data:text/html,exact-owner"] ]];
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return barc_window_tab_count(target) == work_tabs + 1; }));
  EXPECT_EQ(peer_tabs, barc_window_tab_count(peer));
  EXPECT_EQ(1, CountURL(GURL("data:text/html,exact-owner")));
}

IN_PROC_BROWSER_TEST_F(BarcApplicationLaunchBrowserTest,
                       NoWindowCommandsUseExactRegularUUIDAndDockReusesOwner) {
  ASSERT_TRUE(base::test::RunUntil([&] { return InitialURLsReady(); }));
  const int32_t original = target;
  auto* profile = SharedWindow(original)->GetProfile();
  target = 0;
  fallback = true;
  NSMenuItem* item = [[NSMenuItem alloc] init];
  item.tag = IDC_NEW_WINDOW;
  ui_test_utils::BrowserCreatedObserver created;
  [AppController.sharedController commandDispatch:item];
  auto* next = created.Wait();
  ASSERT_TRUE(next);
  EXPECT_EQ(profile, next->GetProfile());
  EXPECT_NE(original, next->GetSessionID().id());
  target = next->GetSessionID().id();
  Admit(target);
  DiscoveryRows rows;
  rows.Read();
  auto row =
      std::find_if(rows.tabs.begin(), rows.tabs.end(),
                   [&](const auto& tab) { return tab.window == target; });
  ASSERT_NE(rows.tabs.end(), row);
  EXPECT_EQ(0u, row->flags & BARC_DISCOVERY_TAB_APP_FACTORY);
  const size_t before = rows.windows.size();
  [AppController.sharedController applicationShouldHandleReopen:NSApp
                                              hasVisibleWindows:NO];
  base::RunLoop().RunUntilIdle();
  rows.Read();
  EXPECT_EQ(before, rows.windows.size());
}

IN_PROC_BROWSER_TEST_F(BarcApplicationLaunchBrowserTest,
                       AsyncRegularTargetChangeCancelsInsteadOfRetargeting) {
  ASSERT_TRUE(base::test::RunUntil([&] { return InitialURLsReady(); }));
  target = 0;
  fallback = true;
  uuid = "275a935d-37a0-434e-a272-d84f9e938bd0";
  base::test::TestFuture<barc::ApplicationBrowserResult,
                         BrowserWindowInterface*, Profile*>
      completed;
  barc::RunInApplicationBrowser(1, completed.GetCallback());
  uuid = kSharedWork;
  ASSERT_TRUE(completed.Wait());
  EXPECT_EQ(barc::ApplicationBrowserResult::kUnavailable, completed.Get<0>());
  EXPECT_EQ(nullptr, completed.Get<1>());
  EXPECT_EQ(nullptr, completed.Get<2>());
}

class BarcCancelledApplicationLaunchBrowserTest
    : public BarcEarlyPostedReturnBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command) override {
    BarcEarlyPostedReturnBrowserTest::SetUpCommandLine(command);
    if (!command->HasSwitch("no-startup-window")) {
      command->AppendSwitch("no-startup-window");
    }
    command->AppendSwitch("barc-native-shell");
    command->AppendSwitch("barc-shared-native-window");
  }

 protected:
  class QueueBeforeAbort : public ChromeBrowserMainExtraParts {
   public:
    void PostBrowserStart() override {
      GlobalBrowserCollection::GetInstance()->ForEach(
          [](BrowserWindowInterface* browser) {
            NSView* header =
                [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
            CHECK(barc_window_attach_native_shell(browser->GetSessionID().id(),
                                                  (__bridge void*)header));
            CHECK(barc_window_admit_discovered(browser->GetSessionID().id(),
                                               (__bridge void*)header));
            return true;
          });
      [AppController.sharedController
          application:NSApp
             openURLs:@[
               [NSURL
                   URLWithString:@"data:text/plain,cancelled-before-ready"]
             ]];
      NSMenuItem* item = [[NSMenuItem alloc] init];
      item.tag = IDC_NEW_WINDOW;
      [AppController.sharedController commandDispatch:item];
      [AppController.sharedController applicationShouldHandleReopen:NSApp
                                                  hasVisibleWindows:NO];
    }
  };
  void CreatedBrowserMainParts(content::BrowserMainParts* parts) override {
    BarcEarlyPostedReturnBrowserTest::CreatedBrowserMainParts(parts);
    static_cast<ChromeBrowserMainParts*>(parts)->AddParts(
        std::make_unique<QueueBeforeAbort>());
  }
};

IN_PROC_BROWSER_TEST_F(
    BarcCancelledApplicationLaunchBrowserTest,
    PendingURLAndWindowRequestsCannotFallBackAfterEarlyStop) {
  ASSERT_TRUE(barc::RuntimeCallbacksClearedForTesting());
  ASSERT_FALSE(barc::IsNativeApplicationRegistered());
  ASSERT_TRUE(barc::IsNativeApplicationMode());
  DiscoveryRows before;
  before.Read();
  [AppController.sharedController openStartupUrls];
  NSMenuItem* item = [[NSMenuItem alloc] init];
  item.tag = IDC_NEW_WINDOW;
  [AppController.sharedController commandDispatch:item];
  [AppController.sharedController applicationShouldHandleReopen:NSApp
                                              hasVisibleWindows:NO];
  base::RunLoop().RunUntilIdle();
  DiscoveryRows after;
  after.Read();
  EXPECT_EQ(before.windows.size(), after.windows.size());
  EXPECT_EQ(before.tabs.size(), after.tabs.size());
  EXPECT_TRUE(after.windows.empty());
  EXPECT_TRUE(after.tabs.empty());
  EXPECT_EQ(0, deliveries);
}

IN_PROC_BROWSER_TEST_F(
    BarcApplicationLaunchBrowserTest,
    URLsDuringAsyncResolutionWaitForAdmissionAndDeliverOnce) {
  ASSERT_TRUE(base::test::RunUntil([&] { return InitialURLsReady(); }));
  const size_t browsers_before =
      GlobalBrowserCollection::GetInstance()->GetSize();
  int revisions = 0;
  const uint64_t token = barc_discovery_observe(
      [](void* context, uint64_t, uint64_t) { ++*static_cast<int*>(context); },
      &revisions);
  ASSERT_NE(0u, token);
  base::ScopedClosureRunner stop(base::BindOnce(
      [](uint64_t token) { barc_discovery_unobserve(token); }, token));
  target = 0;
  fallback = true;
  uuid = "c2f82058-fdcc-41d8-a384-b330ab524a2d";
  OpeningOnCreation mark_opening(this);
  [AppController.sharedController
      application:NSApp
         openURLs:@[ [NSURL URLWithString:@"data:text/plain,first-pending"] ]];
  // This arrives while the real ProfileManager/JSON preference load is pending.
  [AppController.sharedController
      application:NSApp
         openURLs:@[ [NSURL URLWithString:@"data:text/plain,second-pending"] ]];
  ASSERT_TRUE(
      base::test::RunUntil([&] { return created_during_resolution > 0; }));
  const int32_t created = created_during_resolution;
  ASSERT_TRUE(opening);
  EXPECT_EQ(browsers_before + 1,
            GlobalBrowserCollection::GetInstance()->GetSize());
  // Real structural notifications while model admission is still pending must
  // neither create another owner nor consume the queued second URL.
  ASSERT_GT(barc_tab_create(created, "about:blank", 0), 0);
  ASSERT_TRUE(base::test::RunUntil([&] { return revisions > 0; }));
  const int previous_revisions = revisions;
  ASSERT_GT(barc_tab_create(created, "about:blank", 0), 0);
  ASSERT_TRUE(
      base::test::RunUntil([&] { return revisions > previous_revisions; }));
  EXPECT_EQ(browsers_before + 1,
            GlobalBrowserCollection::GetInstance()->GetSize());
  target = created;
  ASSERT_TRUE(base::test::RunUntil([&] {
    BarcDiscoveryWindow pending{};
    return opening && barc_window_discovery_state(created, &pending) &&
           (pending.flags & BARC_DISCOVERY_AWAITING_ADMISSION) &&
           CountURL(GURL("data:text/plain,first-pending")) == 1;
  }));
  EXPECT_EQ(0, CountURL(GURL("data:text/plain,second-pending")));
  opening = false;
  Admit(created);
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return CountURL(GURL("data:text/plain,second-pending")) == 1; }));
  [AppController.sharedController openStartupUrls];
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1, CountURL(GURL("data:text/plain,first-pending")));
  EXPECT_EQ(1, CountURL(GURL("data:text/plain,second-pending")));
  EXPECT_EQ(browsers_before + 1,
            GlobalBrowserCollection::GetInstance()->GetSize());
  const int reads_after_delivery = target_reads;
  const int delivered_revisions = revisions;
  ASSERT_GT(barc_tab_create(created, "about:blank", 0), 0);
  ASSERT_TRUE(
      base::test::RunUntil([&] { return revisions > delivered_revisions; }));
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(reads_after_delivery, target_reads);  // Empty queue does no lookup.
}

IN_PROC_BROWSER_TEST_F(BarcApplicationLaunchBrowserTest,
                       ShutdownDuringAsyncURLResolutionCannotCreateOrRetarget) {
  ASSERT_TRUE(base::test::RunUntil([&] { return InitialURLsReady(); }));
  const size_t before = GlobalBrowserCollection::GetInstance()->GetSize();
  target = 0;
  fallback = true;
  uuid = "b8cb5258-c878-4ddf-9fae-bc1fd449a1f1";
  [AppController.sharedController
      application:NSApp
         openURLs:@[ [NSURL URLWithString:@"data:text/plain,cancel-on-stop"] ]];
  [AppController.sharedController
      application:NSApp
         openURLs:@[ [NSURL
                      URLWithString:@"data:text/plain,also-cancel-on-stop"] ]];
  base::test::TestFuture<barc::ApplicationBrowserResult,
                         BrowserWindowInterface*, Profile*>
      completed;
  barc::RunInApplicationBrowser(1, completed.GetCallback());
  barc::RuntimeStopped();
  EXPECT_TRUE(barc::RuntimeCallbacksClearedForTesting());
  ASSERT_TRUE(completed.Wait());
  EXPECT_EQ(barc::ApplicationBrowserResult::kUnavailable, completed.Get<0>());
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(before, GlobalBrowserCollection::GetInstance()->GetSize());
  [AppController.sharedController openStartupUrls];
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(before, GlobalBrowserCollection::GetInstance()->GetSize());
}

IN_PROC_BROWSER_TEST_F(BarcApplicationLaunchBrowserTest,
                       AsyncUUIDBecomingOpeningRetainsBatchUntilRealAdmission) {
  ASSERT_TRUE(base::test::RunUntil([&] { return InitialURLsReady(); }));
  const size_t before = GlobalBrowserCollection::GetInstance()->GetSize();
  target = 0;
  fallback = true;
  uuid = "70315c5b-246a-4d47-acfc-cc9556c70925";
  [AppController.sharedController
      application:NSApp
         openURLs:@[ [NSURL
                      URLWithString:@"data:text/plain,uuid-then-opening"] ]];
  opening = true;  // Model window preparation begins before async prefs finish.
  [AppController.sharedController
      application:NSApp
         openURLs:@[ [NSURL URLWithString:@"data:text/plain,during-opening"] ]];
  base::test::TestFuture<barc::ApplicationBrowserResult> loaded;
  barc::RunInApplicationBrowser(
      1, base::BindOnce(
             [](base::test::TestFuture<barc::ApplicationBrowserResult>* done,
                barc::ApplicationBrowserResult result, BrowserWindowInterface*,
                Profile*) {
               done->SetValue(
                   result);  // No borrowed Profile escapes this callback.
             },
             base::Unretained(&loaded)));
  ASSERT_TRUE(loaded.Wait());
  EXPECT_EQ(barc::ApplicationBrowserResult::kReady, loaded.Get());
  EXPECT_EQ(before, GlobalBrowserCollection::GetInstance()->GetSize());
  const int32_t prepared = Open(uuid.c_str(), 0, BARC_PROFILE_BLANK);
  ASSERT_GT(prepared, 0);
  target = prepared;
  opening = false;
  int revisions = 0;
  const uint64_t token = barc_discovery_observe(
      [](void* context, uint64_t, uint64_t) { ++*static_cast<int*>(context); },
      &revisions);
  ASSERT_NE(0u, token);
  base::ScopedClosureRunner stop(base::BindOnce(
      [](uint64_t token) { barc_discovery_unobserve(token); }, token));
  Admit(prepared);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return CountURL(GURL("data:text/plain,uuid-then-opening")) == 1 &&
           CountURL(GURL("data:text/plain,during-opening")) == 1;
  }));
  EXPECT_EQ(before + 1, GlobalBrowserCollection::GetInstance()->GetSize());
  [AppController.sharedController openStartupUrls];
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1, CountURL(GURL("data:text/plain,uuid-then-opening")));
  EXPECT_EQ(1, CountURL(GURL("data:text/plain,during-opening")));
}

namespace {
class ReentrantSplitObserver final : public TabStripModelObserver {
 public:
  ReentrantSplitObserver(TabStripModel* strip, int32_t window,
                         BarcSplitLayout replacement)
      : window_(window), replacement_(replacement) {
    strip->AddObserver(this);
  }
  void OnSplitTabChanged(const SplitTabChange& change) override {
    if (attempted || change.type != SplitTabChange::Type::kAdded)
      return;
    attempted = true;
    EXPECT_EQ(0, barc_window_set_split(window_, &replacement_));
  }
  bool attempted = false;
 private:
  const int32_t window_;
  const BarcSplitLayout replacement_;
};
}  // namespace

class BarcFourPaneBrowserTest : public BarcSharedNativeWindowBrowserTest {
 protected:
  void SetUpOnMainThread() override {
    BarcSharedNativeWindowBrowserTest::SetUpOnMainThread();
    // Zoom is host-scoped by default. Give each pane its own real host so the
    // command-routing assertion does not mistake site zoom for a foreign target.
    for (size_t i = 0; i < 4; ++i) {
      host_resolver()->AddRule("split-pane-" + std::to_string(i) + ".test",
                               "127.0.0.1");
    }
  }
};

IN_PROC_BROWSER_TEST_F(BarcFourPaneBrowserTest,
                       FourPaneSplitPreservesLiveDocumentsAndPaneRouting) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t window = browser()->GetSessionID().id();
  auto* view = BrowserView::GetBrowserViewForBrowser(browser());
  auto* multi = view->multi_contents_view();
  const auto initial_containers = view->GetContentsContainerViews();
  ASSERT_EQ(4u, initial_containers.size());
  EXPECT_EQ(1u, multi->GetPaneCount());
  for (size_t i = 1; i < initial_containers.size(); ++i) {
    EXPECT_FALSE(initial_containers[i]->GetVisible());
    EXPECT_FALSE(initial_containers[i]->contents_view()->web_contents());
    EXPECT_FALSE(initial_containers[i]->devtools_web_view()->web_contents());
  }
  std::array<int32_t, 4> handles{};
  std::array<content::WebContents*, 4> pages{};
  std::array<int, 4> histories{};
  handles[0] = barc_window_tab_at(window, 0);
  pages[0] = browser()->GetTabStripModel()->GetActiveWebContents();
  for (size_t i = 1; i < handles.size(); ++i) {
    handles[i] = barc_tab_create(window, "about:blank", 0);
    ASSERT_NE(0, handles[i]);
    pages[i] = tabs::TabHandle(handles[i]).Get()->GetContents();
  }
  for (size_t i = 0; i < pages.size(); ++i) {
    content::TestNavigationObserver navigated(pages[i]);
    ASSERT_EQ(1, barc_tab_navigate(window, handles[i],
        embedded_test_server()->GetURL(
            "split-pane-" + std::to_string(i) + ".test", "/title1.html")
            .spec().c_str()));
    navigated.Wait();
    ASSERT_TRUE(content::WaitForLoadStop(pages[i]));
    ASSERT_TRUE(content::ExecJs(pages[i], content::JsReplace(R"(
      document.body.innerHTML = '<input id="draft"><div style="height:5000px"></div>';
      window.marker = {pane: $1};
      document.querySelector('#draft').value = 'retained-' + $1;
      history.pushState({}, '', '#one');
      history.pushState({}, '', '#two');
      window.scrollTo(0, 400);
    )", static_cast<int>(i))));
    histories[i] = pages[i]->GetController().GetEntryCount();
    ASSERT_GE(histories[i], 3);
  }
  BarcSplitLayout request{4, 0, {handles[2], handles[0], handles[3], handles[1]},
                           {0.2, 0.45, 0.75}, handles[3]};
  ASSERT_EQ(1, barc_window_set_split(window, &request));
  view->DeprecatedLayoutImmediately();
  ExpectPageBelowOnlyNativeTop(view, 0);
  std::array<ContentsContainerView*, 4> containers{};
  for (size_t i = 0; i < pages.size(); ++i) {
    containers[i] = multi->GetContentsContainerViewFor(pages[i]);
    ASSERT_TRUE(containers[i]);
    EXPECT_TRUE(containers[i]->GetVisible());
    EXPECT_FALSE(containers[i]->bounds().IsEmpty());
    EXPECT_EQ(histories[i], pages[i]->GetController().GetEntryCount());
    EXPECT_EQ(400, content::EvalJs(pages[i], "window.scrollY"));
    EXPECT_EQ(static_cast<int>(i), content::EvalJs(pages[i], "window.marker.pane"));
    EXPECT_EQ("retained-" + std::to_string(i),
              content::EvalJs(pages[i], "document.querySelector('#draft').value"));
  }
  for (size_t i = 1; i < request.count; ++i) {
    const auto* previous = multi->GetContentsContainerViewFor(
        tabs::TabHandle(base::span(request.tabs)[i - 1]).Get()->GetContents());
    const auto* next = multi->GetContentsContainerViewFor(
        tabs::TabHandle(base::span(request.tabs)[i]).Get()->GetContents());
    EXPECT_LE(previous->bounds().right(), next->bounds().x());
  }
  BarcSplitLayout actual{};
  ASSERT_EQ(1, barc_window_get_split(window, 0, &actual));
  EXPECT_EQ(4u, actual.count);
  EXPECT_EQ(request.orientation, actual.orientation);
  EXPECT_TRUE(std::ranges::equal(base::span(request.dividers),
                                base::span(actual.dividers)));
  EXPECT_EQ(handles[3], actual.active_tab);
  ASSERT_EQ(1, barc_tab_execute_command(window, handles[3], BARC_PAGE_ZOOM_IN));
  EXPECT_GT(zoom::ZoomController::FromWebContents(pages[3])->GetZoomLevel(), 0);
  EXPECT_EQ(0, zoom::ZoomController::FromWebContents(pages[0])->GetZoomLevel());
  EXPECT_EQ(0, barc_tab_execute_command(window, handles[0], BARC_PAGE_ZOOM_IN));

  // Reorder exactly the same four pages and change orientation. Native content
  // containers, documents, form data and controller histories remain their own.
  request = {4, 1, {handles[1], handles[3], handles[0], handles[2]},
                   {0.15, 0.55, 0.8}, handles[0]};
  ASSERT_EQ(1, barc_window_set_split(window, &request));
  view->DeprecatedLayoutImmediately();
  for (size_t i = 0; i < pages.size(); ++i) {
    EXPECT_EQ(containers[i], multi->GetContentsContainerViewFor(pages[i]));
    EXPECT_EQ(histories[i], pages[i]->GetController().GetEntryCount());
    EXPECT_EQ("retained-" + std::to_string(i),
              content::EvalJs(pages[i], "document.querySelector('#draft').value"));
  }
  for (size_t i = 1; i < request.count; ++i) {
    const auto* previous = multi->GetContentsContainerViewFor(
        tabs::TabHandle(base::span(request.tabs)[i - 1]).Get()->GetContents());
    const auto* next = multi->GetContentsContainerViewFor(
        tabs::TabHandle(base::span(request.tabs)[i]).Get()->GetContents());
    EXPECT_LE(previous->bounds().bottom(), next->bounds().y());
  }
  multi->OnResizeDivider(1, 25, true);
  ASSERT_EQ(1, barc_window_get_split(window, 0, &actual));
  EXPECT_DOUBLE_EQ(0.15, base::span(actual.dividers)[0]);
  EXPECT_NE(0.55, base::span(actual.dividers)[1]);
  EXPECT_DOUBLE_EQ(0.8, base::span(actual.dividers)[2]);
  const BarcSplitLayout resized = actual;
  ASSERT_EQ(1, barc_window_clear_split(window, 0, &actual));
  EXPECT_EQ(0, barc_window_get_split(window, 0, &actual));
  EXPECT_EQ(4u, barc_window_tab_count(window));
  EXPECT_EQ(handles[0], browser()->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
  EXPECT_EQ(containers[0], multi->GetActiveContentsContainerView());
  ASSERT_EQ(1, barc_tab_go_back(window, handles[0]));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return pages[0]->GetLastCommittedURL().ref() == "one";
  }));
  // The real desktop session-restoration seam accepts the whole ordered set,
  // not a truncated leading/trailing pair, and preserves all divider metadata.
  auto* context = BrowserLiveTabContext::From(browser());
  ASSERT_TRUE(context);
  std::vector<sessions::LiveTab*> restored;
  for (int32_t handle : base::span(request.tabs)) {
    restored.push_back(context->GetLiveTabAt(
        browser()->GetTabStripModel()->GetIndexOfTab(tabs::TabHandle(handle).Get())));
  }
  const auto restored_id = split_tabs::SplitTabId::GenerateNew();
  const split_tabs::SplitTabVisualData restored_data(
      split_tabs::SplitTabLayout::kStacked, base::span(resized.dividers));
  context->ReconstructSplitTabs(restored, restored_id, restored_data);
  EXPECT_EQ(restored_id, browser()->GetTabStripModel()->GetActiveTab()->GetSplit());
  ASSERT_EQ(1, barc_window_get_split(window, 0, &actual));
  EXPECT_EQ(4u, actual.count);
  EXPECT_TRUE(std::ranges::equal(base::span(actual.tabs), base::span(request.tabs)));
  EXPECT_TRUE(std::ranges::equal(base::span(actual.dividers),
                                restored_data.split_dividers()));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       SplitRemovalTransferAndAdmissionKeepExactOwners) {
  const int32_t window = browser()->GetSessionID().id();
  std::array<int32_t, 4> handles{barc_window_tab_at(window, 0)};
  for (size_t i = 1; i < handles.size(); ++i) {
    handles[i] = barc_tab_create(window, "about:blank", 0);
    ASSERT_NE(0, handles[i]);
  }
  BarcSplitLayout request{4, 0, {handles[0], handles[1], handles[2], handles[3]},
                           {0.25, 0.5, 0.75}, handles[1]};
  ASSERT_EQ(1, barc_window_set_split(window, &request));
  const auto original_split = browser()->GetTabStripModel()->GetActiveTab()->GetSplit();
  auto* transferred = tabs::TabHandle(handles[3]).Get()->GetContents();
  ASSERT_TRUE(content::ExecJs(transferred, "window.marker = {live: 1};"));
  const int32_t peer_id = barc_window_new_peer(window);
  ASSERT_NE(0, peer_id);
  ASSERT_EQ(1, barc_tab_transfer(window, handles[3], peer_id));
  EXPECT_EQ(transferred, tabs::TabHandle(handles[3]).Get()->GetContents());
  EXPECT_EQ(1, content::EvalJs(transferred, "window.marker.live"));
  EXPECT_EQ(original_split, browser()->GetTabStripModel()->GetActiveTab()->GetSplit());
  BarcSplitLayout state{};
  ASSERT_EQ(1, barc_window_get_split(window, 0, &state));
  EXPECT_EQ(3u, state.count);
  EXPECT_DOUBLE_EQ(1.0 / 3, base::span(state.dividers)[0]);
  EXPECT_DOUBLE_EQ(2.0 / 3, base::span(state.dividers)[1]);
  ASSERT_EQ(1, barc_window_select(window));
  // Exercise the real Cmd-W command: selection includes all three panes,
  // but this command must close only the active pane.
  chrome::CloseTab(browser());
  ASSERT_TRUE(base::test::RunUntil([&] { return !tabs::TabHandle(handles[1]).Get(); }));
  ASSERT_EQ(1, barc_window_get_split(window, 0, &state));
  EXPECT_EQ(2u, state.count);
  EXPECT_EQ(handles[2], state.active_tab);
  auto* multi = BrowserView::GetBrowserViewForBrowser(browser())->multi_contents_view();
  EXPECT_EQ(multi->GetContentsContainerViewFor(
                tabs::TabHandle(handles[2]).Get()->GetContents()),
            multi->GetActiveContentsContainerView());
  EXPECT_EQ(original_split, browser()->GetTabStripModel()->GetActiveTab()->GetSplit());
  ASSERT_EQ(1, barc_tab_close(window, handles[2]));
  ASSERT_TRUE(base::test::RunUntil([&] { return !tabs::TabHandle(handles[2]).Get(); }));
  EXPECT_EQ(0, barc_window_get_split(window, 0, &state));
  EXPECT_EQ(1u, barc_window_tab_count(window));
  EXPECT_EQ(handles[0], browser()->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());

  // A different profile or a stale/duplicate handle is refused before mutation.
  const int32_t personal = Open(kSharedPersonal, 0, BARC_PROFILE_BLANK);
  const int32_t foreign = barc_window_tab_at(personal, 0);
  request = {2, 0, {handles[0], foreign}, {0.5}, handles[0]};
  EXPECT_EQ(0, barc_window_set_split(window, &request));
  request.tabs[1] = handles[0];
  EXPECT_EQ(0, barc_window_set_split(window, &request));
  request.tabs[1] = handles[1];
  EXPECT_EQ(0, barc_window_set_split(window, &request));
  EXPECT_EQ(1u, barc_window_tab_count(window));
  EXPECT_EQ(1u, barc_window_tab_count(personal));
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       SplitCatalogSettlesAndCommitsFinalResize) {
  const int32_t window = browser()->GetSessionID().id();
  std::array<int32_t, 4> handles{barc_window_tab_at(window, 0)};
  for (size_t i = 1; i < handles.size(); ++i) {
    handles[i] = barc_tab_create(window, "about:blank", 0);
    ASSERT_NE(0, handles[i]);
    ASSERT_TRUE(content::WaitForLoadStop(tabs::TabHandle(handles[i]).Get()->GetContents()));
  }
  DiscoveryEvents events;
  const auto token = barc_discovery_observe(DiscoveryEvents::Receive, &events);
  ASSERT_NE(0u, token);
  base::ScopedClosureRunner unsubscribe(base::BindOnce(barc_discovery_unobserve, token));
  base::RunLoop().RunUntilIdle();
  events.revisions.clear();
  BarcSplitLayout request{4, 0, {handles[0], handles[1], handles[2], handles[3]},
                           {0.25, 0.5, 0.75}, handles[0]};
  auto replacement = request;
  replacement.orientation = 1;
  replacement.dividers[1] = 0.6;
  ReentrantSplitObserver reentrant(browser()->GetTabStripModel(), window,
                                    replacement);
  ASSERT_EQ(1, barc_window_set_split(window, &request));
  EXPECT_TRUE(reentrant.attempted);
  EXPECT_TRUE(events.revisions.empty());
  base::RunLoop().RunUntilIdle();
  ASSERT_EQ(1u, events.revisions.size());
  const auto settled = events.revisions.size();
  ASSERT_EQ(1, barc_window_set_split(window, &request));
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(settled, events.revisions.size());

  auto* strip = browser()->GetTabStripModel();
  const auto split = strip->GetActiveTab()->GetSplit();
  ASSERT_TRUE(split);
  const std::array<double, 3> resized{0.25, 0.6, 0.75};
  strip->UpdateSplitDividers(*split, resized, /*is_intermediate=*/true);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(settled, events.revisions.size());
  // Finalization must notify even when its values equal the last drag update.
  strip->UpdateSplitDividers(*split, resized, /*is_intermediate=*/false);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(settled + 1, events.revisions.size());
  BarcSplitLayout actual{};
  ASSERT_EQ(1, barc_window_get_split(window, 0, &actual));
  EXPECT_DOUBLE_EQ(0.6, base::span(actual.dividers)[1]);
  const auto final_count = events.revisions.size();
  barc_discovery_unobserve(token);
  strip->UpdateSplitDividers(*split, base::span(request.dividers), false);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(final_count, events.revisions.size());
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       FailedSplitTransferRestoresGeometryWithoutReselectingOwner) {
  const int32_t window = browser()->GetSessionID().id();
  std::array<int32_t, 4> handles{barc_window_tab_at(window, 0)};
  std::array<content::WebContents*, 4> pages{};
  for (size_t i = 0; i < handles.size(); ++i) {
    if (i != 0)
      handles[i] = barc_tab_create(window, "about:blank", 0);
    ASSERT_NE(0, handles[i]);
    pages[i] = tabs::TabHandle(handles[i]).Get()->GetContents();
    ASSERT_TRUE(content::WaitForLoadStop(pages[i]));
    ASSERT_TRUE(content::ExecJs(pages[i], content::JsReplace(R"(
      document.body.innerHTML = '<input id="draft">';
      window.marker = {pane: $1};
      document.querySelector('#draft').value = 'split-' + $1;
    )", static_cast<int>(i))));
  }
  const BarcSplitLayout request{4, 1,
      {handles[0], handles[1], handles[2], handles[3]},
      {0.18, 0.43, 0.78}, handles[1]};
  ASSERT_EQ(1, barc_window_set_split(window, &request));
  auto* strip = browser()->GetTabStripModel();
  const auto split_id = strip->GetActiveTab()->GetSplit();
  ASSERT_TRUE(split_id);
  auto* const source_widget =
      BrowserView::GetBrowserViewForBrowser(browser())->browser_widget();
  const int32_t personal = Open(kSharedPersonal, window, BARC_PROFILE_BLANK);
  ASSERT_NE(0, personal);
  for (size_t moving : {3u, 1u, 0u}) {
    SCOPED_TRACE(moving);
    ASSERT_EQ(1, barc_window_select(window));
    const int32_t destination = barc_window_new_peer(window);
    ASSERT_NE(0, destination);
    CloseTransferDestination cancel(strip, destination, personal);
    ASSERT_EQ(0, barc_tab_transfer(window, handles[moving], destination));
    ASSERT_TRUE(cancel.called());
    EXPECT_FALSE(browser()->IsDeleteScheduled());
    EXPECT_EQ(4, strip->count());
    EXPECT_FALSE(UnloadController::From(browser())->is_attempting_to_close_browser());
    EXPECT_EQ(split_id, strip->GetActiveTab()->GetSplit());
    EXPECT_EQ(handles[1], strip->GetActiveTab()->GetHandle().raw_value());
    EXPECT_EQ(SharedWindow(personal), source_widget->selected_browser_view()->browser());
    BarcSplitLayout actual{};
    ASSERT_EQ(1, barc_window_get_split(window, 0, &actual));
    EXPECT_EQ(request.count, actual.count);
    EXPECT_EQ(request.orientation, actual.orientation);
    EXPECT_TRUE(std::ranges::equal(base::span(request.tabs), base::span(actual.tabs)));
    EXPECT_TRUE(std::ranges::equal(base::span(request.dividers), base::span(actual.dividers)));
    for (size_t i = 0; i < handles.size(); ++i) {
      auto* tab = tabs::TabHandle(handles[i]).Get();
      ASSERT_TRUE(tab);
      EXPECT_EQ(browser(), tab->GetBrowserWindowInterface());
      EXPECT_EQ(pages[i], tab->GetContents());
      EXPECT_EQ(static_cast<int>(i), content::EvalJs(pages[i], "window.marker.pane"));
      EXPECT_EQ("split-" + std::to_string(i),
                content::EvalJs(pages[i], "document.querySelector('#draft').value"));
    }
  }
}

#if BUILDFLAG(ENTERPRISE_SCREENSHOT_PROTECTION)
IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       SplitCapturePolicyFollowsPresentedPanes) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t window = browser()->GetSessionID().id();
  const GURL blocked = embedded_test_server()->GetURL("/title2.html");
  data_controls::SetDataControls(browser()->GetProfile()->GetPrefs(), {
      "{\"name\":\"split-capture\",\"rule_id\":\"split-capture\","
      "\"sources\":{\"urls\":[\"" + blocked.spec() + "\"]},"
      "\"restrictions\":[{\"class\":\"SCREENSHOT\",\"level\":\"BLOCK\"}]}"});
  std::array<int32_t, 4> handles{barc_window_tab_at(window, 0)};
  for (size_t i = 1; i < handles.size(); ++i) {
    handles[i] = barc_tab_create(window, "about:blank", 0);
    ASSERT_NE(0, handles[i]);
  }
  for (size_t i = 0; i < handles.size(); ++i) {
    auto* contents = tabs::TabHandle(handles[i]).Get()->GetContents();
    content::TestNavigationObserver navigation(contents);
    const GURL url = i == 3 ? blocked : embedded_test_server()->GetURL("/title1.html");
    ASSERT_EQ(1, barc_tab_navigate(window, handles[i], url.spec().c_str()));
    navigation.Wait();
    ASSERT_TRUE(content::WaitForLoadStop(contents));
  }
  auto* protected_contents = tabs::TabHandle(handles[3]).Get()->GetContents();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return enterprise_data_protection::IsScreenShareBlocked(protected_contents);
  }));
  auto* widget = BrowserView::GetBrowserViewForBrowser(browser())->browser_widget();
  ASSERT_TRUE(widget->AreScreenshotsAllowed());
  // Preserve the existing two-pane path as well as the extra enrolled panes.
  BarcSplitLayout actual{};
  BarcSplitLayout request{2, 0, {handles[0], handles[3]}, {0.5}, handles[0]};
  ASSERT_EQ(1, barc_window_set_split(window, &request));
  EXPECT_FALSE(widget->AreScreenshotsAllowed());
  ASSERT_EQ(1, barc_window_get_split(window, 0, &actual));
  ASSERT_EQ(1, barc_window_clear_split(window, 0, &actual));
  EXPECT_TRUE(widget->AreScreenshotsAllowed());
  request = {4, 0, {handles[0], handles[1], handles[2], handles[3]},
             {0.25, 0.5, 0.75}, handles[0]};
  ASSERT_EQ(1, barc_window_set_split(window, &request));
  EXPECT_FALSE(widget->AreScreenshotsAllowed());
  ASSERT_EQ(1, barc_window_get_split(window, 0, &actual));
  ASSERT_EQ(1, barc_window_clear_split(window, 0, &actual));
  EXPECT_TRUE(widget->AreScreenshotsAllowed());
  EXPECT_EQ(protected_contents, tabs::TabHandle(handles[3]).Get()->GetContents());
}
#endif

namespace {
class ReentrantResizeDelegate final : public MultiContentsViewDelegateImpl {
 public:
  ReentrantResizeDelegate(BrowserWindowInterface& browser,
                          base::OnceClosure action)
      : MultiContentsViewDelegateImpl(browser), action_(std::move(action)) {}
  void ResizeDividers(base::span<const double>, bool) override {
    auto action = std::move(action_);
    std::move(action).Run();
  }
 private:
  base::OnceClosure action_;
};
}  // namespace

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       ResizeCallbackCanShrinkCloseOrDestroyPresentedSplit) {
  auto* browser_view = BrowserView::GetBrowserViewForBrowser(browser());
  // Exercise actual Views ownership without violating TabStripModel's ban on
  // reentrant mutations from its own observer callbacks.
  for (int mode = 0; mode < 3; ++mode) {
    SCOPED_TRACE(mode);
    MultiContentsView* multi = nullptr;
    bool called = false;
    auto delegate = std::make_unique<ReentrantResizeDelegate>(
        *browser(), base::BindLambdaForTesting([&] {
          called = true;
          if (mode == 0) {
            multi->ShowSplitView(split_tabs::SplitTabVisualData(
                split_tabs::SplitTabLayout::kSideBySide, 0.5));
          } else if (mode == 1) {
            multi->CloseSplitView();
          } else {
            browser_view->RemoveChildViewT(multi).reset();
          }
        }));
    multi = browser_view->AddChildView(std::make_unique<MultiContentsView>(
        browser_view, std::move(delegate)));
    multi->SetBounds(0, 0, 1000, 600);
    const std::array<double, 3> dividers{0.25, 0.5, 0.75};
    multi->ShowSplitView(split_tabs::SplitTabVisualData(
        split_tabs::SplitTabLayout::kSideBySide, dividers));
    multi->DeprecatedLayoutImmediately();
    std::vector<MultiContentsResizeArea*> areas;
    for (const auto& child : multi->children()) {
      if (auto* area = views::AsViewClass<MultiContentsResizeArea>(child.get()))
        areas.push_back(area);
    }
    ASSERT_EQ(3u, areas.size());
    ASSERT_FALSE(areas.back()->bounds().IsEmpty());
    views::ViewTracker alive(multi);
    const ui::KeyEvent key(ui::EventType::kKeyPressed, ui::VKEY_RIGHT,
                           ui::EF_NONE);
    EXPECT_TRUE(areas.back()->OnKeyPressed(key));
    EXPECT_TRUE(called);
    if (mode == 2) {
      EXPECT_FALSE(alive);
    } else {
      ASSERT_TRUE(alive);
      EXPECT_EQ(mode == 0 ? 2u : 1u, multi->GetPaneCount());
      browser_view->RemoveChildViewT(multi).reset();
    }
  }
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       SplitReplacementClearsOnlyExactInactiveCollection) {
  const int32_t work = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  ASSERT_NE(0, work);
  const int32_t first = barc_window_tab_at(work, 0);
  const int32_t second = barc_tab_create(work, "about:blank", 0);
  const int32_t unrelated = barc_tab_create(work, "about:blank", 0);
  ASSERT_NE(0, second);
  ASSERT_NE(0, unrelated);
  auto* page = tabs::TabHandle(first).Get()->GetContents();
  ASSERT_TRUE(content::WaitForLoadStop(page));
  ASSERT_TRUE(content::ExecJs(page,
      "window.marker={live:1}; document.body.innerHTML='<input id=draft>';"
      "draft.value='old-pane';"));
  ASSERT_EQ(1, barc_tab_select(work, first));
  BarcSplitLayout old_request{2, 0, {first, second}, {0.4}, first, 0};
  ASSERT_EQ(1, barc_window_set_split(work, &old_request));
  BarcSplitLayout old{};
  ASSERT_EQ(1, barc_window_get_split(work, first, &old));
  ASSERT_GT(old.collection, 0);
  ASSERT_EQ(1, barc_tab_select(work, unrelated));
  BarcSplitLayout untouched{};
  untouched.count = 99;
  EXPECT_EQ(0, barc_window_get_split(work, 0, &untouched));
  EXPECT_EQ(99u, untouched.count);
  ASSERT_EQ(1, barc_window_get_split(work, first, &old));
  EXPECT_EQ(0, old.active_tab);

  const int32_t personal = Open(kSharedPersonal, work, BARC_PROFILE_BLANK);
  const int32_t personal_first = barc_window_tab_at(personal, 0);
  const int32_t personal_second = barc_tab_create(personal, "about:blank", 0);
  ASSERT_NE(0, personal_second);
  ASSERT_EQ(1, barc_tab_select(personal, personal_first));
  BarcSplitLayout replacement{2, 1, {personal_first, personal_second},
                               {0.6}, personal_first, 0};
  ASSERT_EQ(1, barc_window_set_split(personal, &replacement));
  BarcSplitLayout new_layout{};
  ASSERT_EQ(1, barc_window_get_split(personal, 0, &new_layout));
  BarcDiscoveryWindow before{};
  ASSERT_EQ(1, barc_window_discovery_state(personal, &before));
  ASSERT_EQ(personal, before.selected_client);
  ASSERT_EQ(1, barc_window_clear_split(work, first, &old));
  EXPECT_EQ(unrelated, SharedWindow(work)->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
  EXPECT_EQ(0, barc_window_get_split(work, first, &untouched));
  EXPECT_EQ(page, tabs::TabHandle(first).Get()->GetContents());
  EXPECT_EQ(1, content::EvalJs(page, "marker.live"));
  EXPECT_EQ("old-pane", content::EvalJs(page, "draft.value"));
  BarcDiscoveryWindow after{};
  ASSERT_EQ(1, barc_window_discovery_state(personal, &after));
  EXPECT_EQ(before.physical_group, after.physical_group);
  EXPECT_EQ(before.selected_client, after.selected_client);
  EXPECT_EQ(before.active_tab, after.active_tab);
  EXPECT_EQ(before.flags & (BARC_DISCOVERY_PHYSICAL_ACTIVE | BARC_DISCOVERY_PHYSICAL_VISIBLE),
            after.flags & (BARC_DISCOVERY_PHYSICAL_ACTIVE | BARC_DISCOVERY_PHYSICAL_VISIBLE));

  // Equal geometry after remove/recreate is a different existing collection.
  ASSERT_EQ(1, barc_tab_select(work, first));
  ASSERT_EQ(1, barc_window_set_split(work, &old_request));
  ASSERT_EQ(1, barc_window_get_split(work, first, &old));
  ASSERT_EQ(1, barc_window_clear_split(work, first, &old));
  ASSERT_EQ(1, barc_window_set_split(work, &old_request));
  BarcSplitLayout recreated{};
  ASSERT_EQ(1, barc_window_get_split(work, first, &recreated));
  EXPECT_NE(old.collection, recreated.collection);
  ASSERT_EQ(1, barc_tab_select(personal, personal_first));
  EXPECT_EQ(0, barc_window_clear_split(work, first, &old));
  // A later background native resize likewise wins over the old expectation.
  auto* strip = SharedWindow(work)->GetTabStripModel();
  const auto split = tabs::TabHandle(first).Get()->GetSplit();
  ASSERT_TRUE(split);
  const std::array<double, 1> resized{0.7};
  strip->UpdateSplitDividers(*split, resized, false);
  EXPECT_EQ(0, barc_window_clear_split(work, first, &recreated));
  BarcSplitLayout current{};
  ASSERT_EQ(1, barc_window_get_split(work, first, &current));
  EXPECT_EQ(recreated.collection, current.collection);
  EXPECT_DOUBLE_EQ(0.7, base::span(current.dividers)[0]);
  BarcSplitLayout still_new{};
  ASSERT_EQ(1, barc_window_get_split(personal, 0, &still_new));
  EXPECT_EQ(new_layout.collection, still_new.collection);
  EXPECT_EQ(new_layout.active_tab, still_new.active_tab);
  ASSERT_EQ(1, barc_window_discovery_state(personal, &after));
  EXPECT_EQ(personal, after.selected_client);
  EXPECT_EQ(personal_first, after.active_tab);
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       DisjointSplitReplacementWithinClientKeepsNewSelection) {
  const int32_t window = browser()->GetSessionID().id();
  std::array<int32_t, 4> handles{barc_window_tab_at(window, 0)};
  for (size_t i = 1; i < handles.size(); ++i) {
    handles[i] = barc_tab_create(window, "about:blank", 0);
    ASSERT_NE(0, handles[i]);
  }
  const BarcSplitLayout initial{2, 0, {handles[0], handles[1]}, {0.4}, handles[0], 0};
  ASSERT_EQ(1, barc_window_set_split(window, &initial));
  BarcSplitLayout old{};
  ASSERT_EQ(1, barc_window_get_split(window, handles[0], &old));
  EXPECT_EQ(handles[0], old.active_tab);
  const BarcSplitLayout replacement{2, 1, {handles[2], handles[3]}, {0.6}, handles[3], 0};
  ASSERT_EQ(1, barc_window_set_split(window, &replacement));
  BarcSplitLayout selected{};
  ASSERT_EQ(1, barc_window_get_split(window, 0, &selected));
  ASSERT_NE(old.collection, selected.collection);
  EXPECT_EQ(handles[3], selected.active_tab);
  // Only the new Set's own active-member change is normalized for cleanup.
  EXPECT_EQ(0, barc_window_clear_split(window, handles[0], &old));
  old.active_tab = 0;
  ASSERT_EQ(1, barc_window_clear_split(window, handles[0], &old));
  BarcSplitLayout current{};
  ASSERT_EQ(1, barc_window_get_split(window, 0, &current));
  EXPECT_EQ(selected.collection, current.collection);
  EXPECT_EQ(selected.active_tab, current.active_tab);
  EXPECT_EQ(selected.orientation, current.orientation);
  EXPECT_DOUBLE_EQ(selected.dividers[0], current.dividers[0]);
  EXPECT_EQ(0, barc_window_get_split(window, handles[0], &current));
  EXPECT_EQ(4u, barc_window_tab_count(window));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       VideoPictureInPictureUsesExactPageAndObservedState) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t tab_id = barc_window_tab_at(work_id, 0);
  EXPECT_EQ(0, barc_tab_execute_command(work_id, tab_id, BARC_PAGE_VIDEO_PIP_TOGGLE));
  Navigate(work, embedded_test_server()->GetURL("/media/picture-in-picture/pixel_test.html"));
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_EQ(true, content::EvalJs(contents, "play()"));
  auto* media = content::MediaSession::Get(contents);
  ASSERT_TRUE(base::test::RunUntil([&] {
    const auto actions = media->GetMediaSessionActionsSync();
    return std::ranges::find(actions, media_session::mojom::MediaSessionAction::kEnterPictureInPicture) != actions.end();
  }));
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, tab_id, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  ASSERT_FALSE(events.events.empty());
  EXPECT_NE(0u, events.events.back().flags & BARC_TAB_PIP_STATE_KNOWN);
  EXPECT_EQ(0u, events.events.back().flags & (BARC_TAB_VIDEO_PIP | BARC_TAB_DOCUMENT_PIP));
  const int32_t other = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  ASSERT_GT(other, 0);
  ASSERT_EQ(1, barc_tab_select(other, barc_window_tab_at(other, 0)));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, tab_id, BARC_PAGE_VIDEO_PIP_TOGGLE));
  EXPECT_EQ(0, barc_tab_execute_command(other, tab_id, BARC_PAGE_VIDEO_PIP_TOGGLE));
  EXPECT_FALSE(contents->HasPictureInPictureVideo());
  ASSERT_EQ(1, barc_tab_select(work_id, tab_id));
  ASSERT_EQ(1, barc_tab_execute_command(work_id, tab_id, BARC_PAGE_VIDEO_PIP_TOGGLE));
  ASSERT_TRUE(base::test::RunUntil([&] { return contents->HasPictureInPictureVideo(); }));
  EXPECT_NE(0u, events.events.back().flags & BARC_TAB_VIDEO_PIP);
  EXPECT_EQ(0u, events.events.back().flags & BARC_TAB_DOCUMENT_PIP);
  ASSERT_EQ(1, barc_tab_execute_command(work_id, tab_id, BARC_PAGE_VIDEO_PIP_TOGGLE));
  ASSERT_TRUE(base::test::RunUntil([&] { return !contents->HasPictureInPictureVideo(); }));
  EXPECT_EQ(0u, events.events.back().flags & BARC_TAB_VIDEO_PIP);
  // Actual document PiP is observed separately, and this video command refuses it.
  ASSERT_TRUE(content::ExecJs(contents,
      "window.testDocumentPip = await documentPictureInPicture.requestWindow({width:320,height:240})"));
  ASSERT_TRUE(base::test::RunUntil([&] { return contents->HasPictureInPictureDocument(); }));
  EXPECT_NE(0u, events.events.back().flags & BARC_TAB_DOCUMENT_PIP);
  EXPECT_EQ(0, barc_tab_execute_command(work_id, tab_id, BARC_PAGE_VIDEO_PIP_TOGGLE));
  EXPECT_TRUE(contents->HasPictureInPictureDocument());
  ASSERT_TRUE(content::ExecJs(contents, "window.testDocumentPip.close()"));
  ASSERT_TRUE(base::test::RunUntil([&] { return !contents->HasPictureInPictureDocument(); }));
  EXPECT_EQ(0u, events.events.back().flags & BARC_TAB_DOCUMENT_PIP);
  const int32_t peer = barc_window_new_peer(work_id);
  ASSERT_GT(peer, 0);
  ASSERT_EQ(1, barc_tab_transfer(work_id, tab_id, peer));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, tab_id, BARC_PAGE_VIDEO_PIP_TOGGLE));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       SplitMiddlePaneUpdateKeepsOrderAndAccessibleLabels) {
  const int32_t window = browser()->GetSessionID().id();
  auto* strip = browser()->GetTabStripModel();
  for (auto update : {TabStripModel::SplitUpdateType::kReplace,
                      TabStripModel::SplitUpdateType::kSwap}) {
    for (uint32_t orientation : {0u, 1u}) {
      std::array<int32_t, 5> handles{};
      for (auto& handle : handles) {
        handle = barc_tab_create(window, "about:blank", 0);
        ASSERT_NE(0, handle);
      }
      BarcSplitLayout request{4, orientation,
          {handles[0], handles[1], handles[2], handles[3]},
          {0.2, 0.45, 0.75}, handles[0]};
      ASSERT_EQ(1, barc_window_set_split(window, &request));
      const auto id = tabs::TabHandle(handles[0]).Get()->GetSplit();
      ASSERT_TRUE(id);
      auto check_labels = [&](const BarcSplitLayout& layout) {
        for (size_t i = 0; i < layout.count; ++i) {
          const auto suffix = l10n_util::GetStringFUTF16(
              layout.orientation == 0
                  ? IDS_TAB_AX_LABEL_SPLIT_TAB_HORIZONTAL_PANE_FORMAT
                  : IDS_TAB_AX_LABEL_SPLIT_TAB_VERTICAL_PANE_FORMAT,
              u"", base::NumberToString16(i + 1),
              base::NumberToString16(layout.count));
          EXPECT_NE(std::u16string::npos,
                    tabs::GetAccessibleTabLabel(
                        tabs::TabHandle(base::span(layout.tabs)[i]).Get(), true)
                        .find(suffix));
        }
      };
      check_labels(request);
      strip->ReverseTabsInSplit(*id);
      BarcSplitLayout reversed{};
      ASSERT_EQ(1, barc_window_get_split(window, handles[0], &reversed));
      EXPECT_EQ(handles[3], base::span(reversed.tabs)[0]);
      check_labels(reversed);
      strip->ReverseTabsInSplit(*id);
      strip->UpdateTabInSplit(tabs::TabHandle(handles[1]).Get(),
          strip->GetIndexOfTab(tabs::TabHandle(handles[4]).Get()), update);
      BarcSplitLayout actual{};
      ASSERT_EQ(1, barc_window_get_split(window, handles[0], &actual));
      EXPECT_EQ(4u, actual.count);
      EXPECT_EQ(handles[0], actual.active_tab);
      EXPECT_EQ(id, tabs::TabHandle(handles[4]).Get()->GetSplit());
      const std::array<int32_t, 4> expected{
          handles[0], handles[4], handles[2], handles[3]};
      EXPECT_TRUE(std::ranges::equal(base::span(actual.tabs), expected));
      EXPECT_TRUE(std::ranges::equal(base::span(actual.dividers),
                                    base::span(request.dividers)));
      check_labels(actual);
      // Removing the third pane must update every remaining ordinal/count.
      ASSERT_EQ(1, barc_tab_close(window, handles[2]));
      ASSERT_TRUE(base::test::RunUntil([&] {
        return !tabs::TabHandle(handles[2]).Get();
      }));
      ASSERT_EQ(1, barc_window_get_split(window, handles[0], &actual));
      EXPECT_EQ(3u, actual.count);
      check_labels(actual);
      ASSERT_EQ(1, barc_window_clear_split(window, handles[0], &actual));
    }
  }
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       BackgroundMediaTransportAndMetadataKeepExactOwner) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  const int32_t tab_id = barc_window_tab_at(work_id, 0);
  auto* existing = content::MediaSession::GetIfExists(contents);
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, tab_id, NavigationEvents::Receive, &events);
  ASSERT_EQ(1, barc_tab_observe_media(events.token, NavigationEvents::ReceiveMedia));
  EXPECT_EQ(existing, content::MediaSession::GetIfExists(contents));
  EXPECT_EQ(0, barc_tab_observe_media(events.token, NavigationEvents::ReceiveMedia));
  Navigate(work, embedded_test_server()->GetURL("/media/picture-in-picture/pixel_test.html"));
  ASSERT_EQ(true, content::EvalJs(contents, R"((async () => {
    await play(); window.nextCount = 0; window.previousCount = 0;
    navigator.mediaSession.metadata = new MediaMetadata({title:'Track A', artist:'Artist A', album:'Album A'});
    navigator.mediaSession.setActionHandler('nexttrack', () => {
      window.nextCount++; navigator.mediaSession.metadata = new MediaMetadata({title:'Track B'});
    });
    navigator.mediaSession.setActionHandler('previoustrack', () => window.previousCount++);
    return true;
  })())"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !events.media.empty() && events.media.back().title == "Track A" &&
        (events.media.back().flags & BARC_MEDIA_PLAYING);
  }));
  EXPECT_EQ("Artist A", events.media.back().artist);
  EXPECT_EQ("Album A", events.media.back().album);
  const int32_t other = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  const int32_t other_tab = barc_window_tab_at(other, 0);
  ASSERT_EQ(1, barc_tab_select(other, other_tab));
  EXPECT_EQ(0, barc_tab_media_action(other, tab_id, BARC_MEDIA_PAUSE));
  EXPECT_EQ(0, barc_tab_media_action(work_id, tab_id, -1));
  ASSERT_EQ(1, barc_tab_media_action(work_id, tab_id, BARC_MEDIA_PAUSE));
  ASSERT_EQ(true, content::EvalJs(contents, "video.paused || new Promise(r => video.addEventListener('pause', () => r(true), {once:true}))"));
  ASSERT_TRUE(base::test::RunUntil([&] { return !(events.media.back().flags & BARC_MEDIA_PLAYING); }));
  ASSERT_EQ(1, barc_tab_media_action(work_id, tab_id, BARC_MEDIA_PLAY));
  ASSERT_EQ(true, content::EvalJs(contents, "!video.paused || new Promise(r => video.addEventListener('playing', () => r(true), {once:true}))"));
  ASSERT_EQ(1, barc_tab_media_action(work_id, tab_id, BARC_MEDIA_NEXT_TRACK));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.media.back().title == "Track B"; }));
  EXPECT_EQ(1, content::EvalJs(contents, "window.nextCount"));
  ASSERT_EQ(1, barc_tab_media_action(work_id, tab_id, BARC_MEDIA_PREVIOUS_TRACK));
  ASSERT_TRUE(base::test::RunUntil([&] { return content::EvalJs(contents, "window.previousCount").ExtractInt() == 1; }));
  EXPECT_TRUE(SharedWindow(other)->IsSelectedForNativeWindow());
  EXPECT_EQ(other_tab, barc_window_tab_at(other, 0));
  SharedProfileResult private_result;
  barc_private_session_open_window(SharedProfileCompleted, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  const int32_t private_id = private_result.Get<1>();
  auto* private_window = SharedWindow(private_id);
  const int32_t private_tab = barc_window_tab_at(private_id, 0);
  Navigate(private_window, embedded_test_server()->GetURL("/media/picture-in-picture/pixel_test.html"));
  auto* private_contents = private_window->GetTabStripModel()->GetActiveWebContents();
  NavigationEvents private_events;
  private_events.token = barc_tab_observe(private_id, private_tab, NavigationEvents::Receive, &private_events);
  ASSERT_EQ(1, barc_tab_observe_media(private_events.token, NavigationEvents::ReceiveMedia));
  ASSERT_EQ(true, content::EvalJs(private_contents, "(async()=>{await play(); navigator.mediaSession.metadata = new MediaMetadata({title:'Private track'}); return true;})()"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    auto info = content::MediaSession::Get(private_contents)->GetMediaSessionInfoSync();
    return !private_events.media.empty() && (private_events.media.back().flags & BARC_MEDIA_CONTROLLABLE) &&
        (info->hide_metadata || private_events.media.back().title == "Private track");
  }));
  EXPECT_EQ(0, barc_tab_media_action(work_id, private_tab, BARC_MEDIA_PAUSE));
  EXPECT_TRUE(std::ranges::none_of(events.media, [](const auto& event) { return event.title == "Private track"; }));
  EXPECT_TRUE(std::ranges::none_of(private_events.media, [](const auto& event) { return event.title == "Track A" || event.title == "Track B"; }));
  // A live transfer retains the same handler/document and changes only its owner.
  const int32_t peer = barc_window_new_peer(work_id);
  ASSERT_GT(peer, 0);
  ASSERT_EQ(1, barc_tab_transfer(work_id, tab_id, peer));
  EXPECT_EQ(0, barc_tab_media_action(work_id, tab_id, BARC_MEDIA_NEXT_TRACK));
  ASSERT_EQ(1, barc_tab_media_action(peer, tab_id, BARC_MEDIA_NEXT_TRACK));
  ASSERT_TRUE(base::test::RunUntil([&] { return content::EvalJs(contents, "window.nextCount").ExtractInt() == 2; }));
  EXPECT_EQ(peer, events.media.back().window);
  // Replacement cannot republish queued metadata from the old live document.
  events.trace_media_commit = true;
  Navigate(SharedWindow(peer), embedded_test_server()->GetURL("/title1.html"));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.media.back().title.empty() && !(events.media.back().flags & BARC_MEDIA_PLAYING); }));
  EXPECT_EQ(0, barc_tab_media_action(peer, tab_id, BARC_MEDIA_PLAY));
  base::RunLoop().RunUntilIdle();
  EXPECT_TRUE(events.media_commit_observed);
  EXPECT_TRUE(std::ranges::none_of(events.metadata_after_commit,
      [](const auto& title) { return title == "Track A" || title == "Track B"; }));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       MediaUnsubscribeDuringInitialDeliveryStopsPublication) {
  const int32_t window = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t tab = barc_window_tab_at(window, 0);
  NavigationEvents events;
  events.token = barc_tab_observe(window, tab, NavigationEvents::Receive, &events);
  events.unsubscribe_media = true;
  EXPECT_EQ(1, barc_tab_observe_media(events.token, NavigationEvents::ReceiveMedia));
  ASSERT_EQ(1u, events.media.size());
  EXPECT_EQ(0, barc_tab_observe_media(events.token, NavigationEvents::ReceiveMedia));
  content::MediaSession::Get(SharedWindow(window)->GetTabStripModel()->GetActiveWebContents());
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1u, events.media.size());
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       AudioCallbackUnsubscribeEndsMediaSafely) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t window = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* browser = SharedWindow(window);
  const int32_t tab = barc_window_tab_at(window, 0);
  NavigationEvents events;
  events.token = barc_tab_observe(window, tab, NavigationEvents::Receive, &events);
  ASSERT_EQ(1, barc_tab_observe_media(events.token, NavigationEvents::ReceiveMedia));
  events.unsubscribe_audible = true;
  Navigate(browser, embedded_test_server()->GetURL("/title1.html"));
  auto* contents = browser->GetTabStripModel()->GetActiveWebContents();
  // Real audio delivery, not invoking the observer method as its own oracle.
  ASSERT_EQ(true, content::EvalJs(contents, R"((async()=>{
    window.audioProbe = new Audio('/media/pink_noise_140ms.wav');
    audioProbe.loop = true;
    await audioProbe.play(); return true;
  })())")) << content::EvalJs(contents, R"(JSON.stringify({
    visibility: document.visibilityState,
    readyState: window.audioProbe?.readyState,
    networkState: window.audioProbe?.networkState,
    paused: window.audioProbe?.paused,
    error: window.audioProbe?.error?.code
  }))");
  ASSERT_TRUE(base::test::RunUntil([&] { return events.audio_unsubscribed; }));
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(events.media_at_audio_unsubscribe, events.media.size());
  EXPECT_EQ(0, barc_tab_observe_media(events.token, NavigationEvents::ReceiveMedia));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       NavigationCallbackCanBindAnotherPagesMedia) {
  const int32_t window = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t tab = barc_window_tab_at(window, 0);
  const int32_t background = barc_tab_create(window, "about:blank", 0);
  ASSERT_GT(background, 0);
  auto* background_contents = SharedWindow(window)->GetTabStripModel()
                                  ->GetWebContentsAt(1);
  ASSERT_TRUE(background_contents);
  ASSERT_TRUE(content::WaitForLoadStop(background_contents));
  ASSERT_EQ(GURL("about:blank"), background_contents->GetLastCommittedURL());
  ASSERT_EQ(background, barc_window_tab_at(window, 1));
  NavigationEvents outer, nested;
  outer.token = barc_tab_observe(window, tab, NavigationEvents::Receive, &outer);
  outer.nested_media_owner = &nested;
  outer.nested_media_tab = background;
  ASSERT_EQ(1, barc_tab_set_muted(window, tab, 1));
  base::RunLoop().RunUntilIdle();
  EXPECT_NE(0u, nested.token);
  EXPECT_EQ(1u, nested.media.size());
  EXPECT_EQ(window, nested.media.back().window);
  EXPECT_EQ(background, nested.media.back().tab);
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       PhysicalPanesKeepOriginalProfileContainersAndProtection) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work && personal);
#if BUILDFLAG(ENTERPRISE_SCREENSHOT_PROTECTION)
  data_controls::SetDataControls(work->GetProfile()->GetPrefs(), {R"({
    "name":"physical-work-block","rule_id":"physical-work-block",
    "sources":{"urls":["*"]},
    "restrictions":[{"class":"SCREENSHOT","level":"BLOCK"}]
  })"});
#endif
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  Navigate(personal, embedded_test_server()->GetURL("/title2.html"));
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  auto* widget = work_view->browser_widget();
  ASSERT_EQ(widget, personal_view->browser_widget());
  ASSERT_NE(work->GetProfile(), personal->GetProfile());
  auto* work_contents = work->GetTabStripModel()->GetActiveWebContents();
  auto* personal_contents = personal->GetTabStripModel()->GetActiveWebContents();
  auto* work_container = work_view->GetContentsContainerViewFor(work_contents);
  auto* personal_container = personal_view->GetContentsContainerViewFor(personal_contents);
  auto* work_parent = work_container->parent();
  auto* personal_parent = personal_container->parent();
  const auto work_owned = work_view->GetContentsContainerViews();
  const auto personal_owned = personal_view->GetContentsContainerViews();
  const int32_t background_handle = barc_tab_create(work_id, "about:blank", 0);
  ASSERT_NE(0, background_handle);
  auto* background_contents = tabs::TabHandle(background_handle).Get()->GetContents();
  ASSERT_NE(background_contents, work_contents);
  EXPECT_EQ(content::Visibility::HIDDEN, background_contents->GetVisibility());
  ASSERT_TRUE(content::ExecJs(work_contents,
      "window.liveDraft={value:'work'};document.body.innerHTML='<input id=draft>';draft.value='work';"));
  ASSERT_TRUE(content::ExecJs(personal_contents,
      "window.liveDraft={value:'personal'};document.body.innerHTML='<input id=draft>';draft.value='personal';"));
  ASSERT_EQ(1, barc_window_select(work_id));
  NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
  ASSERT_EQ(1, barc_window_attach_native_shell(work_id, (__bridge void*)header));
  ASSERT_EQ(1, barc_window_show(work_id));
  widget->LayoutRootViewIfNecessary();
  std::array<tabs::TabInterface*, 2> panes{
      tabs::TabInterface::MaybeGetFromContents(work_contents),
      tabs::TabInterface::MaybeGetFromContents(personal_contents)};
  const auto layout = split_tabs::SplitTabVisualData::EqualSplit(
      split_tabs::SplitTabLayout::kSideBySide, panes.size());
  ASSERT_TRUE(widget->PresentBarcTabs(panes, layout, panes[0]));
  auto* physical = views::AsViewClass<MultiContentsView>(work_container->parent());
  ASSERT_TRUE(physical && physical->is_physical_presentation());
  EXPECT_EQ(physical, personal_container->parent());
  EXPECT_EQ(work_view, work_container->browser_view());
  EXPECT_EQ(personal_view, personal_container->browser_view());
  EXPECT_EQ(work_owned, work_view->GetContentsContainerViews());
  EXPECT_EQ(personal_owned, personal_view->GetContentsContainerViews());
  EXPECT_TRUE(work_container->GetVisible() && personal_container->GetVisible());
  EXPECT_EQ(work_contents, work_container->contents_view()->web_contents());
  EXPECT_EQ(personal_contents, personal_container->contents_view()->web_contents());
  // Wrong-Widget/duplicate/capacity refusal must not destroy or reparent its input.
  auto* foreign = BrowserView::GetBrowserViewForBrowser(browser())->GetActiveContentsContainerView();
  auto* foreign_parent = foreign->parent();
  EXPECT_FALSE(physical->AddPresentedContainer(foreign));
  EXPECT_EQ(foreign_parent, foreign->parent());
  EXPECT_FALSE(physical->AddPresentedContainer(work_container));
  EXPECT_EQ(physical, work_container->parent());
  ASSERT_TRUE(physical->AddPresentedContainer(work_owned[2]));
  ASSERT_TRUE(physical->AddPresentedContainer(work_owned[3]));
  auto* untouched = personal_owned[2]->parent();
  EXPECT_FALSE(physical->AddPresentedContainer(personal_owned[2]));
  EXPECT_EQ(untouched, personal_owned[2]->parent());
  for (int i = 0; i < 4; ++i) {
    widget->SelectBarcPresentedContents(i % 2 ? work_contents : personal_contents);
    EXPECT_EQ(i % 2 ? work_view : personal_view, widget->selected_browser_view());
    EXPECT_EQ(physical, work_container->parent());
    EXPECT_EQ(physical, personal_container->parent());
    EXPECT_TRUE(work_container->GetVisible() && personal_container->GetVisible());
    EXPECT_EQ(content::Visibility::HIDDEN, background_contents->GetVisibility());
#if BUILDFLAG(ENTERPRISE_SCREENSHOT_PROTECTION)
    widget->UpdateBarcPresentedScreenshotPolicy();
    EXPECT_FALSE(widget->AreScreenshotsAllowed());
    personal_view->ApplyScreenshotSettings(true);
    EXPECT_FALSE(widget->AreScreenshotsAllowed());
#endif
  }
  // The actual owner-bound modal hosts use their pane's current native geometry.
  const gfx::Size dialog(80, 40);
  for (auto* pane : {work_container, personal_container}) {
    const auto bounds = pane->ConvertRectToWidget(pane->GetLocalBounds());
    const auto position = pane->web_contents_modal_dialog_host()->GetDialogPosition(dialog);
    EXPECT_TRUE(bounds.Contains(gfx::Rect(position, dialog)));
    EXPECT_EQ(pane->size(), pane->web_contents_modal_dialog_host()->GetMaximumDialogSize());
  }
  EXPECT_EQ("work", content::EvalJs(work_contents, "draft.value"));
  EXPECT_EQ("personal", content::EvalJs(personal_contents, "draft.value"));
  EXPECT_EQ("work", content::EvalJs(work_contents, "liveDraft.value"));
  EXPECT_EQ("personal", content::EvalJs(personal_contents, "liveDraft.value"));
  widget->ClearBarcPresentedTabs();
  EXPECT_EQ(work_parent, work_container->parent());
  EXPECT_EQ(personal_parent, personal_container->parent());
  EXPECT_EQ(work_owned, work_view->GetContentsContainerViews());
  EXPECT_EQ(personal_owned, personal_view->GetContentsContainerViews());
}

class ReplaceZoomOnDismiss : public views::WidgetObserver {
 public:
  ReplaceZoomOnDismiss(views::Widget* widget, base::OnceClosure replace)
      : replace_(std::move(replace)) {
    observation_.Observe(widget);
  }
  void OnWidgetClosing(views::Widget*) override { Replace(); }
  void OnWidgetVisibilityChanged(views::Widget*, bool visible) override {
    if (!visible) {
      Replace();
    }
  }
  void OnWidgetDestroying(views::Widget*) override { observation_.Reset(); }
  bool replaced() const { return !replace_; }

 private:
  void Replace() {
    if (replace_) {
      std::move(replace_).Run();
    }
  }
  base::OnceClosure replace_;
  base::ScopedObservation<views::Widget, views::WidgetObserver> observation_{this};
};

class BarcPresentedPaneCommandsBrowserTest : public BarcDiscoveryBrowserTest {
 protected:
  void SetUpOnMainThread() override {
    BarcDiscoveryBrowserTest::SetUpOnMainThread();
    for (size_t i = 0; i < 4; ++i) {
      host_resolver()->AddRule("cross-pane-" + std::to_string(i) + ".test",
                               "127.0.0.1");
    }
  }
};

IN_PROC_BROWSER_TEST_F(BarcPresentedPaneCommandsBrowserTest,
                       AlternatingProfilePanesActivateExactRealTabAndCommands) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work && personal);
  const int32_t a1 = barc_window_tab_at(work_id, 0);
  const int32_t b1 = barc_window_tab_at(personal_id, 0);
  const int32_t a2 = barc_tab_create(work_id, "about:blank", 0);
  const int32_t b2 = barc_tab_create(personal_id, "about:blank", 0);
  ASSERT_TRUE(a2 && b2);
  std::array<tabs::TabInterface*, 4> panes{
      tabs::TabHandle(a1).Get(), tabs::TabHandle(b1).Get(),
      tabs::TabHandle(a2).Get(), tabs::TabHandle(b2).Get()};
  // Blank factory completion does not guarantee a live committed render frame.
  // Load each exact contents before testing zoom, with distinct host-scoped keys.
  for (size_t i = 0; i < panes.size(); ++i) {
    auto* contents = panes[i]->GetContents();
    const GURL url = embedded_test_server()->GetURL(
        "cross-pane-" + std::to_string(i) + ".test", "/title1.html");
    content::TestNavigationObserver navigated(contents);
    ASSERT_EQ(1, barc_tab_navigate(
        panes[i]->GetBrowserWindowInterface()->GetSessionID().id(),
        panes[i]->GetHandle().raw_value(), url.spec().c_str()));
    navigated.Wait();
    ASSERT_TRUE(content::WaitForLoadStop(contents));
    ASSERT_EQ(url, contents->GetLastCommittedURL());
    ASSERT_TRUE(contents->GetPrimaryMainFrame()->IsRenderFrameLive());
  }
  BarcSplitLayout local{};
  local.count = 2; local.orientation = 0; local.dividers[0] = .5;
  local.tabs[0] = a1; local.tabs[1] = a2; local.active_tab = a1;
  ASSERT_EQ(1, barc_window_select(work_id));
  ASSERT_EQ(1, barc_window_set_split(work_id, &local));
  local.tabs[0] = b1; local.tabs[1] = b2; local.active_tab = b1;
  ASSERT_EQ(1, barc_window_select(personal_id));
  ASSERT_EQ(1, barc_window_set_split(personal_id, &local));
  ASSERT_EQ(1, barc_window_select(work_id));
  auto* widget = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
  ASSERT_EQ(1, barc_window_attach_native_shell(work_id, (__bridge void*)header));
  ASSERT_EQ(1, barc_window_show(work_id));
  widget->LayoutRootViewIfNecessary();
  ASSERT_TRUE(widget->PresentBarcTabs(panes,
      split_tabs::SplitTabVisualData::EqualSplit(split_tabs::SplitTabLayout::kSideBySide, 4), panes[0]));
  for (size_t i : {2u, 3u, 0u, 1u}) {
    SCOPED_TRACE("pane=" + std::to_string(i));
    auto* contents = panes[i]->GetContents();
    auto* previous_owner = widget->selected_browser_view()->browser();
    auto* previous_zoom = ZoomBubbleCoordinator::From(previous_owner);
    auto previous_zoom_widget = previous_zoom ? previous_zoom->GetBubbleWidget()
                                             : base::WeakPtr<views::Widget>();
    widget->SelectBarcPresentedContents(contents);
    auto* owner = panes[i]->GetBrowserWindowInterface();
    ASSERT_EQ(owner, widget->selected_browser_view()->browser());
    ExpectPageBelowOnlyNativeTop(widget->selected_browser_view(), 0);
    EXPECT_EQ(contents, owner->GetTabStripModel()->GetActiveWebContents());
    EXPECT_TRUE(panes[i]->IsActivated());
    if (previous_owner != owner && previous_zoom_widget) {
      EXPECT_TRUE(previous_zoom_widget->IsClosed());
      EXPECT_FALSE(previous_zoom_widget->IsVisible());
    }
    EXPECT_DOUBLE_EQ(
        0, zoom::ZoomController::FromWebContents(contents)->GetZoomLevel());
    EXPECT_EQ(1, barc_tab_execute_command(owner->GetSessionID().id(),
        panes[i]->GetHandle().raw_value(), BARC_PAGE_ZOOM_IN));
    EXPECT_GT(zoom::ZoomController::FromWebContents(contents)->GetZoomLevel(), 0);
    auto* zoom = ZoomBubbleCoordinator::From(owner);
    ASSERT_TRUE(zoom);
    ASSERT_TRUE(zoom->bubble());
    EXPECT_TRUE(zoom->bubble()->GetWidget()->IsVisible());
    if (i == 2) {
      // A real close click may precede client selection in the same UI turn.
      // The coordinator's visible-bubble accessor is already null at this point.
      auto closing = zoom->GetBubbleWidget();
      ASSERT_TRUE(closing);
      ReplaceZoomOnDismiss select_while_closing(
          closing.get(), base::BindLambdaForTesting([&] {
            ASSERT_TRUE(closing);
            ASSERT_TRUE(closing->IsClosed());
            ASSERT_TRUE(closing->IsVisible());
            EXPECT_FALSE(zoom->bubble());
            widget->SelectBarcPresentedContents(panes[3]->GetContents());
            EXPECT_EQ(personal, widget->selected_browser_view()->browser());
            EXPECT_EQ(panes[3]->GetContents(),
                      personal->GetTabStripModel()->GetActiveWebContents());
          }));
      zoom->Hide();
      EXPECT_TRUE(select_while_closing.replaced());
      ASSERT_TRUE(closing);
      EXPECT_TRUE(closing->IsClosed());
      EXPECT_FALSE(closing->IsVisible());
    }
    EXPECT_EQ(0, barc_tab_execute_command(owner->GetSessionID().id(),
        panes[i ^ 2u]->GetHandle().raw_value(), BARC_PAGE_ZOOM_IN));
  }
  // A close/visibility observer may create a newer zoom UI for the old owner.
  // Dismiss only the captured widget; the replacement must still block handoff.
  auto* zoom = ZoomBubbleCoordinator::From(personal);
  ASSERT_TRUE(zoom);
  auto original = zoom->GetBubbleWidget();
  ASSERT_TRUE(original);
  {
    ReplaceZoomOnDismiss replace(original.get(), base::BindLambdaForTesting([&] {
      zoom->Show(panes[1]->GetContents(), ZoomBubbleView::AUTOMATIC);
    }));
    widget->SelectBarcPresentedContents(panes[0]->GetContents());
    EXPECT_TRUE(replace.replaced());
    EXPECT_EQ(personal, widget->selected_browser_view()->browser());
    auto replacement = zoom->GetBubbleWidget();
    ASSERT_TRUE(replacement);
    EXPECT_NE(original.get(), replacement.get());
    EXPECT_TRUE(replacement->IsVisible());
    EXPECT_FALSE(replacement->IsClosed());
    if (original) {
      EXPECT_TRUE(original->IsClosed());
      EXPECT_FALSE(original->IsVisible());
    }
  }
  widget->ClearBarcPresentedTabs();
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       BorrowedPaneTransferReturnsOwnershipBeforeLogicalClose) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work && personal);
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  Navigate(personal, embedded_test_server()->GetURL("/title2.html"));
  auto* work_contents = work->GetTabStripModel()->GetActiveWebContents();
  auto* personal_contents = personal->GetTabStripModel()->GetActiveWebContents();
  auto* work_tab = tabs::TabInterface::MaybeGetFromContents(work_contents);
  auto* personal_tab = tabs::TabInterface::MaybeGetFromContents(personal_contents);
  const int32_t moving = work_tab->GetHandle().raw_value();
  const int history = work_contents->GetController().GetEntryCount();
  ASSERT_TRUE(content::ExecJs(work_contents,
      "window.liveObject={value:'moving'};document.body.innerHTML='<input id=draft>';draft.value='moving';"));
  ASSERT_TRUE(content::ExecJs(personal_contents, "window.liveObject={value:'survivor'}"));
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  auto* widget = work_view->browser_widget();
  auto host_alive = widget->GetWeakPtr();
  const auto native = widget->GetNativeWindow();
  auto* personal_container = personal_view->GetContentsContainerViewFor(personal_contents);
  auto* personal_parent = personal_container->parent();
  ASSERT_EQ(1, barc_window_select(work_id));
  std::array<tabs::TabInterface*, 2> panes{work_tab, personal_tab};
  ASSERT_TRUE(widget->PresentBarcTabs(panes,
      split_tabs::SplitTabVisualData::EqualSplit(split_tabs::SplitTabLayout::kSideBySide, 2), work_tab));
  const int32_t destination = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto source_alive = work->GetWeakPtr();
  ASSERT_EQ(1, barc_tab_transfer(work_id, moving, destination));
  EXPECT_EQ(work_contents, tabs::TabHandle(moving).Get()->GetContents());
  EXPECT_EQ(SharedWindow(destination), tabs::TabHandle(moving).Get()->GetBrowserWindowInterface());
  EXPECT_EQ(history, work_contents->GetController().GetEntryCount());
  EXPECT_EQ("moving", content::EvalJs(work_contents, "draft.value"));
  EXPECT_EQ("moving", content::EvalJs(work_contents, "liveObject.value"));
  content::RunAllTasksUntilIdle();
  if (source_alive) {
    ASSERT_TRUE(source_alive->IsDeleteScheduled());
    ASSERT_TRUE(source_alive->GetTabStripModel()->empty());
    BrowserManagerService::SynchronouslyDestroyBrowser(source_alive.get());
  }
  EXPECT_FALSE(source_alive);
  ASSERT_TRUE(host_alive);
  ASSERT_EQ(personal_view->browser_widget(), widget);
  EXPECT_EQ(native, personal_view->GetNativeWindow());
  EXPECT_EQ(personal_parent, personal_container->parent());
  EXPECT_FALSE(widget->HasBarcPresentedContents(personal_view));
  EXPECT_EQ(personal_contents, personal_container->contents_view()->web_contents());
  EXPECT_EQ("survivor", content::EvalJs(personal_contents, "liveObject.value"));
}

namespace {
class CloseLogicalOwnerOnBorrow : public views::ViewObserver {
 public:
  CloseLogicalOwnerOnBorrow(views::View* root,
                            ContentsContainerView* target, base::OnceClosure action)
      : target_(target), action_(std::move(action)) { root_.Observe(root); }
  void OnChildViewAdded(views::View* observed, views::View* child) override {
    if (root_.IsObservingSource(observed)) {
      auto* physical = views::AsViewClass<MultiContentsView>(child);
      if (physical && physical->is_physical_presentation()) {
        presentation_.Observe(physical);
      }
    } else if (child == target_.view() && !requested_) {
      requested_ = true;
      std::move(action_).Run();
    }
  }
  void OnViewIsDeleting(views::View* view) override {
    if (root_.IsObservingSource(view)) { root_.Reset(); }
    if (presentation_.IsObservingSource(view)) { presentation_.Reset(); }
  }
  bool requested() const { return requested_; }
 private:
  views::ViewTracker target_;
  base::OnceClosure action_;
  bool requested_ = false;
  base::ScopedObservation<views::View, views::ViewObserver> root_{this};
  base::ScopedObservation<views::View, views::ViewObserver> presentation_{this};
};
}  // namespace

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       BorrowHierarchyCloseWaitsUntilExactOwnerReturn) {
  for (bool via_bridge : {false, true}) {

  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work && personal);
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  auto* work_contents = work->GetTabStripModel()->GetActiveWebContents();
  auto* personal_contents = personal->GetTabStripModel()->GetActiveWebContents();
  auto* work_container = work_view->GetContentsContainerViewFor(work_contents);
  auto* original_parent = work_container->parent();
  auto* widget = work_view->browser_widget();
  auto alive = widget->GetWeakPtr();
  auto owner_alive = personal->GetWeakPtr();
  ASSERT_EQ(1, barc_window_select(work_id));
  {
    CloseLogicalOwnerOnBorrow observed(widget->non_client_view(),
        personal_view->GetContentsContainerViewFor(personal_contents),
        base::BindLambdaForTesting([&] {
          if (via_bridge) { EXPECT_EQ(1, barc_window_close(personal_id)); }
          else { personal->GetWindow()->Close(); }
        }));
    std::array<tabs::TabInterface*, 2> panes{
        tabs::TabInterface::MaybeGetFromContents(work_contents),
        tabs::TabInterface::MaybeGetFromContents(personal_contents)};
    ASSERT_TRUE(widget->PresentBarcTabs(panes,
        split_tabs::SplitTabVisualData::EqualSplit(split_tabs::SplitTabLayout::kSideBySide, 2), panes[0]));
    EXPECT_TRUE(observed.requested());
    // Request acceptance did not destroy the returning/adding View stack.
    ASSERT_TRUE(owner_alive);
    EXPECT_FALSE(owner_alive->IsDeleteScheduled());
  }
  content::RunAllTasksUntilIdle();
  if (owner_alive) {
    ASSERT_TRUE(owner_alive->IsDeleteScheduled());
    ASSERT_TRUE(owner_alive->GetTabStripModel()->empty());
    BrowserManagerService::SynchronouslyDestroyBrowser(owner_alive.get());
  }
  EXPECT_FALSE(owner_alive);
  ASSERT_TRUE(alive);
  EXPECT_EQ(original_parent, work_container->parent());
  EXPECT_EQ(work_contents, work_container->contents_view()->web_contents());
  EXPECT_EQ(work_view, widget->selected_browser_view());
  }
}


IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       BorrowHierarchyRejectsBridgeTransferWithoutDetaching) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  const int32_t destination = Open(kSharedPersonal, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work && personal);
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  auto* widget = work_view->browser_widget();
  auto* a = work->GetTabStripModel()->GetActiveWebContents();
  auto* b = personal->GetTabStripModel()->GetActiveWebContents();
  auto* tab = tabs::TabInterface::MaybeGetFromContents(b);
  const int32_t moving = tab->GetHandle().raw_value();
  ASSERT_EQ(1, barc_window_select(work_id));
  {
    CloseLogicalOwnerOnBorrow observed(widget->non_client_view(),
        personal_view->GetContentsContainerViewFor(b),
        base::BindLambdaForTesting([&] {
          EXPECT_EQ(0, barc_tab_transfer(personal_id, moving, destination));
          EXPECT_EQ(personal, tabs::TabHandle(moving).Get()->GetBrowserWindowInterface());
        }));
    std::array<tabs::TabInterface*, 2> panes{
        tabs::TabInterface::MaybeGetFromContents(a), tab};
    ASSERT_TRUE(widget->PresentBarcTabs(panes,
        split_tabs::SplitTabVisualData::EqualSplit(split_tabs::SplitTabLayout::kSideBySide, 2), panes[0]));
    EXPECT_TRUE(observed.requested());
    EXPECT_EQ(personal, tabs::TabHandle(moving).Get()->GetBrowserWindowInterface());
  }
  widget->ClearBarcPresentedTabs();
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       BorrowedNativeDestructionReturnsEveryProfileBeforeTeardown) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work && personal);
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* widget = work_view->browser_widget();
  auto host_alive = widget->GetWeakPtr();
  auto work_alive = work->GetWeakPtr();
  auto personal_alive = personal->GetWeakPtr();
  ASSERT_EQ(1, barc_window_select(work_id));
  std::array<tabs::TabInterface*, 2> panes{
      tabs::TabInterface::MaybeGetFromContents(work->GetTabStripModel()->GetActiveWebContents()),
      tabs::TabInterface::MaybeGetFromContents(personal->GetTabStripModel()->GetActiveWebContents())};
  ASSERT_TRUE(widget->PresentBarcTabs(panes,
      split_tabs::SplitTabVisualData::EqualSplit(split_tabs::SplitTabLayout::kSideBySide, 2), panes[0]));
  // This deliberately bypasses the bridge guard/normal logical-close queue.
  // OnNativeWidgetDestroying must restore views before any original owner dies.
  [widget->GetNativeWindow().GetNativeNSWindow() close];
  content::RunAllTasksUntilIdle();
  EXPECT_FALSE(host_alive);
  EXPECT_FALSE(work_alive);
  EXPECT_FALSE(personal_alive);
}

namespace {
class TryPresentationDuringOwnerReconcile : public views::ViewObserver {
 public:
  TryPresentationDuringOwnerReconcile(views::View* view, base::OnceClosure action, bool when_visible = false)
      : action_(std::move(action)), when_visible_(when_visible) { observation_.Observe(view); }
  void OnViewVisibilityChanged(views::View* view, views::View*, bool) override {
    if (view->GetVisible() == when_visible_ && action_) {
      std::move(action_).Run();
    }
  }
  void OnViewIsDeleting(views::View*) override { observation_.Reset(); }
 private:
  base::OnceClosure action_;
  const bool when_visible_;
  base::ScopedObservation<views::View, views::ViewObserver> observation_{this};
};
}  // namespace

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       MixedSplitPreparesSingletonAndInactiveOwnerWithoutCollections) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work && personal);
  ASSERT_NE(work->GetProfile(), personal->GetProfile());
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  auto* widget = work_view->browser_widget();
  ASSERT_EQ(widget, personal_view->browser_widget());
  const int32_t a = barc_window_tab_at(work_id, 0);
  const int32_t b = barc_window_tab_at(personal_id, 0);
  const int32_t hidden = barc_tab_create(personal_id, "about:blank", 0);
  ASSERT_GT(hidden, 0);
  auto* hidden_contents = tabs::TabHandle(hidden).Get()->GetContents();
  auto* work_contents = tabs::TabHandle(a).Get()->GetContents();
  ASSERT_TRUE(content::NavigateToURL(hidden_contents, GURL("data:text/html,<input id=draft>")));
  ASSERT_TRUE(content::ExecJs(hidden_contents,
      "window.exactDraft={value:'inactive'};document.body.innerHTML='<input id=draft>';draft.value='kept';"));
  ASSERT_EQ(1, barc_window_select(work_id));
  NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
  ASSERT_EQ(1, barc_window_attach_native_shell(work_id, (__bridge void*)header));
  ASSERT_EQ(1, barc_window_show(work_id));
  BarcSplitLayout request{2, 0, {a, hidden}, {.4}, a};
  ASSERT_EQ(1, barc_window_set_split(work_id, &request));
  BarcSplitLayout old{};
  ASSERT_EQ(1, barc_window_get_split(personal_id, hidden, &old));
  EXPECT_EQ(1u, old.kind);
  EXPECT_EQ(0, old.collection);
  EXPECT_GT(old.generation, 0u);
  EXPECT_EQ(a, old.active_tab);
  EXPECT_EQ(b, personal->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
  EXPECT_FALSE(tabs::TabHandle(a).Get()->GetSplit());
  EXPECT_FALSE(tabs::TabHandle(hidden).Get()->GetSplit());
  EXPECT_EQ(hidden_contents, tabs::TabHandle(hidden).Get()->GetContents());
  EXPECT_EQ(work_contents, tabs::TabHandle(a).Get()->GetContents());

  // Replacing the composition prepares another inactive tab of this same owner.
  const int32_t third = barc_tab_create(personal_id, "about:blank", 0);
  ASSERT_GT(third, 0);
  BarcSplitLayout replacement{3, 1, {a, hidden, third}, {.3, .7}, a};
  ASSERT_EQ(1, barc_window_set_split(work_id, &replacement));
  BarcSplitLayout current{};
  ASSERT_EQ(1, barc_window_get_split(work_id, 0, &current));
  EXPECT_EQ(1u, current.kind);
  EXPECT_NE(old.generation, current.generation);
  EXPECT_EQ(0, barc_window_clear_split(work_id, a, &old));
  BarcSplitLayout retained{};
  ASSERT_EQ(1, barc_window_get_split(personal_id, hidden, &retained));
  EXPECT_EQ(current.generation, retained.generation);
  EXPECT_EQ(3u, retained.count);
  EXPECT_EQ("inactive", content::EvalJs(hidden_contents, "exactDraft.value"));
  EXPECT_EQ("kept", content::EvalJs(hidden_contents, "draft.value"));

  // A foreign physical owner cannot partially replace the mounted layout.
  const int32_t other = Open(kSharedPersonal, 0, BARC_PROFILE_BLANK);
  const int32_t other_tab = barc_window_tab_at(other, 0);
  request.tabs[1] = other_tab;
  ASSERT_EQ(1, barc_window_select(work_id));
  EXPECT_EQ(0, barc_window_set_split(work_id, &request));
  ASSERT_EQ(1, barc_window_get_split(work_id, 0, &retained));
  EXPECT_EQ(current.generation, retained.generation);
  bool reentered = false;
  bool admitted_during_clear = true;
  {
    auto* third_container = personal_view->GetContentsContainerViewFor(
        tabs::TabHandle(third).Get()->GetContents());
    ASSERT_TRUE(third_container);
    TryPresentationDuringOwnerReconcile observed(third_container,
        base::BindLambdaForTesting([&] {
          reentered = true;
          std::array<tabs::TabInterface*, 2> panes{
              tabs::TabHandle(a).Get(), tabs::TabHandle(hidden).Get()};
          admitted_during_clear = widget->SetBarcPresentedTabs(panes,
              split_tabs::SplitTabVisualData::EqualSplit(
                  split_tabs::SplitTabLayout::kSideBySide, 2), panes[0]);
        }));
    EXPECT_EQ(1, barc_window_clear_split(personal_id, hidden, &current));
  }
  EXPECT_TRUE(reentered);
  EXPECT_FALSE(admitted_during_clear);
  EXPECT_FALSE(widget->HasBarcPresentedTabs());
  request.tabs[1] = hidden;
  ASSERT_EQ(1, barc_window_set_split(work_id, &request));
  BarcSplitLayout newer{};
  ASSERT_EQ(1, barc_window_get_split(work_id, 0, &newer));
  EXPECT_NE(current.generation, newer.generation);
  EXPECT_EQ(0, barc_window_clear_split(work_id, a, &current));
  BarcSplitLayout still_new{};
  ASSERT_EQ(1, barc_window_get_split(work_id, 0, &still_new));
  EXPECT_EQ(newer.generation, still_new.generation);
  EXPECT_EQ(1, barc_window_clear_split(work_id, a, &newer));
  EXPECT_EQ(work_contents, work_view->GetActiveContentsContainerView()->contents_view()->web_contents());
  EXPECT_EQ(tabs::TabHandle(b).Get()->GetContents(),
            personal_view->GetActiveContentsContainerView()->contents_view()->web_contents());
  EXPECT_EQ(b, personal->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
  EXPECT_FALSE(tabs::TabHandle(hidden).Get()->GetSplit());
  EXPECT_EQ("kept", content::EvalJs(hidden_contents, "draft.value"));
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       MixedSplitBorrowRefusalPreservesNewerOwnerSelection) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work && personal);
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  auto* widget = work_view->browser_widget();
  const int32_t a = barc_window_tab_at(work_id, 0);
  const int32_t b = barc_window_tab_at(personal_id, 0);
  const int32_t newer = barc_tab_create(work_id, "about:blank", 0);
  ASSERT_GT(newer, 0);
  ASSERT_EQ(1, barc_window_select(work_id));
  NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
  ASSERT_EQ(1, barc_window_attach_native_shell(work_id, (__bridge void*)header));
  ASSERT_EQ(1, barc_window_show(work_id));
  auto* personal_container = personal_view->GetActiveContentsContainerView();
  CloseLogicalOwnerOnBorrow observed(widget->non_client_view(), personal_container,
      base::BindLambdaForTesting([&] {
        auto* strip = work->GetTabStripModel();
        strip->ActivateTabAt(strip->GetIndexOfTab(tabs::TabHandle(newer).Get()));
      }));
  BarcSplitLayout request{2, 0, {a, b}, {.5}, a};
  EXPECT_EQ(0, barc_window_set_split(work_id, &request));
  EXPECT_TRUE(observed.requested());
  EXPECT_FALSE(widget->HasBarcPresentedTabs());
  EXPECT_EQ(newer, work->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
  EXPECT_EQ(tabs::TabHandle(newer).Get()->GetContents(),
            work_view->GetActiveContentsContainerView()->contents_view()->web_contents());
  EXPECT_EQ(b, personal->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       MixedSplitHierarchyRefusalRestoresPriorPresentationOnly) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work && personal);
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  auto* widget = work_view->browser_widget();
  const int32_t a = barc_window_tab_at(work_id, 0);
  const int32_t b = barc_window_tab_at(personal_id, 0);
  const int32_t extra = barc_tab_create(personal_id, "about:blank", 0);
  ASSERT_GT(extra, 0);
  auto* contents = tabs::TabHandle(b).Get()->GetContents();
  ASSERT_TRUE(content::NavigateToURL(contents, GURL("data:text/html,live-draft")));
  ASSERT_TRUE(content::ExecJs(contents, "window.exactObject={draft:'unchanged'};"));
  ASSERT_EQ(1, barc_window_select(work_id));
  NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
  ASSERT_EQ(1, barc_window_attach_native_shell(work_id, (__bridge void*)header));
  ASSERT_EQ(1, barc_window_show(work_id));
  BarcSplitLayout initial{2, 0, {a, b}, {.4}, a};
  ASSERT_EQ(1, barc_window_set_split(work_id, &initial));
  BarcSplitLayout before{};
  ASSERT_EQ(1, barc_window_get_split(work_id, 0, &before));
  auto* target = personal_view->GetContentsContainerViewFor(contents);
  CloseLogicalOwnerOnBorrow observed(widget->non_client_view(), target,
      base::BindLambdaForTesting([&] { widget->ClearBarcPresentedTabs(); }));
  BarcSplitLayout replacement{3, 1, {a, b, extra}, {.3, .7}, a};
  EXPECT_EQ(0, barc_window_set_split(work_id, &replacement));
  EXPECT_TRUE(observed.requested());
  BarcSplitLayout after{};
  ASSERT_EQ(1, barc_window_get_split(work_id, 0, &after));
  EXPECT_EQ(1u, after.kind);
  EXPECT_EQ(2u, after.count);
  EXPECT_EQ(a, after.tabs[0]);
  EXPECT_EQ(b, after.tabs[1]);
  EXPECT_EQ(a, after.active_tab);
  EXPECT_EQ(before.orientation, after.orientation);
  EXPECT_DOUBLE_EQ(before.dividers[0], after.dividers[0]);
  EXPECT_NE(before.generation, after.generation);
  EXPECT_EQ(0, barc_window_clear_split(work_id, a, &before));
  EXPECT_EQ(1, barc_window_native_shell_is_owned(work_id, (__bridge void*)header));
  EXPECT_EQ(work_view, widget->selected_browser_view());
  EXPECT_EQ(contents, tabs::TabHandle(b).Get()->GetContents());
  EXPECT_EQ("unchanged", content::EvalJs(contents, "exactObject.draft"));
  EXPECT_EQ(1, barc_window_clear_split(work_id, a, &after));
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       MixedToLocalClearCannotOverwriteNewerSameOwnerTab) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work && personal);
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  auto* widget = work_view->browser_widget();
  const int32_t a = barc_window_tab_at(work_id, 0);
  const int32_t b = barc_window_tab_at(personal_id, 0);
  const int32_t newer = barc_tab_create(work_id, "about:blank", 0);
  const int32_t hidden = barc_tab_create(personal_id, "about:blank", 0);
  ASSERT_TRUE(newer && hidden);
  ASSERT_EQ(1, barc_window_select(work_id));
  NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
  ASSERT_EQ(1, barc_window_attach_native_shell(work_id, (__bridge void*)header));
  ASSERT_EQ(1, barc_window_show(work_id));
  BarcSplitLayout mixed{3, 0, {a, b, hidden}, {.3, .6}, a};
  ASSERT_EQ(1, barc_window_set_split(work_id, &mixed));
  auto* target = personal_view->GetContentsContainerViewFor(
      tabs::TabHandle(hidden).Get()->GetContents());
  ASSERT_TRUE(target);
  const uint64_t epoch = widget->barc_selection_epoch();
  bool reentered = false;
  TryPresentationDuringOwnerReconcile observed(target,
      base::BindLambdaForTesting([&] {
        reentered = true;
        auto* strip = work->GetTabStripModel();
        strip->ActivateTabAt(strip->GetIndexOfTab(tabs::TabHandle(newer).Get()));
      }));
  BarcSplitLayout local{2, 1, {a, newer}, {.5}, a};
  EXPECT_EQ(0, barc_window_set_split(work_id, &local));
  EXPECT_TRUE(reentered);
  EXPECT_EQ(epoch, widget->barc_selection_epoch());
  EXPECT_EQ(newer, work->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
  EXPECT_FALSE(widget->HasBarcPresentedTabs());
  EXPECT_FALSE(tabs::TabHandle(a).Get()->GetSplit());
  EXPECT_FALSE(tabs::TabHandle(newer).Get()->GetSplit());
  EXPECT_EQ(tabs::TabHandle(newer).Get()->GetContents(),
            work_view->GetActiveContentsContainerView()->contents_view()->web_contents());
  EXPECT_EQ(1, barc_window_native_shell_is_owned(work_id, (__bridge void*)header));
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       ExplicitMixedClearDissolvesOnlyUnchangedSelectedLocalCollection) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work && personal);
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* widget = work_view->browser_widget();
  const int32_t a = barc_window_tab_at(work_id, 0);
  const int32_t b = barc_window_tab_at(personal_id, 0);
  const int32_t a2 = barc_tab_create(work_id, "about:blank", 0);
  const int32_t b2 = barc_tab_create(personal_id, "about:blank", 0);
  ASSERT_TRUE(a2 && b2);
  auto* contents = tabs::TabHandle(a).Get()->GetContents();
  ASSERT_TRUE(content::NavigateToURL(contents, GURL("data:text/html,owned-draft")));
  ASSERT_TRUE(content::ExecJs(contents, "window.ownedDraft={value:'kept'};"));
  ASSERT_EQ(1, barc_window_select(work_id));
  BarcSplitLayout local_work{2, 0, {a, a2}, {.4}, a};
  ASSERT_EQ(1, barc_window_set_split(work_id, &local_work));
  BarcSplitLayout work_before{};
  ASSERT_EQ(1, barc_window_get_split(work_id, 0, &work_before));
  ASSERT_EQ(1, barc_window_select(personal_id));
  BarcSplitLayout local_personal{2, 0, {b, b2}, {.6}, b};
  ASSERT_EQ(1, barc_window_set_split(personal_id, &local_personal));
  BarcSplitLayout personal_before{};
  ASSERT_EQ(1, barc_window_get_split(personal_id, 0, &personal_before));
  ASSERT_EQ(1, barc_window_select(work_id));
  NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
  ASSERT_EQ(1, barc_window_attach_native_shell(work_id, (__bridge void*)header));
  ASSERT_EQ(1, barc_window_show(work_id));
  BarcSplitLayout mixed{2, 0, {a, b}, {.5}, a};
  ASSERT_EQ(1, barc_window_set_split(work_id, &mixed));
  widget->ClearBarcPresentedTabs(); // Automatic return is strictly view-only.
  BarcSplitLayout restored{};
  ASSERT_EQ(1, barc_window_get_split(work_id, 0, &restored));
  EXPECT_EQ(0u, restored.kind);
  EXPECT_EQ(work_before.collection, restored.collection);
  ASSERT_EQ(1, barc_window_get_split(personal_id, 0, &restored));
  EXPECT_EQ(personal_before.collection, restored.collection);
  auto* secondary = work_view->GetContentsContainerViewFor(tabs::TabHandle(a2).Get()->GetContents());
  ASSERT_TRUE(secondary);
  ASSERT_EQ(1, barc_window_set_split(work_id, &mixed));
  BarcSplitLayout mounted{};
  ASSERT_EQ(1, barc_window_get_split(work_id, 0, &mounted));
  bool reconfigured = false;
  {
    TryPresentationDuringOwnerReconcile observed(secondary,
        base::BindLambdaForTesting([&] {
          reconfigured = true;
          work->GetTabStripModel()->SetSplit(
              {tabs::TabHandle(a).Get(), tabs::TabHandle(a2).Get()},
              tabs::TabHandle(a).Get(),
              split_tabs::SplitTabVisualData(split_tabs::SplitTabLayout::kStacked, .7));
        }), true);
    EXPECT_EQ(0, barc_window_clear_split(work_id, a, &mounted));
  }
  EXPECT_TRUE(reconfigured);
  ASSERT_EQ(1, barc_window_get_split(work_id, 0, &restored));
  EXPECT_EQ(work_before.collection, restored.collection);
  EXPECT_EQ(1u, restored.orientation);
  EXPECT_DOUBLE_EQ(.7, restored.dividers[0]);
  EXPECT_EQ(a, restored.active_tab);
  ASSERT_EQ(1, barc_window_set_split(work_id, &mixed));
  ASSERT_EQ(1, barc_window_get_split(work_id, 0, &mounted));
  ASSERT_EQ(1, barc_window_clear_split(work_id, a, &mounted));
  EXPECT_EQ(0, barc_window_get_split(work_id, 0, &restored));
  EXPECT_FALSE(tabs::TabHandle(a).Get()->GetSplit());
  EXPECT_FALSE(tabs::TabHandle(a2).Get()->GetSplit());
  ASSERT_EQ(1, barc_window_get_split(personal_id, 0, &restored));
  EXPECT_EQ(personal_before.collection, restored.collection);
  EXPECT_EQ(2u, restored.count);
  EXPECT_EQ(a, work->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
  EXPECT_EQ(contents, work_view->GetActiveContentsContainerView()->contents_view()->web_contents());
  EXPECT_EQ("kept", content::EvalJs(contents, "ownedDraft.value"));
  EXPECT_EQ(1, barc_window_native_shell_is_owned(work_id, (__bridge void*)header));
}

// Real menu -> observed document intent -> one untouched admitted page. No
// synthetic event replay or direct role injection is used by these cases.
class BarcPeekBrowserTest : public BarcPromotionDiscoveryBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    BarcPromotionDiscoveryBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("site-per-process");
  }
 protected:
  int32_t Request(BrowserWindowInterface* source, const GURL& url,
                  NavigationEvents& events) {
    EXPECT_EQ(1, barc_tab_enable_peek(events.token, 1));
    auto* contents = source->GetTabStripModel()->GetActiveWebContents();
    content::ContextMenuParams params;
    params.page_url = contents->GetLastCommittedURL();
    params.frame_url = params.page_url;
    params.frame_origin = contents->GetPrimaryMainFrame()->GetLastCommittedOrigin();
    params.link_url = params.unfiltered_link_url = url;
    TestRenderViewContextMenu menu(*contents->GetPrimaryMainFrame(), params);
    menu.Init();
    EXPECT_TRUE(menu.IsItemPresent(IDC_CONTENT_CONTEXT_OPENLINKINPEEK));
    EXPECT_TRUE(menu.IsCommandIdEnabled(IDC_CONTENT_CONTEXT_OPENLINKINPEEK));
    menu.ExecuteCommand(IDC_CONTENT_CONTEXT_OPENLINKINPEEK, 0);
    if (events.events.empty() || events.events.back().kind != BARC_TAB_PEEK_REQUESTED)
      return 0;
    EXPECT_EQ(url.spec(), events.events.back().url);
    return events.events.back().error;
  }
  std::pair<int32_t, int32_t> Create(uint64_t token, int32_t request,
                                    NavigationEvents& events) {
    struct Admission {
      int32_t window = 0, tab = 0;
      raw_ptr<NavigationEvents> events;
    } admitted{0, 0, &events};
    const int result = barc_tab_create_peek(token, request,
        [](void* context, int32_t window, int32_t tab) -> int {
          auto* admitted = static_cast<Admission*>(context);
          auto* owner = SharedWindow(window);
          auto* page = owner ? tabs::TabHandle(tab).Get() : nullptr;
          EXPECT_TRUE(page);
          if (!page) return 0;
          EXPECT_TRUE(page->GetContents()->GetController().IsInitialBlankNavigation());
          EXPECT_EQ(nullptr, page->GetContents()->GetController().GetPendingEntry());
          EXPECT_FALSE(page->GetContents()->HasOpener());
          EXPECT_FALSE(owner->IsSelectedForNativeWindow());
          admitted->window = window; admitted->tab = tab;
          admitted->events->token = barc_tab_observe(window, tab,
              NavigationEvents::Receive, admitted->events.get());
          EXPECT_EQ(1, barc_tab_enable_peek(admitted->events->token, 1));
          EXPECT_FALSE(barc::CanRequestPeek(page->GetContents()->GetPrimaryMainFrame()));
          return admitted->events->token != 0;
        }, &admitted);
    EXPECT_EQ(1, result);
    return {admitted.window, admitted.tab};
  }
};

IN_PROC_BROWSER_TEST_F(BarcPeekBrowserTest, MenuIntentIsDocumentBoundAndConsumedOnce) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t source_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* source = SharedWindow(source_id);
  ASSERT_TRUE(source);
  NSView* source_header = Attach(source_id);
  ASSERT_TRUE(source_header);
  ASSERT_EQ(1, barc_window_show(source_id));
  Navigate(source, embedded_test_server()->GetURL("/title1.html"));
  auto* original = source->GetTabStripModel()->GetActiveWebContents();
  const auto original_document = original->GetPrimaryMainFrame()->GetDocumentToken();
  ASSERT_TRUE(content::ExecJs(original, R"(
    document.body.innerHTML='<input id=peekDraft>';
    window.peekDraftNode=document.getElementById('peekDraft');
    peekDraftNode.value='unsaved-source-draft';
    window.peekLiveState=(()=>{let value=10;return()=>++value})();
  )"));
  EXPECT_EQ(11, content::EvalJs(original, "peekLiveState()"));
  NavigationEvents source_events, peek_events;
  source_events.token = barc_tab_observe(source_id, barc_window_tab_at(source_id, 0),
                                        NavigationEvents::Receive, &source_events);
  ASSERT_NE(0u, source_events.token);
  const auto original_url = original->GetLastCommittedURL();
  // A utility-only observer has no PageSession Peek capability. The ordinary
  // native menu must not advertise an action its sink cannot handle.
  content::ContextMenuParams utility_params;
  utility_params.page_url = original_url; utility_params.frame_url = original_url;
  utility_params.frame_origin = original->GetPrimaryMainFrame()->GetLastCommittedOrigin();
  utility_params.link_url = utility_params.unfiltered_link_url =
      embedded_test_server()->GetURL("/title2.html");
  TestRenderViewContextMenu utility_menu(*original->GetPrimaryMainFrame(), utility_params);
  utility_menu.Init();
  EXPECT_FALSE(utility_menu.IsItemPresent(IDC_CONTENT_CONTEXT_OPENLINKINPEEK));
  EXPECT_EQ(0, barc_tab_enable_peek(source_events.token, 2));
  const int32_t first = Request(source, embedded_test_server()->GetURL("/title1.html?old"), source_events);
  const GURL target = embedded_test_server()->GetURL("/title2.html");
  const int32_t latest = Request(source, target, source_events);
  ASSERT_GT(first, 0);
  ASSERT_GT(latest, first);
  EXPECT_EQ(0, barc_tab_create_peek(source_events.token, first,
      [](void*, int32_t, int32_t) -> int { ADD_FAILURE(); return 1; }, nullptr));
  const auto [peer_id, peek_id] = Create(source_events.token, latest, peek_events);
  auto* peer = SharedWindow(peer_id);
  ASSERT_TRUE(peer);
  auto* peek = tabs::TabHandle(peek_id).Get();
  ASSERT_TRUE(peek);
  ASSERT_TRUE(content::WaitForLoadStop(peek->GetContents()));
  EXPECT_EQ(target, peek->GetContents()->GetLastCommittedURL());
  EXPECT_EQ(original_url, original->GetLastCommittedURL());
  EXPECT_EQ(source->GetProfile(), peer->GetProfile());
  EXPECT_EQ(source->GetWindow()->GetNativeWindow(), peer->GetWindow()->GetNativeWindow());
  EXPECT_TRUE(source->IsSelectedForNativeWindow());
  EXPECT_EQ(original, source->GetTabStripModel()->GetActiveWebContents());
  EXPECT_EQ(original_document, original->GetPrimaryMainFrame()->GetDocumentToken());
  EXPECT_EQ("unsaved-source-draft", content::EvalJs(original, "peekDraft.value"));
  EXPECT_EQ(true, content::EvalJs(original, "peekDraftNode===document.getElementById('peekDraft')"));
  EXPECT_EQ(12, content::EvalJs(original, "peekLiveState()"));
  EXPECT_EQ(1u, peek_events.Count(BARC_TAB_STARTED));
  EXPECT_FALSE(peek->GetContents()->HasOpener());
  EXPECT_EQ(0, barc_tab_create_peek(source_events.token, latest,
      [](void*, int32_t, int32_t) -> int { ADD_FAILURE(); return 1; }, nullptr));
  auto peek_alive = peek->GetWeakPtr();
  ASSERT_EQ(1, barc_tab_close(peer_id, peek_id));
  ASSERT_TRUE(base::test::RunUntil([&] { return !peek_alive; }));
  const int32_t disabled = Request(source, target, source_events);
  ASSERT_EQ(1, barc_tab_enable_peek(source_events.token, 0));
  EXPECT_EQ(0, barc_tab_create_peek(source_events.token, disabled,
      [](void*, int32_t, int32_t) -> int { ADD_FAILURE(); return 1; }, nullptr));
  const int32_t stale = Request(source, target, source_events);
  ASSERT_GT(stale, 0);
  content::TestNavigationObserver reload(original);
  ASSERT_EQ(1, barc_tab_reload(source_id, barc_window_tab_at(source_id, 0)));
  reload.Wait();
  EXPECT_EQ(0, barc_tab_create_peek(source_events.token, stale,
      [](void*, int32_t, int32_t) -> int { ADD_FAILURE(); return 1; }, nullptr));
  auto source_alive = source->GetWeakPtr();
  ASSERT_EQ(1, barc_window_close(source_id));
  ASSERT_TRUE(base::test::RunUntil([&] { return !source_alive; }));
  EXPECT_EQ(0, barc_tab_create_peek(source_events.token, stale,
      [](void*, int32_t, int32_t) -> int { ADD_FAILURE(); return 1; }, nullptr));
}

IN_PROC_BROWSER_TEST_F(BarcPeekBrowserTest, AdmissionNavigationRetainsExactLivePage) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t source_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* source = SharedWindow(source_id);
  ASSERT_TRUE(source);
  NSView* header = Attach(source_id);
  ASSERT_TRUE(header);
  ASSERT_EQ(1, barc_window_show(source_id));
  Navigate(source, embedded_test_server()->GetURL("/title1.html"));
  NavigationEvents events;
  events.token = barc_tab_observe(source_id, barc_window_tab_at(source_id, 0),
                                NavigationEvents::Receive, &events);
  const GURL requested = embedded_test_server()->GetURL("/title2.html?peek");
  struct Admission {
    GURL newer;
    base::WeakPtr<tabs::TabInterface> page;
  } admission{embedded_test_server()->GetURL("/title1.html?newer"), {}};
  const int32_t request = Request(source, requested, events);
  ASSERT_GT(request, 0);
  EXPECT_EQ(0, barc_tab_create_peek(events.token, request,
      [](void* context, int32_t, int32_t tab) -> int {
        auto* admission = static_cast<Admission*>(context);
        auto* page = tabs::TabHandle(tab).Get();
        if (!page) return 0;
        admission->page = page->GetWeakPtr();
        content::NavigationController::LoadURLParams params(admission->newer);
        page->GetContents()->GetController().LoadURLWithParams(params);
        return 1;
      }, &admission));
  ASSERT_TRUE(admission.page);
  ASSERT_TRUE(content::WaitForLoadStop(admission.page->GetContents()));
  EXPECT_EQ(admission.newer, admission.page->GetContents()->GetLastCommittedURL());
  EXPECT_EQ(nullptr, barc::PeekForSource(source->GetTabStripModel()->GetActiveTab()));
  // A newer admitted navigation owns this page. Refusal removes only its old
  // Peek role; it neither closes that page nor replays the originally clicked URL.
  DiscoveryRows snapshot;
  snapshot.Read();
  auto row = std::ranges::find(snapshot.tabs, admission.page->GetHandle().raw_value(),
                              &BarcDiscoveryTab::tab);
  ASSERT_NE(row, snapshot.tabs.end());
  EXPECT_EQ(0u, row->flags & BARC_DISCOVERY_TAB_PEEK);
  EXPECT_TRUE(source->IsSelectedForNativeWindow());
}

IN_PROC_BROWSER_TEST_F(BarcPeekBrowserTest, CardReturnsExactContainerBeforeHideAndClose) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t source_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* source = SharedWindow(source_id);
  ASSERT_TRUE(source);
  NSView* sidebar = Attach(source_id);
  ASSERT_TRUE(sidebar);
  ASSERT_EQ(1, barc_window_show(source_id));
  auto* source_view = BrowserView::GetBrowserViewForBrowser(source);
  auto* widget = source_view->browser_widget();
  widget->LayoutRootViewIfNecessary();
  const gfx::Rect before_header = source_view->multi_contents_view()->bounds();
  NSView* page_bar = [[NSView alloc] init];
  ASSERT_EQ(1, barc_window_set_native_header(source_id, (__bridge void*)sidebar,
      nullptr, (__bridge void*)page_bar, 40));
  widget->LayoutRootViewIfNecessary();
  EXPECT_EQ(40, barc::NativeShellHeight(source_view));
  const gfx::Rect with_header = source_view->multi_contents_view()->bounds();
  EXPECT_EQ(before_header.width(), with_header.width());
  EXPECT_EQ(before_header.height() - 40, with_header.height());
  EXPECT_EQ(before_header.y() + 40, with_header.y());
  EXPECT_LE(source_view->barc_page_header()->bounds().bottom(), with_header.y());
  ASSERT_EQ(1, barc_window_set_native_header(source_id, (__bridge void*)sidebar,
      (__bridge void*)page_bar, (__bridge void*)page_bar, 38));
  widget->LayoutRootViewIfNecessary();
  EXPECT_EQ(before_header.height() - 38, source_view->multi_contents_view()->height());
  ASSERT_EQ(1, barc_window_set_native_header(source_id, (__bridge void*)sidebar,
      (__bridge void*)page_bar, nullptr, 0));
  widget->LayoutRootViewIfNecessary();
  EXPECT_EQ(before_header, source_view->multi_contents_view()->bounds());
  ASSERT_EQ(1, barc_window_set_native_header(source_id, (__bridge void*)sidebar,
      nullptr, (__bridge void*)page_bar, 40));
  Navigate(source, embedded_test_server()->GetURL("/title1.html"));
  auto* source_tab = source->GetTabStripModel()->GetActiveTab();
  const int32_t source_tab_id = source_tab->GetHandle().raw_value();
  const int32_t second = barc_tab_create(source_id, "about:blank", 0);
  const int32_t third = barc_tab_create(source_id, "about:blank", 0);
  const int32_t fourth = barc_tab_create(source_id, "about:blank", 0);
  ASSERT_TRUE(second && third && fourth);
  BarcSplitLayout local{4, 0, {source_tab_id, second, third, fourth}, {.2, .5, .8}, source_tab_id};
  ASSERT_EQ(1, barc_window_set_split(source_id, &local));
  BarcSplitLayout original_split{};
  ASSERT_EQ(1, barc_window_get_split(source_id, 0, &original_split));
  NavigationEvents source_events, peek_events;
  source_events.token = barc_tab_observe(source_id, source_tab_id,
                                        NavigationEvents::Receive, &source_events);
  const int32_t request = Request(source, embedded_test_server()->GetURL("/title2.html"), source_events);
  auto [peer_id, peek_id] = Create(source_events.token, request, peek_events);
  auto* peek = tabs::TabHandle(peek_id).Get();
  ASSERT_TRUE(peek);
  ASSERT_TRUE(content::WaitForLoadStop(peek->GetContents()));
  ASSERT_TRUE(content::ExecJs(peek->GetContents(), "window.peekIdentity = {value:42};"));
  // Header configuration belongs to this exact sidebar, not the selected page.
  // A legal logical-client selection during native attachment cannot strand an
  // attached replacement behind a false refusal/expected-null retry loop.
  ASSERT_EQ(1, barc_window_select(source_id));
  BarcReentrantNativeView* selecting_bar = [[BarcReentrantNativeView alloc] init];
  __block bool selected_during_header = false;
  const int32_t header_selection_target = peer_id;
  selecting_bar.onMove = ^(NSView*) {
    selected_during_header = true;
    EXPECT_EQ(1, barc_window_select(header_selection_target));
  };
  ASSERT_EQ(1, barc_window_set_native_header(source_id, (__bridge void*)sidebar,
      (__bridge void*)page_bar, (__bridge void*)selecting_bar, 40));
  selecting_bar.onMove = nil;
  EXPECT_TRUE(selected_during_header);
  EXPECT_TRUE(SharedWindow(peer_id)->IsSelectedForNativeWindow());
  page_bar = selecting_bar;
  EXPECT_EQ(page_bar, source_view->barc_page_header()->native_view().GetNativeNSView());
  EXPECT_EQ(1, barc_window_set_native_header(source_id, (__bridge void*)sidebar,
      (__bridge void*)page_bar, (__bridge void*)page_bar, 40));
  ASSERT_EQ(1, barc_window_select(source_id));
  auto* original = peek->GetContents();
  NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 32)];
  NSView* actions = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 28, 96)];
  const uint64_t card = barc_tab_present_peek(source_id, source_tab_id, peer_id, peek_id,
      (__bridge void*)sidebar, (__bridge void*)header, (__bridge void*)actions);
  ASSERT_NE(0u, card);
  EXPECT_EQ(1, barc_tab_is_peek_presented(source_id, source_tab_id, peer_id, peek_id,
      card, (__bridge void*)header, (__bridge void*)actions));
  EXPECT_TRUE(SharedWindow(peer_id)->IsSelectedForNativeWindow());
  ExpectNoStockChrome(BrowserView::GetBrowserViewForBrowser(SharedWindow(peer_id)));
  EXPECT_TRUE(source_tab->GetContents()->ShouldIgnoreInputEventsForTesting());
  EXPECT_EQ(1, barc_window_native_shell_is_owned(peer_id, (__bridge void*)sidebar));
  auto* peek_view = BrowserView::GetBrowserViewForBrowser(SharedWindow(peer_id));
  EXPECT_FALSE(source_view->barc_page_header()->native_view());
  EXPECT_EQ(page_bar, peek_view->barc_page_header()->native_view().GetNativeNSView());
  EXPECT_EQ(40, barc::NativeShellHeight(peek_view));
  EXPECT_EQ(0, barc_window_set_native_header(source_id, (__bridge void*)sidebar,
      (__bridge void*)page_bar, nullptr, 0));
  EXPECT_EQ(0, barc_tab_hide_peek(source_id, source_tab_id, peer_id, peek_id,
      card + 1, (__bridge void*)header, (__bridge void*)actions));
  EXPECT_EQ(1, barc_tab_hide_peek(source_id, source_tab_id, peer_id, peek_id,
      card, (__bridge void*)header, (__bridge void*)actions));
  EXPECT_FALSE(source_tab->GetContents()->ShouldIgnoreInputEventsForTesting());
  EXPECT_TRUE(source->IsSelectedForNativeWindow());
  EXPECT_EQ(1, barc_window_native_shell_is_owned(source_id, (__bridge void*)sidebar));
  EXPECT_FALSE(peek_view->barc_page_header()->native_view());
  EXPECT_EQ(page_bar, source_view->barc_page_header()->native_view().GetNativeNSView());
  EXPECT_EQ(40, barc::NativeShellHeight(source_view));
  EXPECT_FALSE(header.superview);
  EXPECT_FALSE(actions.superview);
  EXPECT_EQ(original, peek->GetContents());
  EXPECT_EQ(42, content::EvalJs(original, "peekIdentity.value"));
  EXPECT_EQ(1u, peek_events.Count(BARC_TAB_STARTED));
  EXPECT_EQ(content::Visibility::HIDDEN, original->GetVisibility());
  const uint64_t next = barc_tab_present_peek(source_id, source_tab_id, peer_id, peek_id,
      (__bridge void*)sidebar, (__bridge void*)header, (__bridge void*)actions);
  ASSERT_GT(next, card);
  // A real foreground ordinary tab can reuse this helper BWI. It hides the
  // card without consuming the retained per-source Peek or its live document.
  const int32_t ordinary_id = barc_tab_create(peer_id, "about:blank", 1);
  ASSERT_GT(ordinary_id, 0);
  auto ordinary = tabs::TabHandle(ordinary_id).Get()->GetWeakPtr();
  EXPECT_FALSE(BrowserView::GetBrowserViewForBrowser(source)->browser_widget()->HasBarcPeek());
  ASSERT_TRUE(barc::IsPeekPair(source_tab, peek));
  ASSERT_EQ(1, barc_tab_select(source_id, source_tab_id));
  ASSERT_EQ(1, barc_window_detach_native_shell_if_owned(peer_id, (__bridge void*)sidebar));
  ASSERT_EQ(1, barc_window_attach_native_shell(source_id, (__bridge void*)sidebar));
  const uint64_t reopened = barc_tab_present_peek(source_id, source_tab_id, peer_id, peek_id,
      (__bridge void*)sidebar, (__bridge void*)header, (__bridge void*)actions);
  ASSERT_GT(reopened, next);
  EXPECT_TRUE(peek->IsActivated());
  EXPECT_TRUE(ordinary);
  EXPECT_EQ(original, peek->GetContents());
  EXPECT_EQ(42, content::EvalJs(original, "peekIdentity.value"));
  EXPECT_EQ(1u, peek_events.Count(BARC_TAB_STARTED));
  auto alive = peek->GetWeakPtr();
  ASSERT_EQ(1, barc_tab_close(peer_id, peek_id));
  ASSERT_TRUE(base::test::RunUntil([&] { return !alive; }));
  EXPECT_TRUE(source->IsSelectedForNativeWindow());
  EXPECT_FALSE(header.superview);
  EXPECT_FALSE(actions.superview);
  EXPECT_FALSE(source_tab->GetContents()->ShouldIgnoreInputEventsForTesting());
  EXPECT_TRUE(ordinary);
  BarcSplitLayout restored{};
  ASSERT_EQ(1, barc_window_get_split(source_id, 0, &restored));
  EXPECT_EQ(original_split.collection, restored.collection);
  EXPECT_EQ(4u, restored.count);
  EXPECT_EQ(original_split.tabs[3], restored.tabs[3]);
}

IN_PROC_BROWSER_TEST_F(BarcPeekBrowserTest, CardBorrowOwnerDestructionReturnsBeforeHierarchyUnwinds) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t source_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* source = SharedWindow(source_id);
  ASSERT_TRUE(source);
  NSView* sidebar = Attach(source_id);
  ASSERT_TRUE(sidebar);
  ASSERT_EQ(1, barc_window_show(source_id));
  NSView* page_bar = [[NSView alloc] init];
  ASSERT_EQ(1, barc_window_set_native_header(source_id, (__bridge void*)sidebar,
      nullptr, (__bridge void*)page_bar, 40));
  Navigate(source, embedded_test_server()->GetURL("/title1.html"));
  auto* source_tab = source->GetTabStripModel()->GetActiveTab();
  const int32_t source_tab_id = source_tab->GetHandle().raw_value();
  NavigationEvents source_events, peek_events;
  source_events.token = barc_tab_observe(source_id, source_tab_id,
                                        NavigationEvents::Receive, &source_events);
  const auto [peer_id, peek_id] = Create(source_events.token,
      Request(source, embedded_test_server()->GetURL("/title2.html"), source_events), peek_events);
  auto* peek = tabs::TabHandle(peek_id).Get();
  ASSERT_TRUE(peek);
  ASSERT_TRUE(content::WaitForLoadStop(peek->GetContents()));
  auto peek_alive = peek->GetWeakPtr();
  auto* retained_peek = peek->GetContents();
  const auto retained_document = retained_peek->GetPrimaryMainFrame()->GetDocumentToken();
  ASSERT_TRUE(content::ExecJs(retained_peek, R"(
    document.body.innerHTML='<input id=retainedDraft>';
    retainedDraft.value='still-live';
    window.retainedNode=document.getElementById('retainedDraft');
    window.retainedClosure=(()=>{let value=20;return()=>++value})();
  )"));
  EXPECT_EQ(21, content::EvalJs(retained_peek, "retainedClosure()"));
  class RetirementObserver final : public BrowserCollectionObserver {
   public:
    explicit RetirementObserver(int32_t id) : id_(id) {}
    void OnBrowserClosed(BrowserWindowInterface* browser) override {
      if (browser->GetSessionID().id() != id_) return;
      ++closed;
      valid_window = browser->GetWindow() &&
                     browser->GetWindow()->GetNativeWindow();
    }
    int closed = 0;
    bool valid_window = false;
   private:
    const int32_t id_;
  } retired(source_id);
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver>
      retirement_observation(&retired);
  retirement_observation.Observe(GlobalBrowserCollection::GetInstance());
  auto source_alive = source->GetWeakPtr();
  auto* source_view = BrowserView::GetBrowserViewForBrowser(source);
  auto* widget = source_view->browser_widget();
  views::ViewTracker original_parent(source_view->multi_contents_view());
  views::ViewTracker moved_child(
      source_view->GetContentsContainerViewFor(source_tab->GetContents()));
  CloseLogicalOwnerOnBorrow close(widget->non_client_view(),
      source_view->GetContentsContainerViewFor(source_tab->GetContents()),
      base::BindLambdaForTesting([&] {
        BrowserManagerService::SynchronouslyDestroyBrowser(source_alive.get());
        EXPECT_FALSE(page_bar.superview);
        EXPECT_EQ(0, barc_window_set_native_header(source_id, (__bridge void*)sidebar,
            (__bridge void*)page_bar, nullptr, 0));
        ASSERT_TRUE(original_parent);
        EXPECT_FALSE(original_parent.view()->parent());
        EXPECT_TRUE(original_parent.view()->children().empty());
        ASSERT_TRUE(moved_child);
        auto* empty_child = views::AsViewClass<ContentsContainerView>(moved_child.view());
        ASSERT_TRUE(empty_child);
        EXPECT_FALSE(empty_child->parent());
        EXPECT_TRUE(empty_child->children().empty());
        EXPECT_FALSE(empty_child->browser_view());
        EXPECT_FALSE(empty_child->contents_view());
        EXPECT_FALSE(empty_child->web_contents_modal_dialog_host());
        base::RunLoop().RunUntilIdle();
        EXPECT_TRUE(original_parent);
        EXPECT_TRUE(moved_child);
      }));
  NSView* header = [[NSView alloc] initWithFrame:NSZeroRect];
  NSView* actions = [[NSView alloc] initWithFrame:NSZeroRect];
  EXPECT_EQ(0u, barc_tab_present_peek(source_id, source_tab_id, peer_id, peek_id,
      (__bridge void*)sidebar, (__bridge void*)header, (__bridge void*)actions));
  EXPECT_TRUE(close.requested());
  EXPECT_FALSE(original_parent);
  EXPECT_FALSE(moved_child);
  EXPECT_FALSE(source_alive);
  ASSERT_TRUE(peek_alive);
  EXPECT_EQ(1, retired.closed);
  EXPECT_TRUE(retired.valid_window);
  EXPECT_EQ(1u, source_events.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(0u, peek_events.Count(BARC_TAB_CLOSED));
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1, retired.closed);
  EXPECT_EQ(1u, source_events.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(0u, peek_events.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(retained_peek, peek_alive->GetContents());
  EXPECT_EQ(retained_document, retained_peek->GetPrimaryMainFrame()->GetDocumentToken());
  EXPECT_EQ("still-live", content::EvalJs(retained_peek, "retainedDraft.value"));
  EXPECT_EQ(true, content::EvalJs(retained_peek, "retainedNode===document.getElementById('retainedDraft')"));
  EXPECT_EQ(22, content::EvalJs(retained_peek, "retainedClosure()"));
  EXPECT_FALSE(header.superview);
  EXPECT_FALSE(actions.superview);
  auto* peer_view = BrowserView::GetBrowserViewForBrowser(SharedWindow(peer_id));
  ASSERT_TRUE(peer_view);
  EXPECT_EQ(peer_view->multi_contents_view(),
      peer_view->GetContentsContainerViewFor(peek_alive->GetContents())->parent());
}

IN_PROC_BROWSER_TEST_F(BarcPeekBrowserTest, CardBorrowPreservesNewerSourceTabSelection) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t source_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* source = SharedWindow(source_id);
  ASSERT_TRUE(source);
  NSView* sidebar = Attach(source_id);
  ASSERT_TRUE(sidebar);
  ASSERT_EQ(1, barc_window_show(source_id));
  Navigate(source, embedded_test_server()->GetURL("/title1.html"));
  auto* source_tab = source->GetTabStripModel()->GetActiveTab();
  const int32_t source_tab_id = source_tab->GetHandle().raw_value();
  const int32_t newer = barc_tab_create(source_id, "about:blank", 0);
  ASSERT_GT(newer, 0);
  NavigationEvents source_events, peek_events;
  source_events.token = barc_tab_observe(source_id, source_tab_id,
                                        NavigationEvents::Receive, &source_events);
  const auto [peer_id, peek_id] = Create(source_events.token,
      Request(source, embedded_test_server()->GetURL("/title2.html"), source_events), peek_events);
  auto* source_view = BrowserView::GetBrowserViewForBrowser(source);
  auto* widget = source_view->browser_widget();
  CloseLogicalOwnerOnBorrow select(widget->non_client_view(),
      source_view->GetContentsContainerViewFor(source_tab->GetContents()),
      base::BindLambdaForTesting([&] {
        auto* next = tabs::TabHandle(newer).Get();
        source->GetTabStripModel()->ActivateTabAt(
            source->GetTabStripModel()->GetIndexOfWebContents(next->GetContents()));
      }));
  NSView* header = [[NSView alloc] initWithFrame:NSZeroRect];
  NSView* actions = [[NSView alloc] initWithFrame:NSZeroRect];
  EXPECT_EQ(0u, barc_tab_present_peek(source_id, source_tab_id, peer_id, peek_id,
      (__bridge void*)sidebar, (__bridge void*)header, (__bridge void*)actions));
  ASSERT_TRUE(select.requested());
  EXPECT_EQ(tabs::TabHandle(newer).Get(), source->GetTabStripModel()->GetActiveTab());
  EXPECT_TRUE(source->IsSelectedForNativeWindow());
  EXPECT_EQ(1, barc_window_native_shell_is_owned(source_id, (__bridge void*)sidebar));
  EXPECT_TRUE(tabs::TabHandle(peek_id).Get());
  EXPECT_FALSE(header.superview);
  EXPECT_FALSE(actions.superview);
  EXPECT_FALSE(widget->HasBarcPeek());
  ASSERT_EQ(1, barc_tab_select(source_id, source_tab_id));
  const int32_t previous = barc_tab_create(peer_id, "about:blank", 0);
  const int32_t replacement = barc_tab_create(peer_id, "about:blank", 0);
  ASSERT_TRUE(previous && replacement);
  auto* peer = SharedWindow(peer_id);
  auto* model = peer->GetTabStripModel();
  model->ActivateTabAt(model->GetIndexOfWebContents(tabs::TabHandle(previous).Get()->GetContents()));
  CloseLogicalOwnerOnBorrow select_peer(widget->non_client_view(),
      source_view->GetContentsContainerViewFor(source_tab->GetContents()),
      base::BindLambdaForTesting([&] {
        model->ActivateTabAt(model->GetIndexOfWebContents(tabs::TabHandle(replacement).Get()->GetContents()));
      }));
  EXPECT_EQ(0u, barc_tab_present_peek(source_id, source_tab_id, peer_id, peek_id,
      (__bridge void*)sidebar, (__bridge void*)header, (__bridge void*)actions));
  ASSERT_TRUE(select_peer.requested());
  // Refusal must not restore the operation's former peer tab over this newer
  // selection, even though the physical logical-owner epoch did not change.
  EXPECT_EQ(tabs::TabHandle(replacement).Get(), model->GetActiveTab());
  EXPECT_TRUE(source->IsSelectedForNativeWindow());
  EXPECT_EQ(1, barc_window_native_shell_is_owned(source_id, (__bridge void*)sidebar));
  EXPECT_TRUE(tabs::TabHandle(peek_id).Get());
  EXPECT_FALSE(widget->HasBarcPeek());
}

IN_PROC_BROWSER_TEST_F(BarcPeekBrowserTest, EitherBeforeUnloadVetoRetainsBothPages) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t source_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* source = SharedWindow(source_id);
  ASSERT_TRUE(source);
  NSView* source_header = Attach(source_id);
  ASSERT_TRUE(source_header);
  ASSERT_EQ(1, barc_window_show(source_id));
  Navigate(source, embedded_test_server()->GetURL("/title1.html"));
  const int32_t source_tab = barc_window_tab_at(source_id, 0);
  const int32_t other_id = barc_tab_create(source_id,
      embedded_test_server()->GetURL("/title1.html?unrelated").spec().c_str(), 0);
  ASSERT_GT(other_id, 0);
  auto other = tabs::TabHandle(other_id).Get()->GetWeakPtr();
  ASSERT_TRUE(other && content::WaitForLoadStop(other->GetContents()));
  ASSERT_TRUE(content::ExecJs(other->GetContents(),
      "window.beforeCount=0;onbeforeunload=()=>{++beforeCount;return 'unrelated';};"));
  NavigationEvents source_events, peek_events, other_events;
  other_events.token = barc_tab_observe(source_id, other_id, NavigationEvents::Receive, &other_events);
  source_events.token = barc_tab_observe(source_id, source_tab, NavigationEvents::Receive, &source_events);
  const auto [peer_id, peek_id] = Create(source_events.token,
      Request(source, embedded_test_server()->GetURL("/title2.html"), source_events), peek_events);
  auto source_alive = tabs::TabHandle(source_tab).Get()->GetWeakPtr();
  auto peek_alive = tabs::TabHandle(peek_id).Get()->GetWeakPtr();
  ASSERT_TRUE(peek_alive && content::WaitForLoadStop(peek_alive->GetContents()));
  auto* widget = BrowserView::GetBrowserViewForBrowser(source)->browser_widget();
  for (const auto& page : {source_alive, peek_alive}) {
    ASSERT_TRUE(content::ExecJs(page->GetContents(),
        "document.body.innerHTML='<input id=draft>';draft.value='keep';"
        "window.liveMarker={};onbeforeunload=()=> 'keep draft';"));
    content::PrepContentsForBeforeUnloadTest(page->GetContents());
  }
  ASSERT_EQ(1, barc_tab_close(source_id, source_tab));
  auto* source_prompt = ui_test_utils::WaitForAppModalDialog();
  ASSERT_EQ(source_alive->GetContents(), source_prompt->web_contents());
  // A concurrent unrelated extension/tab close must refuse its own attempt,
  // not reset this cohort's shared controller or dispatch a second dialog.
  ASSERT_EQ(1, barc_tab_close(source_id, other_id));
  EXPECT_TRUE(other);
  EXPECT_EQ(1u, other_events.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_TRUE(widget->HasPhysicalClosePending());
  source_prompt->view()->AcceptAppModalDialog();
  auto* peek_prompt = ui_test_utils::WaitForAppModalDialog();
  ASSERT_EQ(peek_alive->GetContents(), peek_prompt->web_contents());
  // Source consent has not destroyed either page while Peek can still refuse.
  ASSERT_TRUE(source_alive && peek_alive);
  peek_prompt->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] { return !widget->HasPhysicalClosePending(); }));
  ASSERT_TRUE(source_alive && peek_alive);
  EXPECT_TRUE(barc::IsPeekPair(source_alive.get(), peek_alive.get()));
  EXPECT_EQ(0u, source_events.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(0u, peek_events.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(1u, source_events.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(0, content::EvalJs(other->GetContents(), "beforeCount"));
  for (const auto& page : {source_alive, peek_alive})
    EXPECT_EQ("keep", content::EvalJs(page->GetContents(), "draft.value"));
  const auto peek_cancellations_before_retry = peek_events.Count(BARC_TAB_CLOSE_CANCELLED);
  bool retried = false;
  source_events.on_cancelled = base::BindLambdaForTesting([&] {
    retried = true;
    // Real synchronous native tabstrip retry from the refusal callout. The
    // old continuation must not reset the new request's gesture/controller.
    source_alive->GetBrowserWindowInterface()->GetTabStripModel()->CloseWebContents(
        source_alive->GetContents(), TabCloseTypes::CLOSE_USER_GESTURE);
  });
  ASSERT_EQ(1, barc_tab_close(source_id, source_tab));
  source_prompt = ui_test_utils::WaitForAppModalDialog();
  ASSERT_EQ(source_alive->GetContents(), source_prompt->web_contents());
  source_prompt->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] { return retried; }));
  ASSERT_TRUE(source_alive && peek_alive);
  EXPECT_TRUE(source_alive->GetContents()->GetClosedByUserGesture());
  EXPECT_EQ(peek_cancellations_before_retry, peek_events.Count(BARC_TAB_CLOSE_CANCELLED));
  source_prompt = ui_test_utils::WaitForAppModalDialog();
  ASSERT_EQ(source_alive->GetContents(), source_prompt->web_contents());
  source_prompt->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] { return !widget->HasPhysicalClosePending(); }));
  ASSERT_TRUE(source_alive && peek_alive);
  for (const auto& page : {source_alive, peek_alive})
    ASSERT_TRUE(content::ExecJs(page->GetContents(), "onbeforeunload=null;"));
  ASSERT_EQ(1, barc_tab_close(source_id, source_tab));
  ASSERT_TRUE(base::test::RunUntil([&] { return !source_alive && !peek_alive; }));
  ASSERT_TRUE(other);
  EXPECT_EQ(0, content::EvalJs(other->GetContents(), "beforeCount"));
  ASSERT_TRUE(content::ExecJs(other->GetContents(), "onbeforeunload=null;"));
}

IN_PROC_BROWSER_TEST_F(BarcPeekBrowserTest, LogicalSourceCloseKeepsUnrelatedPeerTabs) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t source_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* source = SharedWindow(source_id);
  ASSERT_TRUE(source);
  NSView* sidebar = Attach(source_id);
  ASSERT_TRUE(sidebar);
  ASSERT_EQ(1, barc_window_show(source_id));
  Navigate(source, embedded_test_server()->GetURL("/title1.html"));
  auto* source_tab = source->GetTabStripModel()->GetActiveTab();
  NavigationEvents source_events, peek_events;
  source_events.token = barc_tab_observe(source_id, source_tab->GetHandle().raw_value(),
                                        NavigationEvents::Receive, &source_events);
  const int32_t request = Request(source, embedded_test_server()->GetURL("/title2.html"), source_events);
  const auto [peer_id, peek_id] = Create(source_events.token, request, peek_events);
  auto* peer = SharedWindow(peer_id);
  auto* peek = tabs::TabHandle(peek_id).Get();
  ASSERT_TRUE(peer);
  ASSERT_TRUE(peek);
  ASSERT_TRUE(content::WaitForLoadStop(peek->GetContents()));
  auto source_alive = source_tab->GetWeakPtr();
  auto peek_alive = peek->GetWeakPtr();
  const int32_t other_source = barc_tab_create(source_id, "about:blank", 0);
  const int32_t other_peer = barc_tab_create(peer_id, "about:blank", 0);
  ASSERT_GT(other_source, 0);
  ASSERT_GT(other_peer, 0);
  auto source_other_alive = tabs::TabHandle(other_source).Get()->GetWeakPtr();
  auto peer_other_alive = tabs::TabHandle(other_peer).Get()->GetWeakPtr();
  ASSERT_TRUE(content::ExecJs(peek->GetContents(),
      "window.beforeCount=0; onbeforeunload=()=>{ ++beforeCount; return 'retain'; };"));
  content::PrepContentsForBeforeUnloadTest(peek->GetContents());
  ASSERT_EQ(1, barc_window_close(source_id));
  auto* prompt = ui_test_utils::WaitForAppModalDialog();
  ASSERT_EQ(peek->GetContents(), prompt->web_contents());
  prompt->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] { return source_alive && peek_alive &&
      !BrowserView::GetBrowserViewForBrowser(peer)->browser_widget()->HasPhysicalClosePending(); }));
  EXPECT_TRUE(source_other_alive);
  EXPECT_TRUE(peer_other_alive);
  ASSERT_TRUE(content::ExecJs(peek->GetContents(), "onbeforeunload=null;"));
  ASSERT_EQ(1, barc_window_close(source_id));
  ASSERT_TRUE(base::test::RunUntil([&] { return !source_alive && !source_other_alive && !peek_alive; }));
  EXPECT_TRUE(peer_other_alive);
  EXPECT_EQ(peer, peer_other_alive->GetBrowserWindowInterface());
  EXPECT_EQ(1u, peek_events.Count(BARC_TAB_STARTED));
}

IN_PROC_BROWSER_TEST_F(BarcPeekBrowserTest, PromotionDuringCloseAdmissionKeepsExactLivePage) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t source_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* source = SharedWindow(source_id);
  ASSERT_TRUE(source);
  NSView* source_header = Attach(source_id);
  ASSERT_TRUE(source_header);
  ASSERT_EQ(1, barc_window_show(source_id));
  Navigate(source, embedded_test_server()->GetURL("/title1.html"));
  const int32_t source_tab = barc_window_tab_at(source_id, 0);
  NavigationEvents source_events, peek_events;
  source_events.token = barc_tab_observe(source_id, source_tab, NavigationEvents::Receive, &source_events);
  const auto [peer_id, peek_id] = Create(source_events.token,
      Request(source, embedded_test_server()->GetURL("/title2.html"), source_events), peek_events);
  auto source_alive = tabs::TabHandle(source_tab).Get()->GetWeakPtr();
  auto peek_alive = tabs::TabHandle(peek_id).Get()->GetWeakPtr();
  ASSERT_TRUE(peek_alive && content::WaitForLoadStop(peek_alive->GetContents()));
  ASSERT_TRUE(content::ExecJs(source_alive->GetContents(), "onbeforeunload=()=> 'keep';"));
  ASSERT_TRUE(content::ExecJs(peek_alive->GetContents(),
      "document.body.innerHTML='<input id=draft>';draft.value='live';window.liveMarker={};"));
  content::PrepContentsForBeforeUnloadTest(source_alive->GetContents());
  auto* widget = BrowserView::GetBrowserViewForBrowser(source)->browser_widget();
  const auto starts = peek_events.Count(BARC_TAB_STARTED);
  ASSERT_EQ(1, barc_tab_close(source_id, source_tab));
  auto* prompt = ui_test_utils::WaitForAppModalDialog();
  ASSERT_EQ(source_alive->GetContents(), prompt->web_contents());
  auto prompt_alive = prompt->GetWeakPtr();
  ASSERT_EQ(1, barc_tab_transfer_with_admission(peer_id, peek_id, source_id,
      [](void*, int32_t, int32_t) -> int { return 1; }, nullptr));
  if (prompt_alive) prompt_alive->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] { return !widget->HasPhysicalClosePending(); }));
  ASSERT_TRUE(source_alive && peek_alive);
  EXPECT_EQ(source, peek_alive->GetBrowserWindowInterface());
  EXPECT_FALSE(barc::IsPeekPair(source_alive.get(), peek_alive.get()));
  // Clearing the role exposes the already-enabled consumer; no rebind/new
  // observer or page reconstruction is required after promotion.
  EXPECT_TRUE(barc::CanRequestPeek(peek_alive->GetContents()->GetPrimaryMainFrame()));
  EXPECT_EQ(starts, peek_events.Count(BARC_TAB_STARTED));
  EXPECT_EQ("live", content::EvalJs(peek_alive->GetContents(), "draft.value"));
  EXPECT_EQ("object", content::EvalJs(peek_alive->GetContents(), "typeof liveMarker"));
  EXPECT_EQ(0u, peek_events.Count(BARC_TAB_CLOSED));
  ASSERT_TRUE(content::ExecJs(source_alive->GetContents(), "onbeforeunload=null;"));
}

class BarcPeekTransferConsentBrowserTest : public BarcPeekBrowserTest {
 public:
  void SetUpOnMainThread() override {
    BarcPeekBrowserTest::SetUpOnMainThread();
    host_resolver()->AddRule("a.test", "127.0.0.1");
    host_resolver()->AddRule("b.test", "127.0.0.1");
  }
};

IN_PROC_BROWSER_TEST_F(BarcPeekTransferConsentBrowserTest,
                       CommitSkippedTransferredPageNeedsFreshConsent) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t source_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* source = SharedWindow(source_id);
  ASSERT_TRUE(source);
  NSView* sidebar = Attach(source_id);
  ASSERT_TRUE(sidebar);
  ASSERT_EQ(1, barc_window_show(source_id));
  Navigate(source, embedded_test_server()->GetURL("a.test", "/title1.html"));
  const int32_t source_tab = barc_window_tab_at(source_id, 0);
  NavigationEvents source_events, peek_events;
  source_events.token = barc_tab_observe(source_id, source_tab, NavigationEvents::Receive, &source_events);
  const auto [peer_id, peek_id] = Create(source_events.token,
      Request(source, embedded_test_server()->GetURL("b.test", "/title2.html"), source_events), peek_events);
  auto source_alive = tabs::TabHandle(source_tab).Get()->GetWeakPtr();
  auto peek_alive = tabs::TabHandle(peek_id).Get()->GetWeakPtr();
  ASSERT_TRUE(peek_alive && content::WaitForLoadStop(peek_alive->GetContents()));
  ASSERT_NE(source_alive->GetContents()->GetPrimaryMainFrame()->GetProcess(),
            peek_alive->GetContents()->GetPrimaryMainFrame()->GetProcess());
  ASSERT_TRUE(content::ExecJs(peek_alive->GetContents(), "window.retainedDraft={value:42};"));
  const int32_t destination_id = barc_window_new_peer_in_native_window(source_id, source_id);
  ASSERT_GT(destination_id, 0);
  bool callback_ran = false, moved = false;
  source_events.on_closed = base::BindLambdaForTesting([&] {
    callback_ran = true;
    auto* from_owner = SharedWindow(peer_id);
    auto* to_owner = SharedWindow(destination_id);
    EXPECT_TRUE(from_owner && to_owner && peek_alive);
    if (!from_owner || !to_owner || !peek_alive) return;
    auto* from = from_owner->GetTabStripModel();
    auto* to = to_owner->GetTabStripModel();
    auto detached = from->DetachTabAtForInsertion(from->GetIndexOfTab(peek_alive.get()), false);
    EXPECT_TRUE(detached);
    if (!detached) return;
    to->InsertDetachedTabAt(0, std::move(detached), AddTabTypes::ADD_ACTIVE);
    moved = true;
    from->NotifyEmptyAfterDeferredDetach();
  });
  // A renderer-gone source closes synchronously: its real CLOSED callback runs
  // between the two consented ClosePage calls, with no synthetic event/hook.
  {
    content::ScopedAllowRendererCrashes allow(source_alive->GetContents()->GetPrimaryMainFrame()->GetProcess());
    content::CrashTab(source_alive->GetContents());
  }
  ASSERT_TRUE(peek_alive && !peek_alive->GetContents()->IsCrashed());
  EXPECT_FALSE(callback_ran);
  ASSERT_EQ(1, barc_tab_close(source_id, source_tab));
  ASSERT_TRUE(base::test::RunUntil([&] { return callback_ran && !source_alive; }));
  ASSERT_TRUE(moved);
  ASSERT_TRUE(peek_alive);
  EXPECT_EQ(SharedWindow(destination_id), peek_alive->GetBrowserWindowInterface());
  EXPECT_FALSE(barc::IsPeekCloseCommitted(peek_alive.get()));
  ASSERT_EQ(1, barc_window_select(destination_id));
  EXPECT_EQ(42, content::EvalJs(peek_alive->GetContents(), "retainedDraft.value"));
  ASSERT_TRUE(content::ExecJs(peek_alive->GetContents(), "onbeforeunload=()=> 'new owner consent';"));
  content::PrepContentsForBeforeUnloadTest(peek_alive->GetContents());
  ASSERT_EQ(1, barc_tab_close(destination_id, peek_id));
  auto* prompt = ui_test_utils::WaitForAppModalDialog();
  ASSERT_EQ(peek_alive->GetContents(), prompt->web_contents());
  prompt->view()->CancelAppModalDialog();
  ASSERT_TRUE(peek_alive);
  ASSERT_TRUE(content::ExecJs(peek_alive->GetContents(), "onbeforeunload=null;"));
}

IN_PROC_BROWSER_TEST_F(BarcPeekBrowserTest, PrivatePairYieldsToPhysicalCloseWithoutDuplicateAdmission) {
  ASSERT_TRUE(embedded_test_server()->Start());
  SharedProfileResult opened;
  barc_private_session_open_window(SharedProfileCompleted, &opened);
  ASSERT_EQ(BARC_PROFILE_OK, opened.Get<0>());
  const int32_t source_id = opened.Get<1>();
  auto* source = SharedWindow(source_id);
  ASSERT_TRUE(source);
  ASSERT_TRUE(source->GetProfile()->IsOffTheRecord());
  NSView* source_header = Attach(source_id);
  ASSERT_TRUE(source_header);
  ASSERT_EQ(1, barc_window_show(source_id));
  Navigate(source, embedded_test_server()->GetURL("/title1.html"));
  const int32_t source_tab = barc_window_tab_at(source_id, 0);
  NavigationEvents source_events, peek_events;
  source_events.token = barc_tab_observe(source_id, source_tab, NavigationEvents::Receive, &source_events);
  const auto [peer_id, peek_id] = Create(source_events.token,
      Request(source, embedded_test_server()->GetURL("/title2.html"), source_events), peek_events);
  auto source_alive = tabs::TabHandle(source_tab).Get()->GetWeakPtr();
  auto peek_alive = tabs::TabHandle(peek_id).Get()->GetWeakPtr();
  ASSERT_TRUE(peek_alive && content::WaitForLoadStop(peek_alive->GetContents()));
  ASSERT_EQ(source->GetProfile(), peek_alive->GetContents()->GetBrowserContext());
  std::array<char, 37> source_identity{}, peer_identity{};
  ASSERT_EQ(37u, barc_window_private_session_uuid(source_id, source_identity.data(), source_identity.size()));
  ASSERT_EQ(37u, barc_window_private_session_uuid(peer_id, peer_identity.data(), peer_identity.size()));
  EXPECT_EQ(source_identity, peer_identity);
  EXPECT_EQ(0u, barc_window_profile_uuid(peer_id, peer_identity.data(), peer_identity.size()));
  NSView* header = [[NSView alloc] initWithFrame:NSZeroRect];
  NSView* actions = [[NSView alloc] initWithFrame:NSZeroRect];
  const uint64_t card = barc_tab_present_peek(source_id, source_tab, peer_id, peek_id,
      (__bridge void*)source_header, (__bridge void*)header, (__bridge void*)actions);
  ASSERT_NE(0u, card);
  EXPECT_EQ(0u, barc_tab_present_peek(browser()->GetSessionID().id(),
      browser()->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value(), peer_id, peek_id,
      (__bridge void*)source_header, (__bridge void*)header, (__bridge void*)actions));
  ASSERT_EQ(1, barc_tab_hide_peek(source_id, source_tab, peer_id, peek_id, card,
      (__bridge void*)header, (__bridge void*)actions));
  for (const auto& page : {source_alive, peek_alive}) {
    ASSERT_TRUE(content::ExecJs(page->GetContents(), content::JsReplace(
        "window.beforeCount=0;onbeforeunload=()=>{"
        "domAutomationController.send($1+String(++beforeCount));return 'keep';};",
        page.get() == source_alive.get() ? "source-before:" : "peek-before:")));
    content::PrepContentsForBeforeUnloadTest(page->GetContents());
  }
  content::DOMMessageQueue source_before(source_alive->GetContents());
  content::DOMMessageQueue peek_before(peek_alive->GetContents());
  auto* widget = BrowserView::GetBrowserViewForBrowser(source)->browser_widget();
  ASSERT_EQ(1, barc_tab_close(source_id, source_tab));
  ASSERT_TRUE(widget->HasPhysicalClosePending());
  // This supersedes the exact-pair task before its posted preflight. The
  // ordinary physical coordinator now owns both, not a second tab-close loop.
  widget->Close();
  auto* first = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(source_alive && peek_alive);
  auto first_page = first->web_contents()->GetWeakPtr();
  EXPECT_TRUE(first_page.get() == source_alive->GetContents() ||
              first_page.get() == peek_alive->GetContents());
  first->view()->AcceptAppModalDialog();
  auto* second = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(source_alive && peek_alive);
  EXPECT_NE(first_page.get(), second->web_contents());
  // The open modal synchronously blocks renderer JavaScript. Observe the
  // handler's actual counter sent before each prompt, without executing JS.
  std::string source_message, peek_message;
  ASSERT_TRUE(source_before.WaitForMessage(&source_message));
  ASSERT_TRUE(peek_before.WaitForMessage(&peek_message));
  EXPECT_EQ("\"source-before:1\"", source_message);
  EXPECT_EQ("\"peek-before:1\"", peek_message);
  second->view()->AcceptAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] { return !source_alive && !peek_alive; }));
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1u, source_events.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(1u, peek_events.Count(BARC_TAB_CLOSED));
  EXPECT_FALSE(source_before.PopMessage(&source_message));
  EXPECT_FALSE(peek_before.PopMessage(&peek_message));
}

class BarcBackForwardCacheBrowserTest : public BarcDiscoveryBrowserTest {
 public:
  BarcBackForwardCacheBrowserTest() {
    cache_features_.InitWithFeatures({features::kBackForwardCache},
                                    {features::kBackForwardCacheMemoryControls});
  }
 private:
  base::test::ScopedFeatureList cache_features_;
};

IN_PROC_BROWSER_TEST_F(BarcBackForwardCacheBrowserTest,
                       BackgroundHistoryCacheFlushPreservesLiveDocumentAndProfile) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (!request.relative_url.starts_with("/barc-cache-")) return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_content_type("text/html");
        response->set_content(R"(<input id="draft"><script>
          const key=location.pathname+'-boots';
          window.cacheBoot=Number(localStorage.getItem(key)||0)+1;
          localStorage.setItem(key,String(cacheBoot));
          window.cacheClosure=(()=>{let value=7;return ()=>++value;})();
        </script>)");
        return response;
      }));
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  const int32_t tab = barc_window_tab_at(work_id, 0);
  const GURL first = embedded_test_server()->GetURL("/barc-cache-a");
  Navigate(work, first);
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  content::RenderFrameHostWrapper cached(page->GetPrimaryMainFrame());
  EXPECT_EQ(1, content::EvalJs(page, "cacheBoot"));
  Navigate(work, embedded_test_server()->GetURL("/barc-cache-b"));
  ASSERT_TRUE(cached);
  ASSERT_EQ(content::RenderFrameHost::LifecycleState::kInBackForwardCache, cached->GetLifecycleState());
  ASSERT_TRUE(content::ExecJs(page, "draft.value='keep draft';document.cookie='cacheCookie=keep;SameSite=Lax';history.replaceState({keep:1},'',location.pathname+'?keep=1#draft');"));
  EXPECT_EQ(8, content::EvalJs(page, "cacheClosure()"));
  const auto live_document = page->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  const GURL live_url = page->GetLastCommittedURL();
  auto& controller = page->GetController();
  std::vector<std::pair<int, GURL>> history;
  for (int index = 0; index < controller.GetEntryCount(); ++index) {
    auto* entry = controller.GetEntryAtIndex(index);
    history.emplace_back(entry->GetUniqueID(), entry->GetURL());
  }
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  Navigate(personal, embedded_test_server()->GetURL("/barc-cache-b"));
  auto* other = personal->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(other, "window.otherState='personal';draft.value='personal draft';"));
  ASSERT_EQ(1, barc_window_select(personal_id));
  ASSERT_EQ(content::Visibility::HIDDEN, page->GetVisibility());
  EXPECT_EQ(0, barc_tab_execute_command(personal_id, tab, BARC_PAGE_CLEAR_BACK_FORWARD_CACHE));
  EXPECT_EQ(0, barc_tab_execute_command(-1, tab, BARC_PAGE_CLEAR_BACK_FORWARD_CACHE));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, -1, BARC_PAGE_CLEAR_BACK_FORWARD_CACHE));
  ASSERT_TRUE(cached);
  EXPECT_EQ(content::RenderFrameHost::LifecycleState::kInBackForwardCache, cached->GetLifecycleState());
  ASSERT_EQ(1, barc_tab_execute_command(work_id, tab, BARC_PAGE_CLEAR_BACK_FORWARD_CACHE));
  EXPECT_TRUE(cached.WaitUntilRenderFrameDeleted());
  EXPECT_EQ(live_document.AsRenderFrameHostIfValid(), page->GetPrimaryMainFrame());
  EXPECT_EQ(live_url, page->GetLastCommittedURL());
  EXPECT_EQ(1, content::EvalJs(page, "cacheBoot"));
  EXPECT_EQ(9, content::EvalJs(page, "cacheClosure()"));
  EXPECT_EQ("keep draft", content::EvalJs(page, "draft.value"));
  EXPECT_EQ(1, content::EvalJs(page, "history.state.keep"));
  EXPECT_EQ(true, content::EvalJs(page, "document.cookie.includes('cacheCookie=keep')"));
  EXPECT_EQ(static_cast<int>(history.size()), controller.GetEntryCount());
  for (int index = 0; index < controller.GetEntryCount(); ++index) {
    EXPECT_EQ(history[index].first, controller.GetEntryAtIndex(index)->GetUniqueID());
    EXPECT_EQ(history[index].second, controller.GetEntryAtIndex(index)->GetURL());
  }
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
  EXPECT_EQ(content::Visibility::HIDDEN, page->GetVisibility());
  EXPECT_EQ("personal", content::EvalJs(other, "otherState"));
  EXPECT_EQ("personal draft", content::EvalJs(other, "draft.value"));
  content::TestNavigationObserver back(page);
  ASSERT_EQ(1, barc_tab_go_back(work_id, tab));
  back.Wait();
  EXPECT_EQ(first, page->GetLastCommittedURL());
  EXPECT_EQ(2, content::EvalJs(page, "cacheBoot"));
  EXPECT_EQ(content::Visibility::HIDDEN, page->GetVisibility());
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
}

IN_PROC_BROWSER_TEST_F(BarcBackForwardCacheBrowserTest,
                       HistoryCacheFlushRejectsStaleAndClosingOwner) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  const int32_t tab = barc_window_tab_at(work_id, 0);
  auto contents = work->GetTabStripModel()->GetActiveWebContents()->GetWeakPtr();
  const auto document = contents->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  const int32_t peer_id = barc_window_new_peer(work_id);
  ASSERT_GT(peer_id, 0);
  ui_test_utils::BrowserDestroyedObserver source_closed(work);
  ASSERT_EQ(1, barc_tab_transfer(work_id, tab, peer_id));
  source_closed.Wait();
  EXPECT_EQ(0, barc_tab_execute_command(work_id, tab, BARC_PAGE_CLEAR_BACK_FORWARD_CACHE));
  EXPECT_EQ(0, barc_tab_execute_command(personal_id, tab, BARC_PAGE_CLEAR_BACK_FORWARD_CACHE));
  auto* peer = SharedWindow(peer_id);
  ASSERT_TRUE(contents);
  ASSERT_EQ(1, barc_tab_execute_command(peer_id, tab, BARC_PAGE_CLEAR_BACK_FORWARD_CACHE));
  const int32_t active = barc_tab_create(peer_id, "about:blank", 1);
  ASSERT_GT(active, 0);
  ASSERT_NE(active, tab);
  ASSERT_EQ(1, barc_tab_execute_command(peer_id, tab, BARC_PAGE_CLEAR_BACK_FORWARD_CACHE));
  EXPECT_EQ(active, peer->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
  EXPECT_EQ(document.AsRenderFrameHostIfValid(), contents->GetPrimaryMainFrame());
  ASSERT_TRUE(content::ExecJs(contents.get(), "window.closeAttempts=0;onbeforeunload=()=>{++closeAttempts;return 'keep';};"));
  content::PrepContentsForBeforeUnloadTest(contents.get());
  ASSERT_EQ(1, barc_window_close(peer_id));
  auto* dialog = ui_test_utils::WaitForAppModalDialog();
  EXPECT_EQ(0, barc_tab_execute_command(peer_id, tab, BARC_PAGE_CLEAR_BACK_FORWARD_CACHE));
  dialog->view()->CancelAppModalDialog();
  ASSERT_TRUE(contents);
  ASSERT_TRUE(base::test::RunUntil([&] {
    auto* owner = SharedWindow(peer_id);
    return owner && !UnloadController::From(owner)->is_attempting_to_close_browser() &&
        !BrowserView::GetBrowserViewForBrowser(owner)->browser_widget()->HasPhysicalClosePending();
  }));
  EXPECT_EQ(1, barc_tab_execute_command(peer_id, tab, BARC_PAGE_CLEAR_BACK_FORWARD_CACHE));
  EXPECT_EQ(document.AsRenderFrameHostIfValid(), contents->GetPrimaryMainFrame());
  EXPECT_EQ(1, content::EvalJs(contents.get(), "closeAttempts"));
}


IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       BoostPickerSelectCancelAndReplacementAreDocumentBound) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* owner = SharedWindow(id);
  Navigate(owner, embedded_test_server()->GetURL("/title1.html"));
  auto* contents = owner->GetTabStripModel()->GetActiveWebContents();
  const int32_t tab = barc_window_tab_at(id, 0);
  ASSERT_TRUE(content::ExecJs(contents, R"(
    document.body.innerHTML='<button id="pick-me">Pick</button><input id="draft" value="unsaved">';
    window.bootstraps=1;window.clicked=0;
    document.getElementById('pick-me').addEventListener('click',()=>++clicked);
  )"));
  NavigationEvents events;
  events.token = barc_tab_observe(id, tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  auto ready = [&] {
    return content::EvalJs(contents, "document.documentElement.style.cursor==='crosshair'") == true;
  };
  auto click = [&] {
    content::SimulateMouseClickOrTapElementWithId(contents, "pick-me");
  };
  ASSERT_EQ(1, barc_tab_start_boost_picker(events.token, 1, NavigationEvents::ReceivePicker));
  ASSERT_TRUE(base::test::RunUntil(ready));
  click();
  ASSERT_TRUE(base::test::RunUntil([&] { return events.picks.size() == 1; }));
  EXPECT_EQ("#pick-me", events.picks.back().second);
  EXPECT_EQ(0, content::EvalJs(contents, "clicked"));
  EXPECT_EQ("unsaved", content::EvalJs(contents, "document.getElementById('draft').value"));
  ASSERT_EQ(1, barc_tab_start_boost_picker(events.token, 2, NavigationEvents::ReceivePicker));
  ASSERT_TRUE(base::test::RunUntil(ready));
  ASSERT_EQ(1, barc_tab_cancel_boost_picker(events.token, 2));
  ASSERT_TRUE(base::test::RunUntil([&] { return !ready(); }));
  ASSERT_EQ(1, barc_tab_start_boost_picker(events.token, 3, NavigationEvents::ReceivePicker));
  ASSERT_TRUE(base::test::RunUntil(ready));
  ASSERT_EQ(1, barc_tab_cancel_boost_picker(events.token, 2));
  EXPECT_TRUE(ready());
  click();
  ASSERT_TRUE(base::test::RunUntil([&] { return events.picks.size() == 3; }));
  EXPECT_EQ(3u, events.picks.back().first);
  EXPECT_EQ("#pick-me", events.picks.back().second);
  EXPECT_EQ(1, content::EvalJs(contents, "bootstraps"));
  auto* settings = HostContentSettingsMapFactory::GetForProfile(owner->GetProfile());
  settings->SetDefaultContentSetting(ContentSettingsType::JAVASCRIPT, CONTENT_SETTING_BLOCK);
  EXPECT_EQ(0, barc_tab_start_boost_picker(events.token, 4, NavigationEvents::ReceivePicker));
  EXPECT_EQ(3u, events.picks.size());
  settings->SetDefaultContentSetting(ContentSettingsType::JAVASCRIPT, CONTENT_SETTING_ALLOW);
  barc_tab_unobserve(events.token);
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       BoostPickerRetiresBeforeHistoryHideTransferAndUnobserve) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* owner = SharedWindow(id);
  const auto url = embedded_test_server()->GetURL("/title1.html");
  Navigate(owner, url);
  auto* contents = owner->GetTabStripModel()->GetActiveWebContents();
  const int32_t tab = barc_window_tab_at(id, 0);
  ASSERT_TRUE(content::ExecJs(contents, "document.documentElement.style.cursor='help';window.savedDraft='retained';"));
  auto document = contents->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  NavigationEvents events;
  events.token = barc_tab_observe(id, tab, NavigationEvents::Receive, &events);
  auto start = [&](uint64_t request) {
    EXPECT_EQ(1, barc_tab_start_boost_picker(events.token, request, NavigationEvents::ReceivePicker));
    EXPECT_TRUE(base::test::RunUntil([&] {
      return content::EvalJs(contents, "document.documentElement.style.cursor") == "crosshair";
    }));
  };
  start(1);
  Navigate(owner, embedded_test_server()->GetURL("/title2.html"));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.picks.size() == 1; }));
  EXPECT_TRUE(events.picks.back().second.empty());
  ASSERT_EQ(1, barc_tab_go_back(id, tab));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  // When eligible, the original live document returns without its picker.
  EXPECT_EQ(document.AsRenderFrameHostIfValid(), contents->GetPrimaryMainFrame());
  EXPECT_EQ("retained", content::EvalJs(contents, "savedDraft"));
  EXPECT_EQ("help", content::EvalJs(contents, "document.documentElement.style.cursor"));
  start(2);
  const int32_t peer_id = Open(kSharedWork, id, BARC_PROFILE_BLANK);
  ASSERT_EQ(1, barc_window_select(peer_id));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.picks.size() == 2; }));
  ASSERT_EQ(1, barc_window_select(id));
  EXPECT_EQ("help", content::EvalJs(contents, "document.documentElement.style.cursor"));
  start(3);
  ASSERT_EQ(1, barc_tab_transfer(id, tab, peer_id));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.picks.size() == 3; }));
  EXPECT_TRUE(events.picks.back().second.empty());
  ASSERT_EQ(1, barc_window_select(peer_id));
  start(4);
  barc_tab_unobserve(events.token);
  ASSERT_TRUE(base::test::RunUntil([&] { return events.picks.size() == 4; }));
  EXPECT_EQ("help", content::EvalJs(contents, "document.documentElement.style.cursor"));
  events.token = barc_tab_observe(peer_id, tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  start(5);
  ASSERT_EQ(1, barc_window_close(peer_id));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.picks.size() == 5; }));
  EXPECT_TRUE(events.picks.back().second.empty());
}


IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       BoostPickerRetiresWhenVisibleSplitPaneLosesSelection) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* owner = SharedWindow(id);
  Navigate(owner, embedded_test_server()->GetURL("/title1.html"));
  const int32_t first = barc_window_tab_at(id, 0);
  auto* contents = owner->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(contents, "document.documentElement.style.cursor='help';window.pickerDraft='live';"));
  const int32_t second = barc_tab_create(id, "about:blank", 0);
  ASSERT_GT(second, 0);
  BarcSplitLayout layout{2, 0, {first, second}, {0.5}, first};
  ASSERT_EQ(1, barc_window_set_split(id, &layout));
  NavigationEvents events;
  events.token = barc_tab_observe(id, first, NavigationEvents::Receive, &events);
  ASSERT_EQ(1, barc_tab_start_boost_picker(events.token, 1, NavigationEvents::ReceivePicker));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(contents, "document.documentElement.style.cursor") == "crosshair";
  }));
  ASSERT_EQ(1, barc_tab_select(id, second));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.picks.size() == 1; }));
  EXPECT_TRUE(events.picks.back().second.empty());
  EXPECT_EQ(content::Visibility::VISIBLE, contents->GetVisibility());
  EXPECT_EQ("help", content::EvalJs(contents, "document.documentElement.style.cursor"));
  EXPECT_EQ("live", content::EvalJs(contents, "pickerDraft"));
  EXPECT_EQ(0, barc_tab_start_boost_picker(events.token, 2, NavigationEvents::ReceivePicker));
  ASSERT_EQ(1, barc_tab_select(id, first));
  ASSERT_EQ(1, barc_tab_start_boost_picker(events.token, 3, NavigationEvents::ReceivePicker));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(contents, "document.documentElement.style.cursor") == "crosshair";
  }));
  EXPECT_EQ(1, barc_tab_cancel_boost_picker(events.token, 1));
  EXPECT_EQ("crosshair", content::EvalJs(contents, "document.documentElement.style.cursor"));
  barc_tab_unobserve(events.token);
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       ScriptEvaluationPreservesWorldAndResultSemanticsHidden) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const auto url = embedded_test_server()->GetURL("/title1.html");
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  Navigate(work, url);
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(contents, R"(
    window.onlyInPage=42; window.bootstrap=1;
    document.body.innerHTML='<input id=draft value=unsaved>';
    Object.defineProperty(Array.prototype,'0',{set(){throw Error('poisoned index')},configurable:true});
  )"));
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  Navigate(personal, url);
  ASSERT_EQ(1, barc_window_select(personal_id));
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, barc_window_tab_at(work_id, 0),
                                 NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  auto run = [&](uint64_t request, int mode, int world, const char* source) {
    EXPECT_EQ(1, barc_tab_evaluate_script(events.token, request, mode, world,
                                         source, NavigationEvents::ReceiveScript));
    EXPECT_TRUE(base::test::RunUntil([&] {
      return !events.scripts.empty() && events.scripts.back().request == request;
    }));
    return events.scripts.back();
  };
  auto reply = run(1, 0, 0, "var statement=40; statement+2");
  EXPECT_EQ(BARC_SCRIPT_VALUE, reply.result); EXPECT_EQ("42", reply.json);
  reply = run(2, 0, 1, "typeof onlyInPage");
  EXPECT_EQ("undefined", reply.text); EXPECT_TRUE(reply.is_string);
  reply = run(3, 1, 0, "await Promise.resolve(); return onlyInPage");
  EXPECT_EQ("42", reply.json);
  reply = run(4, 0, 1, "typeof statement");
  EXPECT_EQ("undefined", reply.text);
  EXPECT_EQ(BARC_SCRIPT_UNDEFINED, run(5, 0, 0, "void 0").result);
  reply = run(6, 0, 0, "null"); EXPECT_EQ(BARC_SCRIPT_VALUE, reply.result);
  EXPECT_EQ("null", reply.json);
  EXPECT_EQ(BARC_SCRIPT_EXCEPTION, run(7, 0, 0, "throw Error('thrown')").result);
  EXPECT_EQ(BARC_SCRIPT_REJECTED,
            run(8, 1, 0, "throw Error('rejected')").result);
  reply = run(9, 0, 0, "'a\\u0000b'");
  EXPECT_EQ(std::string("a\0b", 3), reply.text);
  EXPECT_EQ(BARC_SCRIPT_UNSERIALIZABLE,
            run(10, 0, 0, "'x'.repeat(1024*1024+1)").result);
  EXPECT_EQ(1, content::EvalJs(contents, "bootstrap"));
  EXPECT_EQ("unsaved", content::EvalJs(contents, "draft.value"));
  reply = run(11, 1, 1,
      "const input=document.getElementById('draft');"
      "input.addEventListener('input',()=>{input.dataset.events='1'});"
      "input.value='edited';input.dispatchEvent(new Event('input'));"
      "return input.value+':'+input.dataset.events");
  EXPECT_EQ(BARC_SCRIPT_VALUE, reply.result);
  EXPECT_EQ("edited:1", reply.text);
  EXPECT_EQ("edited", content::EvalJs(contents, "draft.value"));
  EXPECT_TRUE(BrowserView::GetBrowserViewForBrowser(personal)->IsSelectedForNativeWindow());
  EXPECT_NE(content::Visibility::VISIBLE, contents->GetVisibility());
  EXPECT_TRUE(content::ExecJs(contents, "delete Array.prototype[0]"));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       ScriptCancellationReleasesRequestsAndSuspendedGate) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, barc_window_tab_at(work_id, 0),
                                 NavigationEvents::Receive, &events);
  for (uint64_t request = 1; request <= 32; ++request) {
    const std::u16string title = base::UTF8ToUTF16("script" + base::NumberToString(request));
    content::TitleWatcher started(contents, title);
    const std::string source = "document.title='script" + base::NumberToString(request) +
        "'; await new Promise(()=>{})";
    ASSERT_EQ(1, barc_tab_evaluate_script(events.token, request, 1, 0,
        source.c_str(), NavigationEvents::ReceiveScript));
    EXPECT_EQ(title, started.WaitAndGetTitle());
    ASSERT_EQ(1, barc_tab_cancel_script(events.token, request));
    EXPECT_EQ(BARC_SCRIPT_CANCELLED, events.scripts.back().result);
  }
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  ASSERT_EQ(1, barc_window_select(personal_id));
  ASSERT_NE(content::Visibility::VISIBLE, contents->GetVisibility());
  content::DOMMessageQueue lifecycle(contents);
  ASSERT_TRUE(content::ExecJs(contents, R"(
    document.addEventListener('freeze',()=>domAutomationController.send('nook-script-frozen'));
    document.addEventListener('resume',()=>domAutomationController.send('nook-script-resumed'));
  )"));
  contents->SetPageFrozen(true);
  auto wait_lifecycle = [&](const char* expected) {
    std::string message;
    while (lifecycle.WaitForMessage(&message)) {
      if (message == expected) return true;
    }
    return false;
  };
  ASSERT_TRUE(wait_lifecycle("\"nook-script-frozen\""));
  ASSERT_EQ(1, barc_tab_evaluate_script(events.token, 33, 0, 0,
      "window.shouldNotRun=1", NavigationEvents::ReceiveScript));
  EXPECT_EQ(true, content::EvalJs(contents, "true"));
  ASSERT_EQ(1, barc_tab_cancel_script(events.token, 33));
  ASSERT_EQ(1, barc_tab_evaluate_script(events.token, 34, 0, 0,
      "42", NavigationEvents::ReceiveScript));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.scripts.back().request == 34; }));
  EXPECT_EQ(BARC_SCRIPT_BUSY, events.scripts.back().result);
  contents->SetPageFrozen(false);
  ASSERT_TRUE(wait_lifecycle("\"nook-script-resumed\""));
  EXPECT_EQ("undefined", content::EvalJs(contents, "typeof shouldNotRun"));
  ASSERT_EQ(1, barc_tab_evaluate_script(events.token, 35, 0, 0,
      "42", NavigationEvents::ReceiveScript));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.scripts.back().request == 35; }));
  EXPECT_EQ("42", events.scripts.back().json);
  events.unsubscribe_script = true;
  ASSERT_EQ(1, barc_tab_evaluate_script(events.token, 36, 0, 0,
      "42", NavigationEvents::ReceiveScript));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.scripts.back().request == 36; }));
  EXPECT_EQ(0, barc_tab_evaluate_script(events.token, 37, 0, 0,
      "42", NavigationEvents::ReceiveScript));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       ScriptHooksCannotPublishIntoReplacementDocument) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const auto first = embedded_test_server()->GetURL("/title1.html");
  const auto second = embedded_test_server()->GetURL("/title2.html");
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  Navigate(work, first);
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, barc_window_tab_at(work_id, 0),
                                 NavigationEvents::Receive, &events);
  uint64_t request = 0;
  for (const std::string& source : {
      "({get then(){location.href=" + content::JsReplace("$1", second) + ";return undefined}})",
      "(()=>{let o={toString(){location.href=" + content::JsReplace("$1", second) + ";return 'old'}};o.self=o;return o})()",
      "({toJSON(){location.href=" + content::JsReplace("$1", second) + ";return 'old'}})"}) {
    Navigate(work, first);
    content::TestNavigationObserver navigated(contents);
    ++request;
    ASSERT_EQ(1, barc_tab_evaluate_script(events.token, request, 0, 0,
        source.c_str(), NavigationEvents::ReceiveScript));
    navigated.Wait();
    ASSERT_TRUE(base::test::RunUntil([&] { return events.scripts.back().request == request; }));
    EXPECT_EQ(BARC_SCRIPT_CANCELLED, events.scripts.back().result);
    EXPECT_EQ(second, contents->GetLastCommittedURL());
  }
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       ScriptAdmissionKeepsPrivateProfileAndPolicyAuthority) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const auto url = embedded_test_server()->GetURL("/title1.html");
  const int32_t regular_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* regular = SharedWindow(regular_id);
  Navigate(regular, url);
  auto* regular_contents = regular->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(regular_contents, "window.identity='regular'"));
  SharedProfileResult opened;
  barc_private_session_open_window(SharedProfileCompleted, &opened);
  ASSERT_EQ(BARC_PROFILE_OK, opened.Get<0>());
  const int32_t private_id = opened.Get<1>();
  auto* private_browser = SharedWindow(private_id);
  Navigate(private_browser, url);
  auto* contents = private_browser->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(contents, "window.identity='private'"));
  const int32_t tab = barc_window_tab_at(private_id, 0);
  EXPECT_EQ(0u, barc_tab_observe(regular_id, tab, NavigationEvents::Receive, nullptr));
  NavigationEvents events;
  events.token = barc_tab_observe(private_id, tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  ASSERT_EQ(1, barc_tab_evaluate_script(events.token, 1, 0, 0,
      "identity", NavigationEvents::ReceiveScript));
  ASSERT_TRUE(base::test::RunUntil([&] { return !events.scripts.empty(); }));
  EXPECT_EQ("private", events.scripts.back().text);
  EXPECT_EQ("regular", content::EvalJs(regular_contents, "identity"));
  auto* settings = HostContentSettingsMapFactory::GetForProfile(private_browser->GetProfile());
  settings->SetContentSettingDefaultScope(url, url, ContentSettingsType::JAVASCRIPT,
                                          CONTENT_SETTING_BLOCK);
  EXPECT_EQ(0, barc_tab_evaluate_script(events.token, 2, 0, 1,
      "window.forbidden=1", NavigationEvents::ReceiveScript));
  settings->SetContentSettingDefaultScope(url, url, ContentSettingsType::JAVASCRIPT,
                                          CONTENT_SETTING_ALLOW);
  ASSERT_EQ(1, barc_tab_evaluate_script(events.token, 3, 1, 0,
      "await new Promise(()=>{})", NavigationEvents::ReceiveScript));
  // A real transfer cancels this exact operation rather than retargeting it.
  const int32_t peer_id = barc_window_new_peer(private_id);
  ASSERT_GT(peer_id, 0);
  ASSERT_EQ(1, barc_tab_transfer(private_id, tab, peer_id));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.scripts.back().request == 3; }));
  EXPECT_EQ(BARC_SCRIPT_CANCELLED, events.scripts.back().result);
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       QueuedScriptRechecksPolicyBeforeIsolatedExecution) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, barc_window_tab_at(work_id, 0),
                                 NavigationEvents::Receive, &events);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  ASSERT_EQ(1, barc_window_select(personal_id));
  ASSERT_NE(content::Visibility::VISIBLE, contents->GetVisibility());
  content::DOMMessageQueue lifecycle(contents);
  ASSERT_TRUE(content::ExecJs(contents, R"(
    document.addEventListener('freeze',()=>domAutomationController.send('nook-script-frozen'));
  )"));
  contents->SetPageFrozen(true);
  auto wait_lifecycle = [&](const char* expected) {
    std::string message;
    while (lifecycle.WaitForMessage(&message)) {
      if (message == expected) return true;
    }
    return false;
  };
  ASSERT_TRUE(wait_lifecycle("\"nook-script-frozen\""));
  ASSERT_EQ(1, barc_tab_evaluate_script(events.token, 1, 0, 1,
      "window.policyBypass=1", NavigationEvents::ReceiveScript));
  auto preferences = contents->GetOrCreateWebPreferences();
  preferences.javascript_enabled = false;
  contents->SetWebPreferences(preferences);
  // Test-only execution supplies an unfreezable renderer message barrier; the
  // production thunk remains deferred and must recheck its actual settings.
  EXPECT_EQ(true, content::EvalJs(contents, "true"));
  EXPECT_TRUE(events.scripts.empty());
  contents->SetPageFrozen(false);
  ASSERT_TRUE(base::test::RunUntil([&] { return !events.scripts.empty(); }));
  EXPECT_EQ(BARC_SCRIPT_UNAVAILABLE, events.scripts.back().result);
  preferences.javascript_enabled = true;
  contents->SetWebPreferences(preferences);
  Navigate(work, embedded_test_server()->GetURL("/set-header?Content-Security-Policy: sandbox"));
  EXPECT_EQ(0, barc_tab_evaluate_script(events.token, 2, 0, 1,
      "window.sandboxBypass=1", NavigationEvents::ReceiveScript));
  Navigate(work, GURL("about:blank"));
  EXPECT_EQ(0, barc_tab_evaluate_script(events.token, 3, 0, 1,
      "42", NavigationEvents::ReceiveScript));
}

namespace {
std::vector<uint8_t> NativeBlockerTestRules() {
  const std::string lists = R"([{"rules":"/native-ad\n/native-ad$document\n/post-only$method=POST","trusted":false}])";
  std::unique_ptr<void, decltype(&nook_adblock_engine_free)> engine(
      nook_adblock_engine_from_lists(lists.data(), lists.size()),
      &nook_adblock_engine_free);
  CHECK(engine);
  size_t size = 0;
  uint8_t* data = nook_adblock_engine_serialize(engine.get(), &size);
  CHECK(data);
  std::vector<uint8_t> result;
  result.assign(UNSAFE_BUFFERS(base::span(data, size)).begin(),
                UNSAFE_BUFFERS(base::span(data, size)).end());
  nook_adblock_buffer_free(data, size);
  return result;
}
struct NativeBlockerReply {
  base::test::TestFuture<uint64_t, int32_t> value;
  static void Receive(void* context, uint64_t revision, int32_t result) {
    static_cast<NativeBlockerReply*>(context)->value.SetValue(revision, result);
  }
};
uint64_t NextBlockerSource() {
  static uint64_t generation = 0;
  return ++generation;
}
void PrepareNativeBlocker(int32_t window) {
  NativeBlockerReply ready;
  ASSERT_EQ(1, barc_blocker_prepare(window, NativeBlockerReply::Receive, &ready));
  EXPECT_EQ(BARC_BLOCKER_READY, ready.value.Get<1>());
}
void InstallNativeBlocker(int32_t window, const std::vector<uint8_t>& rules) {
  const uint64_t generation = NextBlockerSource();
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED, generation, nullptr, 0));
  NativeBlockerReply reply;
  struct BorrowedInput {
    std::vector<uint8_t> bytes;
    raw_ptr<NativeBlockerReply> reply;
    static void Complete(void* context, uint64_t revision, int32_t result) {
      auto* input = static_cast<BorrowedInput*>(context);
      auto* reply = input->reply.get();
      delete input;
      reply->value.SetValue(revision, result);
    }
  };
  auto* input = new BorrowedInput{rules, &reply};
  const int accepted = barc_blocker_publish_rules(
      input->bytes.data(), input->bytes.size(), generation,
      BorrowedInput::Complete, input);
  if (!accepted) delete input;
  ASSERT_EQ(1, accepted);
  EXPECT_EQ(BARC_BLOCKER_READY, reply.value.Get<1>());
  PrepareNativeBlocker(window);
}
class BarcNativeBlockerBrowserTest : public BarcDiscoveryBrowserTest {
 public:
  void SetUpInProcessBrowserTestFixture() override {
    BarcDiscoveryBrowserTest::SetUpInProcessBrowserTestFixture();
    CHECK(NativeContentBlocker::SetPolicy(NativeContentBlocker::kUnresolved, 0, {}));
  }
  void SetUpOnMainThread() override {
    BarcDiscoveryBrowserTest::SetUpOnMainThread();
    host_resolver()->AddRule("*", "127.0.0.1");
    CHECK(barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  }
};
ConfirmInfoBarDelegate* NativeBlockNotice(content::WebContents* contents) {
  auto* manager = infobars::ContentInfoBarManager::FromWebContents(contents);
  if (!manager) return nullptr;
  for (const auto& bar : manager->infobars()) {
    if (bar->delegate()->GetIdentifier() ==
        infobars::InfoBarDelegate::BARC_NATIVE_CONTENT_BLOCK_INFOBAR_DELEGATE)
      return bar->delegate()->AsConfirmInfoBarDelegate();
  }
  return nullptr;
}
void NavigateNativeDenied(BrowserWindowInterface* window, const GURL& url) {
  auto* contents = window->GetTabStripModel()->GetActiveWebContents();
  content::TestNavigationObserver navigation(contents);
  ASSERT_EQ(1, barc_tab_navigate(window->GetSessionID().id(),
      barc_window_tab_at(window->GetSessionID().id(), 0), url.spec().c_str()));
  navigation.Wait();
  content::WaitForLoadStopWithoutSuccessCheck(contents);
  EXPECT_EQ(net::ERR_BLOCKED_BY_CLIENT, navigation.last_net_error_code());
}
}  // namespace

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest,
                       NativeBlockedNavigationNoticeKeepsExactTabAuthority) {
  auto sent = std::make_shared<std::atomic<int>>(0);
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      [](std::shared_ptr<std::atomic<int>> sent,
         const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/native-ad") return nullptr;
        ++*sent;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK);
        response->set_content("approved native target");
        return response;
      }, sent));
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  InstallNativeBlocker(work_id, NativeBlockerTestRules());
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  const int32_t tab = barc_window_tab_at(work_id, 0);
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  const GURL target = embedded_test_server()->GetURL("/native-ad");
  NavigateNativeDenied(work, target);
  ASSERT_TRUE(base::test::RunUntil([&] { return NativeBlockNotice(page); }));
  EXPECT_EQ(1u, events.Count(BARC_TAB_NATIVE_BLOCKED));
  EXPECT_EQ(0, sent->load());
  EXPECT_EQ(u"Continue", NativeBlockNotice(page)->GetButtonLabel(ConfirmInfoBarDelegate::BUTTON_OK));
  ASSERT_EQ(1, barc_window_select(personal_id));
  NativeBlockNotice(page)->Accept();
  EXPECT_EQ(0u, events.Count(BARC_TAB_CONTINUE_NATIVE_BLOCK));
  ASSERT_EQ(1, barc_window_select(work_id));
  NativeBlockNotice(page)->Accept();
  EXPECT_EQ(1u, events.Count(BARC_TAB_CONTINUE_NATIVE_BLOCK));
  EXPECT_EQ(target.spec(), events.events.back().url);
  EXPECT_EQ(0, sent->load()); // Native UI did not invent a second exception authority.
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, tab, 0, std::string(target.host()).c_str(), 0));
  Navigate(work, target);
  EXPECT_EQ(1, sent->load());
  EXPECT_FALSE(NativeBlockNotice(page));
  EXPECT_EQ(1u, events.Count(BARC_TAB_NATIVE_BLOCKED));
  NavigateNativeDenied(personal, target);
  EXPECT_EQ(1, sent->load()); // No exception in the other profile.
  Navigate(work, embedded_test_server()->GetURL("localhost", "/title1.html"));
  NavigateNativeDenied(work, target);
  EXPECT_EQ(1, sent->load()); // Leaving the continued host retired its exception.
  EXPECT_EQ(2u, events.Count(BARC_TAB_NATIVE_BLOCKED));
}

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest,
                       RedirectBlockNoticeHandlesUnobserveAndClose) {
  auto sent = std::make_shared<std::atomic<int>>(0);
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      [](std::shared_ptr<std::atomic<int>> sent,
         const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/redirect-native" &&
            request.relative_url != "/native-ad") return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        if (request.relative_url == "/redirect-native") {
          response->set_code(net::HTTP_FOUND);
          response->AddCustomHeader("Location", "/native-ad");
        } else {
          ++*sent;
          response->set_code(net::HTTP_OK);
        }
        return response;
      }, sent));
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t window = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(window);
  InstallNativeBlocker(window, NativeBlockerTestRules());
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  const int32_t tab = barc_window_tab_at(window, 0);
  const GURL redirect = embedded_test_server()->GetURL("/redirect-native");
  const GURL target = embedded_test_server()->GetURL("/native-ad");
  NavigationEvents events;
  events.token = barc_tab_observe(window, tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  NavigateNativeDenied(work, redirect);
  ASSERT_TRUE(base::test::RunUntil([&] { return NativeBlockNotice(page); }));
  const auto blocked = std::find_if(events.events.begin(), events.events.end(),
      [](const auto& event) { return event.kind == BARC_TAB_NATIVE_BLOCKED; });
  ASSERT_NE(events.events.end(), blocked);
  EXPECT_EQ(target.spec(), blocked->url);
  EXPECT_EQ(0, sent->load());

  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  ASSERT_FALSE(NativeBlockNotice(page));
  events.on_failed = base::BindLambdaForTesting([&] { barc_tab_unobserve(events.token); });
  NavigateNativeDenied(work, redirect);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(2u, events.Count(BARC_TAB_FAILED));
  EXPECT_EQ(1u, events.Count(BARC_TAB_NATIVE_BLOCKED));
  EXPECT_FALSE(NativeBlockNotice(page));

  events.token = barc_tab_observe(window, tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  NavigateNativeDenied(work, redirect);
  ASSERT_TRUE(base::test::RunUntil([&] { return NativeBlockNotice(page); }));
  auto page_alive = page->GetWeakPtr();
  events.on_native_continue = base::BindLambdaForTesting([&] {
    barc_tab_unobserve(events.token);
    EXPECT_EQ(1, barc_tab_close(window, tab));
  });
  ASSERT_EQ(1, barc_window_select(window));
  NativeBlockNotice(page)->Accept();
  ASSERT_TRUE(base::test::RunUntil([&] { return !page_alive; }));
  EXPECT_EQ(1u, events.Count(BARC_TAB_CONTINUE_NATIVE_BLOCK));
  EXPECT_EQ(0, sent->load());
}

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest,
                       ExtensionNavigationDenialNeverBecomesNativeContinue) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  InstallNativeBlocker(work_id, NativeBlockerTestRules());
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  const int32_t tab = barc_window_tab_at(work_id, 0);
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, tab, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  extensions::TestExtensionDir dir;
  dir.WriteManifest(R"({"manifest_version":3,"name":"Native denial ownership",
    "version":"1.0","permissions":["declarativeNetRequest"],
    "host_permissions":["<all_urls>"],"background":{"service_worker":"worker.js"}})");
  dir.WriteFile(FILE_PATH_LITERAL("worker.js"), R"(
    chrome.declarativeNetRequest.updateDynamicRules({addRules:[
      {id:1,priority:1,action:{type:'block'},condition:{urlFilter:'/native-ad',resourceTypes:['main_frame']}}
    ]}).then(()=>chrome.test.sendMessage('native-denial-extension-ready'));
  )");
  ExtensionTestMessageListener ready("native-denial-extension-ready");
  ready.set_browser_context(work->GetProfile());
  extensions::ChromeTestExtensionLoader loader(work->GetProfile());
  const auto extension = loader.LoadExtension(dir.UnpackedPath());
  ASSERT_TRUE(extension);
  ready.set_extension_id(extension->id());
  ASSERT_TRUE(ready.WaitUntilSatisfied());
  const GURL target = embedded_test_server()->GetURL("/native-ad");
  NavigateNativeDenied(work, target);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1u, events.Count(BARC_TAB_FAILED));
  EXPECT_EQ(0u, events.Count(BARC_TAB_NATIVE_BLOCKED));
  EXPECT_FALSE(NativeBlockNotice(page));
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, tab, 0, std::string(target.host()).c_str(), 0));
  NavigateNativeDenied(work, target);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(2u, events.Count(BARC_TAB_FAILED));
  EXPECT_EQ(0u, events.Count(BARC_TAB_NATIVE_BLOCKED));
  EXPECT_FALSE(NativeBlockNotice(page));
}

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest,
                       NativeBlockerExactContextsMethodsAndTabExceptions) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (!request.relative_url.starts_with("/native-") &&
            !request.relative_url.starts_with("/post-only")) return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK);
        response->set_content_type("text/javascript");
        if (request.relative_url == "/native-dedicated.js")
          response->set_content("onmessage=()=>fetch('/native-ad').then(()=>postMessage('allowed'),()=>postMessage('blocked')); ");
        else if (request.relative_url == "/native-shared.js")
          response->set_content("onconnect=e=>{const p=e.ports[0];p.onmessage=()=>fetch('/native-ad').then(()=>p.postMessage('allowed'),()=>p.postMessage('blocked'));};");
        else if (request.relative_url == "/native-sw.js")
          response->set_content("self.addEventListener('install',()=>self.skipWaiting());self.addEventListener('activate',e=>e.waitUntil(clients.claim()));self.onmessage=e=>e.waitUntil(fetch('/native-ad').then(()=>e.source.postMessage('allowed'),()=>e.source.postMessage('blocked')));");
        else response->set_content("synthetic fixture");
        return response;
      }));
  ASSERT_TRUE(embedded_test_server()->Start());
  const auto rules = NativeBlockerTestRules();
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  BarcBlockerState state = {};
  PrepareNativeBlocker(work_id);
  ASSERT_EQ(1, barc_blocker_state(work_id, &state));
  EXPECT_TRUE(state.ready);
  EXPECT_EQ(BARC_BLOCKER_DISABLED, state.requested_policy);
  InstallNativeBlocker(work_id, rules);
  ASSERT_EQ(1, barc_blocker_state(work_id, &state));
  const uint64_t context_id = state.context_id;
  const uint64_t installed_revision = state.installed_revision;
  const int32_t peer_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  ASSERT_EQ(work->GetProfile(), SharedWindow(peer_id)->GetProfile());
  BarcBlockerState peer_state = {};
  ASSERT_EQ(1, barc_blocker_state(peer_id, &peer_state));
  EXPECT_EQ(context_id, peer_state.context_id);
  EXPECT_EQ(installed_revision, peer_state.installed_revision);
  EXPECT_TRUE(state.ready);
  EXPECT_EQ(BARC_BLOCKER_ENABLED, state.requested_policy);
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  Navigate(personal, embedded_test_server()->GetURL("/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  auto* other = personal->GetTabStripModel()->GetActiveWebContents();
  auto fetch = [&](content::WebContents* contents, const char* path,
                   const char* method = "GET") {
    return content::EvalJs(contents, content::JsReplace(
        "fetch($1,{method:$2}).then(()=>true,()=>false)",
        embedded_test_server()->GetURL(path), method));
  };
  EXPECT_EQ(false, fetch(page, "/native-ad"));
  EXPECT_EQ(false, fetch(other, "/native-ad"));
  EXPECT_EQ(true, fetch(page, "/post-only", "GET"));
  EXPECT_EQ(false, fetch(page, "/post-only", "POST"));
  EXPECT_EQ(false, content::EvalJs(page, content::JsReplace(
      "fetch($1).then(()=>true,()=>false)",
      embedded_test_server()->GetURL("/server-redirect?" +
          embedded_test_server()->GetURL("/native-ad").spec()))));
  const int32_t tab = barc_window_tab_at(work_id, 0);
  EXPECT_EQ(0, barc_blocker_set_tab_policy(personal_id, tab, 1, nullptr, 0));
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, tab, 0, nullptr, 60000));
  EXPECT_EQ(true, fetch(page, "/native-ad"));
  EXPECT_EQ("allowed", content::EvalJs(page, R"(
    new Promise(resolve=>{const w=new Worker('/native-dedicated.js');
      w.onmessage=e=>{w.terminate();resolve(e.data)};w.onerror=()=>resolve('error');w.postMessage(1)});
  )"));
  // Shared/SW have no unique tab owner: a selected tab exception cannot leak.
  EXPECT_EQ("blocked", content::EvalJs(page, R"(
    new Promise(resolve=>{const w=new SharedWorker('/native-shared.js');
      w.port.onmessage=e=>{w.port.close();resolve(e.data)};w.onerror=()=>resolve('error');w.port.postMessage(1)});
  )"));
  EXPECT_EQ("blocked", content::EvalJs(page, R"(
    (async()=>{await navigator.serviceWorker.register('/native-sw.js');
      const r=await navigator.serviceWorker.ready;
      const result=await new Promise(resolve=>{navigator.serviceWorker.addEventListener('message',e=>resolve(e.data),{once:true});r.active.postMessage(1)});
      await r.unregister();return result;})();
  )"));
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, tab, 0, "target.test", 0));
  Navigate(work, embedded_test_server()->GetURL("target.test", "/title1.html"));
  EXPECT_EQ(true, content::EvalJs(page, "fetch('/native-ad').then(()=>true,()=>false)"));
  Navigate(work, embedded_test_server()->GetURL("target.test", "/server-redirect?" +
      embedded_test_server()->GetURL("other.test", "/title1.html").spec()));
  EXPECT_EQ(false, content::EvalJs(page, "fetch('/native-ad').then(()=>true,()=>false)"));
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, tab, 0, "target.test", 0));
  Navigate(work, embedded_test_server()->GetURL("other.test", "/title1.html"));
  EXPECT_EQ(false, content::EvalJs(page, "fetch('/native-ad').then(()=>true,()=>false)"));
  SharedProfileResult private_result;
  barc_private_session_open_window(SharedProfileCompleted, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  const int32_t private_id = private_result.Get<1>();
  auto* private_browser = SharedWindow(private_id);
  Navigate(private_browser, embedded_test_server()->GetURL("/title1.html"));
  auto* private_page = private_browser->GetTabStripModel()->GetActiveWebContents();
  EXPECT_EQ(false, fetch(private_page, "/native-ad"));
  PrepareNativeBlocker(private_id);
  EXPECT_EQ(false, fetch(private_page, "/native-ad"));
  ASSERT_EQ(1, barc_blocker_state(private_id, &state));
  EXPECT_NE(context_id, state.context_id);
  EXPECT_EQ(false, fetch(other, "/native-ad"));
  content::TestNavigationObserver denied(page);
  ASSERT_EQ(1, barc_tab_navigate(work_id, tab,
      embedded_test_server()->GetURL("/native-ad").spec().c_str()));
  denied.Wait();
  EXPECT_FALSE(denied.last_navigation_succeeded());
  EXPECT_EQ(net::ERR_BLOCKED_BY_CLIENT, denied.last_net_error_code());
  BarcBlockerState invalid = state;
  EXPECT_EQ(0, barc_blocker_state(-1, &invalid));
  EXPECT_EQ(0u, invalid.context_id);
  EXPECT_EQ(0u, invalid.installed_revision);
}

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest,
                       NativeBlockerRequiredSourceDisableFailureAndSupersession) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  auto* service = NativeContentBlocker::Get(work->GetProfile(), true);
  auto client = NativeContentBlocker::CaptureClient(
      page, page->GetPrimaryMainFrame(), page->GetLastCommittedURL());
  const GURL target = embedded_test_server()->GetURL("/native-ad");
  const auto rules = NativeBlockerTestRules();
  InstallNativeBlocker(work_id, rules);
  const auto accepted = service->state();
  auto* tab = work->GetTabStripModel()->GetActiveTab();
  for (int change = 0; change < 4; ++change) {
    SCOPED_TRACE(change);
    base::test::TestFuture<int> queued;
    service->Check(target, page->GetLastCommittedURL(), client, "script", "GET",
                   queued.GetCallback());
    // The worker may finish, but its UI continuation cannot run before this
    // synchronous policy mutation. It must not publish a stale block result.
    if (change == 0) ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
    if (change == 1) {
      const char* domains[] = {"127.0.0.1"};
      ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED,
          accepted.required_source_generation, domains, 1));
    }
    if (change == 2) ASSERT_TRUE(service->SetTabPolicy(*tab, true, "", base::TimeDelta()));
    if (change == 3) ASSERT_TRUE(service->SetTabPolicy(*tab, false, "", base::Seconds(60)));
    EXPECT_EQ(net::OK, queued.Get());
    ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED,
        accepted.required_source_generation, nullptr, 0));
    ASSERT_TRUE(service->SetTabPolicy(*tab, false, "", base::TimeDelta()));
    base::test::TestFuture<int> protected_again;
    service->Check(target, page->GetLastCommittedURL(), client, "script", "GET",
                   protected_again.GetCallback());
    EXPECT_EQ(net::ERR_BLOCKED_BY_CLIENT, protected_again.Get());
  }
  const uint64_t desired = NextBlockerSource();
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED, desired, nullptr, 0));
  EXPECT_EQ(0, barc_blocker_set_policy(BARC_BLOCKER_ENABLED,
      accepted.source_generation, nullptr, 0));
  NativeBlockerReply prepare;
  ASSERT_EQ(1, barc_blocker_prepare(work_id, NativeBlockerReply::Receive, &prepare));
  base::test::TestFuture<int> request;
  service->Check(target, page->GetLastCommittedURL(), client, "script", "GET",
                 request.GetCallback());
  base::RunLoop().RunUntilIdle();
  EXPECT_FALSE(prepare.value.IsReady());
  EXPECT_FALSE(request.IsReady());
  EXPECT_FALSE(service->state().ready); // Old accepted rules cannot qualify.
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  EXPECT_EQ(BARC_BLOCKER_READY, prepare.value.Get<1>());
  EXPECT_EQ(net::OK, request.Get()); // No producer/parse completion required.

  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED, desired, nullptr, 0));
  NativeBlockerReply failed, failed_prepare;
  ASSERT_EQ(1, barc_blocker_prepare(work_id, NativeBlockerReply::Receive, &failed_prepare));
  ASSERT_EQ(1, barc_blocker_publish_rules(nullptr, 0, desired,
      NativeBlockerReply::Receive, &failed));
  EXPECT_EQ(BARC_BLOCKER_INVALID_RULES, failed.value.Get<1>());
  EXPECT_EQ(BARC_BLOCKER_INVALID_RULES, failed_prepare.value.Get<1>());
  EXPECT_EQ(accepted.installed_revision, service->state().installed_revision);
  base::test::TestFuture<int> failed_request;
  service->Check(target, page->GetLastCommittedURL(), client, "script", "GET",
                 failed_request.GetCallback());
  EXPECT_EQ(net::ERR_FAILED, failed_request.Get()); // Not a fabricated filter hit.

  const uint64_t newer = NextBlockerSource();
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED, newer, nullptr, 0));
  NativeBlockerReply stale, published;
  ASSERT_EQ(1, barc_blocker_publish_rules(rules.data(), rules.size(), desired,
      NativeBlockerReply::Receive, &stale));
  ASSERT_EQ(1, barc_blocker_publish_rules(rules.data(), rules.size(), newer,
      NativeBlockerReply::Receive, &published));
  EXPECT_EQ(BARC_BLOCKER_SUPERSEDED, stale.value.Get<1>());
  EXPECT_EQ(BARC_BLOCKER_READY, published.value.Get<1>());
  PrepareNativeBlocker(work_id);
  EXPECT_EQ(newer, service->state().source_generation);
  base::test::TestFuture<int> blocked;
  service->Check(target, page->GetLastCommittedURL(), client, "script", "GET",
                 blocked.GetCallback());
  EXPECT_EQ(net::ERR_BLOCKED_BY_CLIENT, blocked.Get());

  SharedProfileResult private_result;
  barc_private_session_open_window(SharedProfileCompleted, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  const int32_t private_id = private_result.Get<1>();
  auto* private_browser = SharedWindow(private_id);
  auto* owner = NativeContentBlocker::Get(private_browser->GetProfile(), true);
  const auto private_context = owner->state().context_id;
  const uint64_t unproduced = NextBlockerSource();
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED, unproduced, nullptr, 0));
  NativeBlockerReply ended;
  ASSERT_EQ(1, barc_blocker_prepare(private_id, NativeBlockerReply::Receive, &ended));
  auto alive = private_browser->GetProfile()->GetWeakPtr();
  ASSERT_EQ(1, barc_window_close(private_id));
  EXPECT_EQ(BARC_BLOCKER_OWNER_ENDED, ended.value.Get<1>());
  ASSERT_TRUE(base::test::RunUntil([&] { return !alive; }));
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  SharedProfileResult fresh;
  barc_private_session_open_window(SharedProfileCompleted, &fresh);
  ASSERT_EQ(BARC_PROFILE_OK, fresh.Get<0>());
  PrepareNativeBlocker(fresh.Get<1>());
  BarcBlockerState state{};
  ASSERT_EQ(1, barc_blocker_state(fresh.Get<1>(), &state));
  EXPECT_NE(private_context, state.context_id);
}

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest,
                       NativeBlockerCoexistsWithExtensionDecisionsAndLazyBody) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (!request.relative_url.starts_with("/native-") &&
            !request.relative_url.starts_with("/extension-block")) return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK);
        response->set_content_type("text/plain");
        response->set_content("synthetic fixture");
        return response;
      }));
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  const auto rules = NativeBlockerTestRules();
  InstallNativeBlocker(work_id, rules);
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  // The existing factory has native policy before any requestBody listener.
  EXPECT_EQ(true, content::EvalJs(page,
      "fetch('/native-body',{method:'POST',body:'initial'}).then(()=>true,()=>false)"));
  extensions::TestExtensionDir dir;
  dir.WriteManifest(R"({"manifest_version":3,"name":"Native policy coexistence",
    "version":"1.0","permissions":["webRequest","declarativeNetRequest"],
    "host_permissions":["<all_urls>"],
    "background":{"service_worker":"worker.js"}})");
  dir.WriteFile(FILE_PATH_LITERAL("worker.js"),
                "chrome.test.sendMessage('native-blocker-extension-ready');");
  ExtensionTestMessageListener ready("native-blocker-extension-ready");
  ready.set_browser_context(work->GetProfile());
  extensions::ChromeTestExtensionLoader loader(work->GetProfile());
  const auto extension = loader.LoadExtension(dir.UnpackedPath());
  ASSERT_TRUE(extension);
  ready.set_extension_id(extension->id());
  ASSERT_TRUE(ready.WaitUntilSatisfied());
  auto worker = [&](const std::string& script) {
    return extensions::BackgroundScriptExecutor::ExecuteScript(
        work->GetProfile(), extension->id(), script,
        extensions::BackgroundScriptExecutor::ResultCapture::kSendScriptResult);
  };
  // Native website policy must not unexpectedly block extension-owned service
  // fetches, including the exact URL it blocks for the page.
  EXPECT_EQ(base::Value("allowed"), worker(content::JsReplace(
      "fetch($1).then(()=>chrome.test.sendScriptResult('allowed'),()=>chrome.test.sendScriptResult('blocked'))",
      embedded_test_server()->GetURL("/native-ad"))));
  EXPECT_EQ(base::Value(true), worker(R"(
    chrome.declarativeNetRequest.updateDynamicRules({addRules:[
      {id:1,priority:1,action:{type:'block'},condition:{urlFilter:'/extension-block',resourceTypes:['xmlhttprequest']}},
      {id:2,priority:2,action:{type:'allow'},condition:{urlFilter:'/native-ad',resourceTypes:['xmlhttprequest']}}
    ]}).then(()=>chrome.test.sendScriptResult(true));
  )"));
  EXPECT_EQ(false, content::EvalJs(page,
      "fetch('/native-ad').then(()=>true,()=>false)"));
  const char* allowed[] = {"127.0.0.1"};
  BarcBlockerState policy_state{};
  ASSERT_EQ(1, barc_blocker_state(work_id, &policy_state));
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED, policy_state.required_source_generation, allowed, std::size(allowed)));
  EXPECT_EQ(false, content::EvalJs(page,
      "fetch('/extension-block').then(()=>true,()=>false)"));
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED, policy_state.required_source_generation, nullptr, 0));
  // Dynamically adding a matching requestBody listener must materialize the
  // existing retained upload once, even though native-only requests were lazy.
  EXPECT_EQ(base::Value(true), worker(R"(
    globalThis.bodyPromise=new Promise(resolve=>{
      chrome.webRequest.onBeforeRequest.addListener(
        details=>resolve(details.requestBody.formData.field[0]),
        {urls:['*://127.0.0.1/*native-body*']},['requestBody']);
    });chrome.test.sendScriptResult(true);
  )"));
  EXPECT_EQ(true, content::EvalJs(page, R"(
    fetch('/native-body',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:'field=synthetic-value'}).then(()=>true,()=>false);
  )"));
  EXPECT_EQ(base::Value("synthetic-value"), worker(
      "globalThis.bodyPromise.then(chrome.test.sendScriptResult)"));
}

// The matcher draft must be linked for these real-loader observations. No test
// bypasses resource eligibility or interprets a zero count as upload-idle.
IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest, ObservedDocumentBodyStreamAndCancel) {
  net::EmbeddedTestServer server(net::EmbeddedTestServer::TYPE_HTTPS,
      net::test_server::HttpConnection::Protocol::kHttp2);
  server.ServeFilesFromSourceDirectory("chrome/test/data");
  net::test_server::ControllableHttpResponse completed(&server, "/body-complete");
  net::test_server::ControllableHttpResponse aborted(&server, "/body-abort");
  ASSERT_TRUE(server.Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  InstallNativeBlocker(work_id, NativeBlockerTestRules());
  Navigate(work, server.GetURL("/title1.html"));
  Navigate(personal, server.GetURL("/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  auto* other = personal->GetTabStripModel()->GetActiveWebContents();
  auto observed = [](content::WebContents* contents) {
    auto node = performance_manager::PerformanceManager::GetPrimaryPageNodeForWebContents(contents);
    return node && performance_manager::PageLiveStateDecorator::Data::GetOrCreateForPageNode(node.get())
        ->HasObservedDocumentBodyWork();
  };
  auto begin = [&](const char* path) {
    return content::ExecJs(page, content::JsReplace(R"(
      window.abortBody = new AbortController();
      window.bodyDone = 'pending';
      window.bodyPromise = fetch($1, {method:'POST', duplex:'half', signal:abortBody.signal,
        body:new ReadableStream({start(c){window.bodyController=c;c.enqueue(new Uint8Array([65]));}})})
        .then(r=>r.text()).then(()=>bodyDone='complete',()=>bodyDone='error');
      true;
    )", path));
  };
  ASSERT_TRUE(begin("/body-complete"));
  ASSERT_TRUE(base::test::RunUntil([&] { return observed(page); }));
  EXPECT_FALSE(observed(other));
  ASSERT_TRUE(content::ExecJs(page, "bodyController.enqueue(new Uint8Array([66]));true;"));
  EXPECT_TRUE(observed(page));
  ASSERT_TRUE(content::ExecJs(page, "bodyController.close();true;"));
  completed.WaitForRequest();
  EXPECT_TRUE(observed(page));
  completed.Send(net::HTTP_OK, "text/plain", "complete");
  completed.Done();
  EXPECT_EQ("complete", content::EvalJs(page, "bodyPromise.then(()=>bodyDone)"));
  ASSERT_TRUE(base::test::RunUntil([&] { return !observed(page); }));
  ASSERT_TRUE(begin("/body-abort"));
  ASSERT_TRUE(base::test::RunUntil([&] { return observed(page); }));
  ASSERT_TRUE(content::ExecJs(page, "abortBody.abort();true;"));
  EXPECT_EQ("error", content::EvalJs(page, "bodyPromise.then(()=>bodyDone)"));
  ASSERT_TRUE(base::test::RunUntil([&] { return !observed(page); }));
  EXPECT_FALSE(observed(other));
  EXPECT_TRUE(performance_manager::features::IsNativeResourceProtectionHeld());
}

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest, ObservedDocumentBodyRedirectPrivateAndKeepaliveBoundary) {
  net::test_server::ControllableHttpResponse redirect(embedded_test_server(), "/body-redirect");
  net::test_server::ControllableHttpResponse target(embedded_test_server(), "/body-target");
  net::test_server::ControllableHttpResponse keepalive(embedded_test_server(), "/body-keepalive");
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  SharedProfileResult private_result;
  barc_private_session_open_window(SharedProfileCompleted, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  const int32_t private_id = private_result.Get<1>();
  auto* private_browser = SharedWindow(private_id);
  ASSERT_NE(work->GetProfile(), private_browser->GetProfile());
  InstallNativeBlocker(private_id, NativeBlockerTestRules());
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  Navigate(private_browser, embedded_test_server()->GetURL("/title1.html"));
  auto* page = private_browser->GetTabStripModel()->GetActiveWebContents();
  auto* regular = work->GetTabStripModel()->GetActiveWebContents();
  auto observed = [](content::WebContents* contents) {
    auto node = performance_manager::PerformanceManager::GetPrimaryPageNodeForWebContents(contents);
    return node && performance_manager::PageLiveStateDecorator::Data::GetOrCreateForPageNode(node.get())
        ->HasObservedDocumentBodyWork();
  };
  ASSERT_TRUE(content::ExecJs(page, R"(
    const form = new FormData();form.append('body','synthetic');
    window.bodyPromise = fetch('/body-redirect',{method:'POST',body:form}).then(r=>r.text());true;
  )"));
  redirect.WaitForRequest();
  EXPECT_TRUE(observed(page));
  EXPECT_FALSE(observed(regular));
  const std::string location = "Location: " + embedded_test_server()->GetURL("/body-target").spec();
  redirect.Send(net::HTTP_TEMPORARY_REDIRECT, "text/plain", "", {}, {location});
  redirect.Done();
  target.WaitForRequest();
  EXPECT_TRUE(observed(page));
  target.Send(net::HTTP_OK, "text/plain", "redirected");
  target.Done();
  EXPECT_EQ("redirected", content::EvalJs(page, "bodyPromise"));
  ASSERT_TRUE(base::test::RunUntil([&] { return !observed(page); }));
  ASSERT_TRUE(content::ExecJs(page, "window.keepBody=fetch('/body-keepalive',{method:'POST',body:'synthetic',keepalive:true}).then(r=>r.text());true;"));
  keepalive.WaitForRequest();
  // Excluded deliberately: renderer disconnection is not keepalive completion.
  EXPECT_FALSE(observed(page));
  EXPECT_TRUE(performance_manager::features::IsNativeResourceProtectionHeld());
  Navigate(private_browser, embedded_test_server()->GetURL("/title2.html"));
  EXPECT_FALSE(observed(page));
  EXPECT_FALSE(observed(regular));
  keepalive.Send(net::HTTP_OK, "text/plain", "finished after document replacement");
  keepalive.Done();
}

class BarcObservedBodyReusedFrameBrowserTest : public BarcNativeBlockerBrowserTest {
 public:
  BarcObservedBodyReusedFrameBrowserTest() {
    feature_list_.InitWithFeatures(
        {}, {features::kRenderDocument, features::kBackForwardCache});
  }
 private:
  base::test::ScopedFeatureList feature_list_;
};

IN_PROC_BROWSER_TEST_F(BarcObservedBodyReusedFrameBrowserTest,
                       ObservedBodyStaleFactoryCannotBorrowReusedFrameDocument) {
  net::test_server::ControllableHttpResponse stale(embedded_test_server(), "/body-old-factory");
  net::test_server::ControllableHttpResponse current(embedded_test_server(), "/body-current-factory");
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  InstallNativeBlocker(work_id, NativeBlockerTestRules());
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  auto* first_frame = page->GetPrimaryMainFrame();
  const int64_t first_navigation = first_frame->GetNavigationId();
  mojo::Remote<network::mojom::URLLoaderFactory> old_factory;
  first_frame->CreateNetworkServiceDefaultFactory(old_factory.BindNewPipeAndPassReceiver());
  ASSERT_TRUE(content::NavigateToURLFromRenderer(page, embedded_test_server()->GetURL("/title2.html")));
  ASSERT_EQ(first_frame, page->GetPrimaryMainFrame());
  ASSERT_NE(first_navigation, first_frame->GetNavigationId());
  auto observed = [&] {
    auto node = performance_manager::PerformanceManager::GetPrimaryPageNodeForWebContents(page);
    return node && performance_manager::PageLiveStateDecorator::Data::GetOrCreateForPageNode(node.get())
        ->HasObservedDocumentBodyWork();
  };
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = embedded_test_server()->GetURL("/body-old-factory");
  request->method = "POST";
  request->request_initiator = url::Origin::Create(page->GetLastCommittedURL());
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  auto loader = network::SimpleURLLoader::Create(std::move(request), TRAFFIC_ANNOTATION_FOR_TESTS);
  loader->AttachStringForUpload("old document factory", "text/plain");
  base::test::TestFuture<std::optional<std::string>> stale_reply;
  loader->DownloadToString(old_factory.get(), stale_reply.GetCallback(), 1024);
  stale.WaitForRequest();
  EXPECT_FALSE(observed());  // RFH identity alone must never attribute this body.
  // Active RFH + pending navigation was deliberately ambiguous. A new
  // explicitly post-commit factory has an exact current-document identity.
  mojo::Remote<network::mojom::URLLoaderFactory> current_factory;
  first_frame->CreateNetworkServiceDefaultFactory(current_factory.BindNewPipeAndPassReceiver());
  auto current_request = std::make_unique<network::ResourceRequest>();
  current_request->url = embedded_test_server()->GetURL("/body-current-factory");
  current_request->method = "POST";
  current_request->request_initiator = url::Origin::Create(page->GetLastCommittedURL());
  current_request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  auto current_loader = network::SimpleURLLoader::Create(std::move(current_request), TRAFFIC_ANNOTATION_FOR_TESTS);
  current_loader->AttachStringForUpload("new document factory", "text/plain");
  base::test::TestFuture<std::optional<std::string>> current_reply;
  current_loader->DownloadToString(current_factory.get(), current_reply.GetCallback(), 1024);
  current.WaitForRequest();
  EXPECT_TRUE(observed());
  stale.Send(net::HTTP_OK, "text/plain", "old factory complete");
  stale.Done();
  EXPECT_TRUE(stale_reply.Get().has_value());
  EXPECT_TRUE(observed());  // Old completion cannot remove the new token.
  current.Send(net::HTTP_OK, "text/plain", "new factory complete");
  current.Done();
  EXPECT_EQ("new factory complete", current_reply.Get().value_or(""));
  ASSERT_TRUE(base::test::RunUntil([&] { return !observed(); }));
  EXPECT_TRUE(performance_manager::features::IsNativeResourceProtectionHeld());
}

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest,
                       NativeBlockerShutdownCancelsQueuedBorrowWithoutWorker) {
  class CountedInput final : public base::RefCountedMemory {
   public:
    CountedInput(std::vector<uint8_t> bytes, std::atomic<int>* reads,
                 std::atomic<bool>* destroyed)
        : bytes_(std::move(bytes)), reads_(reads), destroyed_(destroyed) {}
   private:
    ~CountedInput() override { destroyed_->store(true); }
    base::span<const uint8_t> AsSpan() const override {
      ++*reads_;
      return bytes_;
    }
    const std::vector<uint8_t> bytes_;
    const raw_ptr<std::atomic<int>> reads_;
    const raw_ptr<std::atomic<bool>> destroyed_;
  };
  const uint64_t generation = NextBlockerSource();
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED, generation, nullptr, 0));
  std::atomic<int> reads{0};
  std::atomic<bool> destroyed{false};
  int completions = 0;
  base::test::TestFuture<NativeContentBlocker::Result> result;
  {
    base::ScopedThreadPoolExecutionFence queued;
    NativeContentBlocker::PublishRules(
        base::MakeRefCounted<CountedInput>(NativeBlockerTestRules(), &reads, &destroyed),
        generation, base::BindLambdaForTesting([&](NativeContentBlocker::Result value) {
          ++completions;
          EXPECT_TRUE(destroyed.load()); // Borrow is safe before UI completion.
          result.SetValue(value);
        }));
    EXPECT_EQ(0, reads.load());
    NativeContentBlocker::StopPolicy();
    ASSERT_TRUE(result.IsReady()); // No queued worker/parser is required to run.
    EXPECT_EQ(NativeContentBlocker::Result::kOwnerEnded, result.Get().status);
    EXPECT_EQ(0, reads.load());
    EXPECT_EQ(1, completions);
  }
  base::ThreadPoolInstance::Get()->FlushForTesting();
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(0, reads.load());
  EXPECT_EQ(1, completions); // The cancelled late worker reply is inert.
}

IN_PROC_BROWSER_TEST_F(BarcObservedBodyReusedFrameBrowserTest,
                       NativeBlockerStaleRequestCannotBorrowReplacementTabPolicy) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  InstallNativeBlocker(work_id, NativeBlockerTestRules());
  const GURL first_url = embedded_test_server()->GetURL("/title1.html");
  Navigate(work, first_url);
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  auto* frame = page->GetPrimaryMainFrame();
  auto* policy = NativeContentBlocker::Get(work->GetProfile(), false);
  auto original = NativeContentBlocker::CaptureClient(page, frame, first_url);
  mojo::Remote<network::mojom::URLLoaderFactory> original_factory;
  frame->CreateNetworkServiceDefaultFactory(original_factory.BindNewPipeAndPassReceiver());
  ASSERT_TRUE(content::NavigateToURLFromRenderer(page,
      embedded_test_server()->GetURL("/title2.html")));
  ASSERT_EQ(frame, page->GetPrimaryMainFrame());
  EXPECT_FALSE(original.document.AsRenderFrameHostIfValid());
  const int32_t tab = barc_window_tab_at(work_id, 0);
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, tab, 1, nullptr, 0));
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = embedded_test_server()->GetURL("/native-ad");
  request->request_initiator = url::Origin::Create(first_url);
  auto loader = network::SimpleURLLoader::Create(std::move(request), TRAFFIC_ANNOTATION_FOR_TESTS);
  base::test::TestFuture<std::optional<std::string>> response;
  loader->DownloadToString(original_factory.get(), response.GetCallback(), 1024);
  EXPECT_FALSE(response.Get().has_value());
  EXPECT_EQ(net::ERR_BLOCKED_BY_CLIENT, loader->NetError());
  EXPECT_EQ(true, content::EvalJs(page, "fetch('/native-ad').then(()=>true,()=>false)"));
  // An old main-frame decision also cannot clear the replacement document's
  // approved continued host while it is retried after a policy revision.
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, tab, 0,
      std::string(page->GetLastCommittedURL().host()).c_str(), 0));
  base::test::TestFuture<int> old_main;
  policy->Check(embedded_test_server()->GetURL("other.test", "/native-ad"),
      first_url, std::move(original), "main_frame", "GET", old_main.GetCallback());
  EXPECT_EQ(net::ERR_BLOCKED_BY_CLIENT, old_main.Get());
  EXPECT_EQ(true, content::EvalJs(page, "fetch('/native-ad').then(()=>true,()=>false)"));
}

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest,
                       NativeBlockerUnreadyWebsiteRequestWaitsThenDisableReleases) {
  auto outgoing = std::make_shared<std::atomic<int>>(0);
  embedded_test_server()->RegisterRequestMonitor(base::BindRepeating(
      [](std::shared_ptr<std::atomic<int>> outgoing,
         const net::test_server::HttpRequest& request) {
        if (request.relative_url == "/native-ad") ++*outgoing;
      }, outgoing));
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t window = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(window);
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED, NextBlockerSource(), nullptr, 0));
  ASSERT_TRUE(content::WaitForLoadStop(page));
  ASSERT_TRUE(content::ExecJs(page, content::JsReplace(R"(
    window.policyResult='pending';
    window.policyFetch=fetch($1,{mode:'no-cors'}).then(()=>policyResult='allowed',()=>policyResult='failed');true;
  )", embedded_test_server()->GetURL("/native-ad"))));
  // This round trip establishes that the fetch was issued while the renderer
  // remains responsive; no timeout/sleep is an admission oracle.
  EXPECT_EQ("pending", content::EvalJs(page, "policyResult"));
  EXPECT_EQ(0, outgoing->load());
  NativeBlockerReply ready;
  ASSERT_EQ(1, barc_blocker_prepare(window, NativeBlockerReply::Receive, &ready));
  EXPECT_FALSE(ready.value.IsReady());
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  EXPECT_EQ(BARC_BLOCKER_READY, ready.value.Get<1>());
  EXPECT_EQ("allowed", content::EvalJs(page, "policyFetch"));
  EXPECT_EQ(1, outgoing->load());
}

namespace {
std::vector<uint8_t> NativeCosmeticTestRules(bool value = true) {
  std::string lists = R"COSMETIC([{"rules":"cosmetic.test##.native-hide\n127.0.0.1##.native-hide\n127.0.0.1##+js(trusted-set-constant, nativeBeforeInline, true)\nframe.test##.native-hide\n##.native-generic\n##.native-spa\n##.native-after-cache\ncosmetic.test##.native-style:style(color: rgb(1, 2, 3))\ncosmetic.test##.unsupported:has-text(Sponsored)\ncosmetic.test##+js(trusted-set-constant, nativeBeforeInline, true)\nframe.test##+js(trusted-set-constant, nativeBeforeInline, true)","trusted":true}])COSMETIC";
  if (!value) base::ReplaceSubstringsAfterOffset(&lists, 0,
      "nativeBeforeInline, true", "nativeBeforeInline, false");
  std::unique_ptr<void, decltype(&nook_adblock_engine_free)> engine(
      nook_adblock_engine_from_lists(lists.data(), lists.size()),
      &nook_adblock_engine_free);
  CHECK(engine);
  size_t size = 0;
  uint8_t* data = nook_adblock_engine_serialize(engine.get(), &size);
  CHECK(data);
  auto bytes = UNSAFE_BUFFERS(base::span(data, size));
  std::vector<uint8_t> result(bytes.begin(), bytes.end());
  nook_adblock_buffer_free(data, size);
  return result;
}
void RegisterNativeCosmeticDocument(net::EmbeddedTestServer* server) {
  server->RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/native-cosmetics" &&
            request.relative_url != "/native-cosmetics-sandbox") return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK);
        response->set_content_type("text/html");
        if (request.relative_url == "/native-cosmetics-sandbox")
          response->AddCustomHeader("Content-Security-Policy", "sandbox");
        response->set_content(R"(<script>
          window.firstInlineSawNative = window.nativeBeforeInline === true;
          const probe=document.createElement('div');probe.className='native-hide';
          document.documentElement.append(probe);
          window.firstInlineSawCss=getComputedStyle(probe).display==='none';
          probe.remove();
          window.bootstrapCount = (window.bootstrapCount || 0) + 1;
        </script><div class="native-hide">hidden</div>
        <div class="native-style">styled</div>
        <div class="unsupported">Sponsored</div>)");
        return response;
      }));
}
}

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest,
                       NativeCosmeticsPrecedeFirstInlineAndFollowDocument) {
  RegisterNativeCosmeticDocument(embedded_test_server());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  InstallNativeBlocker(work_id, NativeCosmeticTestRules());
  const GURL url = embedded_test_server()->GetURL("cosmetic.test", "/native-cosmetics");
  Navigate(work, url);
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  EXPECT_EQ(true, content::EvalJs(page, "firstInlineSawNative"));
  EXPECT_EQ(true, content::EvalJs(page, "firstInlineSawCss"));
  EXPECT_EQ(1, content::EvalJs(page, "bootstrapCount"));
  EXPECT_EQ("none", content::EvalJs(page,
      "getComputedStyle(document.querySelector('.native-hide')).display"));
  EXPECT_EQ("rgb(1, 2, 3)", content::EvalJs(page,
      "getComputedStyle(document.querySelector('.native-style')).color"));
  EXPECT_NE("none", content::EvalJs(page,
      "getComputedStyle(document.querySelector('.unsupported')).display"));
  // Generic rules use one batched class/id lookup on the same native matcher.
  EXPECT_EQ(true, content::EvalJs(page, R"(
    new Promise(resolve=>{
      const node=document.createElement('div');node.className='native-generic';
      document.body.append(node);
      const observer=new ResizeObserver(()=>{
        if(getComputedStyle(node).display==='none'){
          observer.disconnect();resolve(true);
        }
      });observer.observe(node);
    })
  )"));
  EXPECT_EQ(true, content::EvalJs(page, R"(
    new Promise(resolve=>{
      history.pushState({},'', '/native-cosmetic-spa');
      const node=document.createElement('div');node.className='native-spa';
      const observer=new ResizeObserver(()=>{
        if(getComputedStyle(node).display==='none'){
          observer.disconnect();resolve(true);
        }
      });observer.observe(node);document.body.append(node);
    })
  )"));
  EXPECT_EQ(true, content::EvalJs(page, content::JsReplace(R"(
    new Promise(resolve=>{
      const child=document.createElement('iframe');
      child.onload=()=>resolve(true);child.src=$1;document.body.append(child);
    })
  )", embedded_test_server()->GetURL("frame.test", "/native-cosmetics"))));
  auto* child = content::ChildFrameAt(page->GetPrimaryMainFrame(), 0);
  ASSERT_TRUE(child);
  EXPECT_NE(page->GetPrimaryMainFrame()->GetProcess(), child->GetProcess());
  EXPECT_EQ(true, content::EvalJs(child, "firstInlineSawNative"));
  EXPECT_EQ(true, content::EvalJs(child, "firstInlineSawCss"));
  const auto previous = page->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  Navigate(work, url);  // Same URL is still a new, separately authorized document.
  EXPECT_FALSE(previous.AsRenderFrameHostIfValid());
  EXPECT_EQ(true, content::EvalJs(page, "firstInlineSawNative"));
  EXPECT_EQ(1, content::EvalJs(page, "bootstrapCount"));
  Navigate(work, embedded_test_server()->GetURL("cosmetic.test", "/native-cosmetics-sandbox"));
  EXPECT_EQ("undefined", content::EvalJs(page, "typeof nativeBeforeInline"));
  EXPECT_EQ("none", content::EvalJs(page,
      "getComputedStyle(document.querySelector('.native-hide')).display"));
}

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest,
                       NativeCosmeticsRejectForeignStaleAndChangedPolicy) {
  RegisterNativeCosmeticDocument(embedded_test_server());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  const int32_t personal_id = Open(kSharedPersonal, 0, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  InstallNativeBlocker(work_id, NativeCosmeticTestRules());
  PrepareNativeBlocker(personal_id);
  const GURL url = embedded_test_server()->GetURL("cosmetic.test", "/native-cosmetics");
  Navigate(work, url);
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  auto* frame = page->GetPrimaryMainFrame();
  const auto document = frame->GetDocumentToken();
  auto* service = NativeContentBlocker::Get(work->GetProfile(), true);
  auto* foreign = NativeContentBlocker::Get(personal->GetProfile(), true);
  base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> denied;
  foreign->GetCosmeticResources(frame->GetGlobalId(), document, url, {}, {},
                                false, denied.GetCallback());
  EXPECT_FALSE(denied.Take());
  // Queue worker lookup then synchronously disable before its UI continuation.
  base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> disabled;
  service->GetCosmeticResources(frame->GetGlobalId(), document, url, {}, {},
                                false, disabled.GetCallback());
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  auto disabled_resources = disabled.Take();
  ASSERT_TRUE(disabled_resources);
  EXPECT_FALSE(disabled_resources->apply);
  EXPECT_TRUE(disabled_resources->scriptlets.empty());
  EXPECT_EQ(true, content::EvalJs(page, R"(
    new Promise(resolve=>{
      const node=document.querySelector('.native-hide');
      const observer=new ResizeObserver(()=>{
        if(getComputedStyle(node).display!=='none'){
          observer.disconnect();resolve(true);
        }
      });observer.observe(node);
    })
  )"));
  // CSS/observers are removable. Page-world scriptlets are explicitly undone by
  // the existing reload policy, never a claim of undoing arbitrary JS effects.
  EXPECT_EQ(true, content::EvalJs(page, "nativeBeforeInline"));
  Navigate(work, url);
  EXPECT_EQ(false, content::EvalJs(page, "firstInlineSawNative"));
  base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> stale;
  service->GetCosmeticResources(page->GetPrimaryMainFrame()->GetGlobalId(),
      document, url, {}, {}, false, stale.GetCallback());
  EXPECT_FALSE(stale.Take());
  InstallNativeBlocker(work_id, NativeCosmeticTestRules());
  const int32_t work_tab = work->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value();
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, work_tab, 1, "", 0));
  Navigate(work, url);
  EXPECT_EQ(false, content::EvalJs(page, "firstInlineSawNative"));
  Navigate(personal, url);
  EXPECT_EQ(true, content::EvalJs(personal->GetTabStripModel()->GetActiveWebContents(),
                                "firstInlineSawNative"));
  SharedProfileResult private_result;
  barc_private_session_open_window(SharedProfileCompleted, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  auto* private_browser = SharedWindow(private_result.Get<1>());
  ASSERT_TRUE(private_browser);
  Navigate(private_browser, url);
  EXPECT_EQ(true, content::EvalJs(
      private_browser->GetTabStripModel()->GetActiveWebContents(), "firstInlineSawNative"));
}

namespace {
class BarcNativeCosmeticCacheBrowserTest : public BarcNativeBlockerBrowserTest {
 public:
  BarcNativeCosmeticCacheBrowserTest() {
    features_.InitWithFeaturesAndParameters(
        content::GetDefaultEnabledBackForwardCacheFeaturesForTesting(),
        content::GetDefaultDisabledBackForwardCacheFeaturesForTesting());
  }
 private:
  base::test::ScopedFeatureList features_;
};
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       NativeCosmeticsRetainUnchangedCacheEvictChangedDocuments) {
  RegisterNativeCosmeticDocument(embedded_test_server());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  InstallNativeBlocker(work_id, NativeCosmeticTestRules());
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  const GURL url = embedded_test_server()->GetURL("cosmetic.test", "/native-cosmetics");
  const GURL away = embedded_test_server()->GetURL("other.test", "/title1.html");
  Navigate(work, url);
  ASSERT_EQ(true, content::EvalJs(page, "firstInlineSawNative"));
  EXPECT_EQ("draft", content::EvalJs(page, "window.nativeDraft='draft'"));
  auto saved = page->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  Navigate(work, away);
  auto* cached = saved.AsRenderFrameHostIfValid();
  ASSERT_TRUE(cached);
  ASSERT_EQ(content::RenderFrameHost::LifecycleState::kInBackForwardCache,
            cached->GetLifecycleState());
  BarcBlockerState state{};
  ASSERT_EQ(1, barc_blocker_state(work_id, &state));
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED,
      state.required_source_generation, nullptr, 0));
  const int32_t tab = work->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value();
  // An ordinary default tab-policy application advances network retry state,
  // but must not invalidate unchanged cosmetic resources or cached documents.
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, tab, 0, "", 0));
  const char* unaffected[] = {"unrelated.test"};
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED,
      state.required_source_generation, unaffected, 1));
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED,
      state.required_source_generation, nullptr, 0));
  EXPECT_EQ(cached, saved.AsRenderFrameHostIfValid());
  EXPECT_EQ(content::RenderFrameHost::LifecycleState::kInBackForwardCache,
            cached->GetLifecycleState());
  content::TestNavigationObserver restored(page);
  page->GetController().GoBack();
  restored.Wait();
  EXPECT_EQ(cached, page->GetPrimaryMainFrame());
  EXPECT_EQ("draft", content::EvalJs(page, "nativeDraft"));
  EXPECT_EQ(1, content::EvalJs(page, "bootstrapCount"));
  EXPECT_EQ(true, content::EvalJs(page, R"(
    new Promise(resolve=>{
      const node=document.createElement('div');node.className='native-after-cache';
      const observer=new ResizeObserver(()=>{
        if(getComputedStyle(node).display==='none'){
          observer.disconnect();resolve(true);
        }
      });observer.observe(node);document.body.append(node);
    })
  )"));
  // Material change while live prevents this stale scriptlet document entering
  // cache later, even if the user declines the product's explicit reload.
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  content::RenderFrameDeletedObserver deleted_live(page->GetPrimaryMainFrame());
  Navigate(work, away);
  deleted_live.WaitUntilDeleted();
  EXPECT_FALSE(saved.AsRenderFrameHostIfValid());
  content::TestNavigationObserver changed(page);
  page->GetController().GoBack();
  changed.Wait();
  EXPECT_EQ(false, content::EvalJs(page, "firstInlineSawNative"));
  EXPECT_EQ("undefined", content::EvalJs(page, "typeof nativeDraft"));

  // A changed cached document is evicted immediately as well.
  InstallNativeBlocker(work_id, NativeCosmeticTestRules());
  Navigate(work, url);
  auto cached_again = page->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  Navigate(work, away);
  auto* old = cached_again.AsRenderFrameHostIfValid();
  ASSERT_TRUE(old);
  ASSERT_EQ(content::RenderFrameHost::LifecycleState::kInBackForwardCache,
            old->GetLifecycleState());
  content::RenderFrameDeletedObserver deleted_cached(old);
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  deleted_cached.WaitUntilDeleted();
  EXPECT_FALSE(cached_again.AsRenderFrameHostIfValid());
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       NativeCosmeticsEquivalentExceptionsPreserveCachedDraft) {
  RegisterNativeCosmeticDocument(embedded_test_server());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  InstallNativeBlocker(work_id, NativeCosmeticTestRules());
  const int32_t tab = work->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value();
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, tab, 1, "cosmetic.test", 0));
  Navigate(work, embedded_test_server()->GetURL("cosmetic.test", "/native-cosmetics"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  EXPECT_EQ(false, content::EvalJs(page, "firstInlineSawNative"));
  EXPECT_EQ("exempt-draft", content::EvalJs(page, "window.nativeDraft='exempt-draft'"));
  auto saved = page->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  Navigate(work, embedded_test_server()->GetURL("other.test", "/title1.html"));
  auto* cached = saved.AsRenderFrameHostIfValid();
  ASSERT_TRUE(cached);
  ASSERT_EQ(content::RenderFrameHost::LifecycleState::kInBackForwardCache,
            cached->GetLifecycleState());
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, tab, 1, "cosmetic.test", 0));
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, tab, 1, "cosmetic.test", 60000));
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, tab, 1, "cosmetic.test", 59999));
  InstallNativeBlocker(work_id, NativeCosmeticTestRules(false));
  EXPECT_EQ(cached, saved.AsRenderFrameHostIfValid());
  content::TestNavigationObserver restored(page);
  page->GetController().GoBack();
  restored.Wait();
  EXPECT_EQ(cached, page->GetPrimaryMainFrame());
  EXPECT_EQ("exempt-draft", content::EvalJs(page, "nativeDraft"));
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       NativeCosmeticsCompareAcceptedBytesNotArrivalRevision) {
  RegisterNativeCosmeticDocument(embedded_test_server());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  const auto rules = NativeCosmeticTestRules();
  InstallNativeBlocker(work_id, rules);
  BarcBlockerState state{};
  ASSERT_EQ(1, barc_blocker_state(work_id, &state));
  const GURL url = embedded_test_server()->GetURL("cosmetic.test", "/native-cosmetics");
  const GURL away = embedded_test_server()->GetURL("other.test", "/title1.html");
  Navigate(work, url);
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  EXPECT_EQ("same-source", content::EvalJs(page, "window.nativeDraft='same-source'"));
  auto saved = page->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  Navigate(work, away);
  auto* cached = saved.AsRenderFrameHostIfValid();
  ASSERT_TRUE(cached);
  ASSERT_EQ(content::RenderFrameHost::LifecycleState::kInBackForwardCache,
            cached->GetLifecycleState());
  NativeBlockerReply identical;
  ASSERT_EQ(1, barc_blocker_publish_rules(rules.data(), rules.size(),
      state.required_source_generation, NativeBlockerReply::Receive, &identical));
  ASSERT_EQ(BARC_BLOCKER_READY, identical.value.Get<1>());
  PrepareNativeBlocker(work_id);
  EXPECT_EQ(cached, saved.AsRenderFrameHostIfValid());
  content::TestNavigationObserver restored(page);
  page->GetController().GoBack();
  restored.Wait();
  EXPECT_EQ(cached, page->GetPrimaryMainFrame());
  EXPECT_EQ("same-source", content::EvalJs(page, "nativeDraft"));
  Navigate(work, away);
  content::RenderFrameDeletedObserver removed(cached);
  const auto changed = NativeCosmeticTestRules(false);
  NativeBlockerReply replacement;
  ASSERT_EQ(1, barc_blocker_publish_rules(changed.data(), changed.size(),
      state.required_source_generation, NativeBlockerReply::Receive, &replacement));
  ASSERT_EQ(BARC_BLOCKER_READY, replacement.value.Get<1>());
  removed.WaitUntilDeleted();
  EXPECT_FALSE(saved.AsRenderFrameHostIfValid());
  content::TestNavigationObserver fresh(page);
  page->GetController().GoBack();
  fresh.Wait();
  EXPECT_EQ(false, content::EvalJs(page, "firstInlineSawNative"));
  EXPECT_EQ(false, content::EvalJs(page, "nativeBeforeInline"));
  EXPECT_EQ("undefined", content::EvalJs(page, "typeof nativeDraft"));
}

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest,
                       NativeCosmeticsBoundGenericRequestsAndReleaseOnDisable) {
  RegisterNativeCosmeticDocument(embedded_test_server());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  InstallNativeBlocker(work_id, NativeCosmeticTestRules());
  Navigate(work, embedded_test_server()->GetURL("cosmetic.test", "/native-cosmetics"));
  auto* frame = work->GetTabStripModel()->GetActiveWebContents()->GetPrimaryMainFrame();
  const auto document = frame->GetDocumentToken();
  mojo::Remote<chrome::mojom::NookCosmeticResourcesHost> host;
  NativeContentBlocker::BindCosmeticResources(frame, host.BindNewPipeAndPassReceiver());
  for (int invalid = 0; invalid < 3; ++invalid) {
    std::vector<std::string> classes;
    if (invalid == 0) classes = {std::string(513, 'x')};
    if (invalid == 1) classes.assign(129, "x");
    if (invalid == 2) classes.assign(128, std::string(512, 'x'));
    base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> reply;
    host->GetGenericSelectors(document, classes, {}, reply.GetCallback());
    EXPECT_FALSE(reply.Take());
  }
  const auto desired = NextBlockerSource();
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED, desired, nullptr, 0));
  base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> pending, rejected;
  host->GetGenericSelectors(document, {"native-generic"}, {}, pending.GetCallback());
  host->GetGenericSelectors(document, {"native-other"}, {}, rejected.GetCallback());
  EXPECT_FALSE(rejected.Take());
  EXPECT_FALSE(pending.IsReady());
  // No producer resume, polling or cancellation of shared preparation.
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  auto released = pending.Take();
  ASSERT_TRUE(released);
  EXPECT_FALSE(released->apply);
  // Exact-document cumulative input budget, independently of renderer JS caps.
  for (int batch = 0; batch < 15; ++batch) {
    base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> reply;
    host->GetGenericSelectors(document,
        std::vector<std::string>(16, std::string(512, 'x')), {}, reply.GetCallback());
    EXPECT_TRUE(reply.Take());
  }
  base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> last;
  host->GetGenericSelectors(document,
      std::vector<std::string>(15, std::string(512, 'x')), {}, last.GetCallback());
  EXPECT_TRUE(last.Take());
  base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> over;
  host->GetGenericSelectors(document, {std::string(512, 'x')}, {}, over.GetCallback());
  EXPECT_FALSE(over.Take());
}

namespace {
class BarcNativeCosmeticPrerenderBrowserTest : public BarcNativeBlockerBrowserTest {
 private:
  content::test::ScopedPrerenderFeatureList prerender_features_;
};
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticPrerenderBrowserTest,
                       NativeCosmeticsPrerenderLookupCompletesBeforeActivation) {
  RegisterNativeCosmeticDocument(embedded_test_server());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  NSView* header = Attach(work_id);
  ASSERT_EQ(1, barc_window_admit_discovered(work_id, (__bridge void*)header));
  ASSERT_EQ(1, barc_window_show(work_id));
  InstallNativeBlocker(work_id, NativeCosmeticTestRules());
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_EQ(content::Visibility::VISIBLE, page->GetVisibility());
  content::test::PrerenderTestHelper prerender(base::BindRepeating(
      [](content::WebContents* contents) { return contents; }, page));
  const GURL target = embedded_test_server()->GetURL("/native-cosmetics");
  const auto id = prerender.AddPrerender(target);
  auto* prepared = prerender.GetPrerenderedMainFrameHost(id);
  ASSERT_TRUE(prepared);
  EXPECT_EQ(content::RenderFrameHost::LifecycleState::kPrerendering,
            prepared->GetLifecycleState());
  EXPECT_EQ(true, content::EvalJs(prepared, "firstInlineSawNative"));
  EXPECT_EQ("none", content::EvalJs(prepared,
      "getComputedStyle(document.querySelector('.native-hide')).display"));
  prerender.NavigatePrimaryPage(target);
  EXPECT_EQ(prepared, page->GetPrimaryMainFrame());
  EXPECT_EQ(true, content::EvalJs(page, "firstInlineSawNative"));
  EXPECT_EQ(1, content::EvalJs(page, "bootstrapCount"));
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticPrerenderBrowserTest,
                       NativeCosmeticsMaterialChangeCancelsPreparedPage) {
  RegisterNativeCosmeticDocument(embedded_test_server());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  NSView* header = Attach(work_id);
  ASSERT_EQ(1, barc_window_admit_discovered(work_id, (__bridge void*)header));
  ASSERT_EQ(1, barc_window_show(work_id));
  InstallNativeBlocker(work_id, NativeCosmeticTestRules());
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  content::test::PrerenderTestHelper prerender(base::BindRepeating(
      [](content::WebContents* contents) { return contents; }, page));
  const GURL target = embedded_test_server()->GetURL("/native-cosmetics");
  const auto id = prerender.AddPrerender(target);
  auto* prepared = prerender.GetPrerenderedMainFrameHost(id);
  ASSERT_TRUE(prepared);
  auto previous = prepared->GetWeakDocumentPtr();
  EXPECT_EQ(true, content::EvalJs(prepared, "firstInlineSawNative"));
  content::RenderFrameDeletedObserver deleted(prepared);
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  deleted.WaitUntilDeleted();
  EXPECT_FALSE(previous.AsRenderFrameHostIfValid());
  prerender.NavigatePrimaryPage(target);
  EXPECT_EQ(false, content::EvalJs(page, "firstInlineSawNative"));
  EXPECT_EQ(1, content::EvalJs(page, "bootstrapCount"));
}

IN_PROC_BROWSER_TEST_F(BarcNativeBlockerBrowserTest,
                       NativeCosmeticsInitialRequestOnceAndDisabledReadiness) {
  RegisterNativeCosmeticDocument(embedded_test_server());
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  InstallNativeBlocker(work_id, NativeCosmeticTestRules());
  Navigate(work, embedded_test_server()->GetURL("cosmetic.test", "/native-cosmetics"));
  auto* frame = work->GetTabStripModel()->GetActiveWebContents()->GetPrimaryMainFrame();
  const auto document = frame->GetDocumentToken();
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED,
                                      NextBlockerSource(), nullptr, 0));
  mojo::Remote<chrome::mojom::NookCosmeticResourcesHost> host;
  NativeContentBlocker::BindCosmeticResources(frame, host.BindNewPipeAndPassReceiver());
  base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> pending, duplicate;
  host->GetResources(document, pending.GetCallback());
  host->GetResources(document, duplicate.GetCallback());
  EXPECT_FALSE(duplicate.Take());
  EXPECT_FALSE(pending.IsReady());
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  auto released = pending.Take();
  ASSERT_TRUE(released);
  EXPECT_FALSE(released->apply);
  base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> repeated;
  host->GetResources(document, repeated.GetCallback());
  EXPECT_FALSE(repeated.Take());
}

namespace {
std::vector<uint8_t> NativeWebSocketRules() {
  const std::string lists = R"([{"rules":"/native-ws$websocket","trusted":false}])";
  std::unique_ptr<void, decltype(&nook_adblock_engine_free)> engine(
      nook_adblock_engine_from_lists(lists.data(), lists.size()), &nook_adblock_engine_free);
  CHECK(engine);
  size_t size = 0;
  uint8_t* data = nook_adblock_engine_serialize(engine.get(), &size);
  CHECK(data);
  std::vector<uint8_t> bytes(UNSAFE_BUFFERS(base::span(data, size)).begin(),
                             UNSAFE_BUFFERS(base::span(data, size)).end());
  nook_adblock_buffer_free(data, size);
  return bytes;
}
class CountingNativeSocket final : public net::test_server::WebSocketEchoHandler {
 public:
  using WebSocketEchoHandler::WebSocketEchoHandler;
  void OnHandshake(const net::test_server::HttpRequest&) override { ++handshakes; }
  inline static std::atomic<int> handshakes{0};
};
class BarcNativeWebSocketBrowserTest : public BarcNativeBlockerBrowserTest {
 protected:
  void SetUpOnMainThread() override {
    BarcNativeBlockerBrowserTest::SetUpOnMainThread();
    https_.SetSSLConfig(net::EmbeddedTestServer::CERT_TEST_NAMES);
    https_.ServeFilesFromSourceDirectory("chrome/test/data");
    net::test_server::InstallDefaultWebSocketHandlers(&https_);
    net::test_server::RegisterWebSocketHandler<net::test_server::WebSocketEchoHandler>(
        &https_, "/native-ws");
    CountingNativeSocket::handshakes = 0;
    net::test_server::RegisterWebSocketHandler<CountingNativeSocket>(&https_, "/stale-ws");
    https_.RegisterRequestHandler(base::BindRepeating(
        [](const net::test_server::HttpRequest& request)
            -> std::unique_ptr<net::test_server::HttpResponse> {
          if (request.relative_url != "/socket-worker.js" &&
              request.relative_url != "/socket-shared.js" &&
              request.relative_url != "/socket-service.js") return nullptr;
          auto response = std::make_unique<net::test_server::BasicHttpResponse>();
          response->set_content_type("text/javascript");
          response->set_content(R"(
            const attempt = url => new Promise(resolve => {
              const socket = new WebSocket(url);
              socket.onopen = () => { socket.close(); resolve('open'); };
              socket.onerror = () => resolve('blocked');
            });
            self.onmessage = event => {
              const reply = event.ports[0] || self;
              const work = attempt(event.data).then(value => reply.postMessage(value));
              if (event.waitUntil) event.waitUntil(work);
            };
            self.onconnect = event => {
              const port = event.ports[0];
              port.onmessage = event => attempt(event.data).then(value => port.postMessage(value));
              port.start();
            };
            self.addEventListener('install', () => self.skipWaiting());
            self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
          )");
          return response;
        }));
    ASSERT_TRUE(https_.Start());
  }
  std::string Attempt(content::WebContents* page, int kind, const GURL& target) {
    return content::EvalJs(page, content::JsReplace(R"(
      (async () => {
        const url = $1, kind = $2;
        if (kind === 0) return await new Promise(resolve => {
          const socket = new WebSocket(url);
          socket.onopen = () => { socket.close(); resolve('open'); };
          socket.onerror = () => resolve('blocked');
        });
        if (kind === 1) return await new Promise(resolve => {
          const worker = new Worker('/socket-worker.js');
          worker.onmessage = event => { worker.terminate(); resolve(event.data); };
          worker.postMessage(url);
        });
        if (kind === 2) return await new Promise(resolve => {
          const worker = new SharedWorker('/socket-shared.js');
          worker.port.onmessage = event => { worker.port.close(); resolve(event.data); };
          worker.port.start(); worker.port.postMessage(url);
        });
        const registration = await navigator.serviceWorker.register('/socket-service.js');
        await navigator.serviceWorker.ready;
        return await new Promise(resolve => {
          const channel = new MessageChannel();
          channel.port1.onmessage = event => { channel.port1.close(); resolve(event.data); };
          registration.active.postMessage(url, [channel.port2]);
        });
      })()
    )", target, kind)).ExtractString();
  }
  net::EmbeddedTestServer https_{net::EmbeddedTestServer::TYPE_HTTPS};
};
}  // namespace

IN_PROC_BROWSER_TEST_F(BarcNativeWebSocketBrowserTest,
                       NativeWebSocketAllInitiatorsUseActualProfileAndTabExceptions) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  auto* personal = SharedWindow(personal_id);
  InstallNativeBlocker(work_id, NativeWebSocketRules());
  Navigate(work, https_.GetURL("a.test", "/title1.html"));
  Navigate(personal, https_.GetURL("a.test", "/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  auto* peer = personal->GetTabStripModel()->GetActiveWebContents();
  const auto blocked = net::test_server::GetWebSocketURL(https_, "a.test", "/native-ws");
  const auto allowed = net::test_server::GetWebSocketURL(https_, "a.test", "/echo-with-no-extension");
  for (int kind = 0; kind != 4; ++kind) {
    EXPECT_EQ("open", Attempt(page, kind, allowed));
    EXPECT_EQ("blocked", Attempt(page, kind, blocked));
  }
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, barc_window_tab_at(work_id, 0),
                                         1, "", 0));
  // A document/dedicated-worker exemption never lends itself to frame-less
  // shared/service workers or another real profile's tab.
  EXPECT_EQ("open", Attempt(page, 0, blocked));
  EXPECT_EQ("open", Attempt(page, 1, blocked));
  EXPECT_EQ("blocked", Attempt(page, 2, blocked));
  EXPECT_EQ("blocked", Attempt(page, 3, blocked));
  EXPECT_EQ("blocked", Attempt(peer, 0, blocked));
  for (int kind = 1; kind != 4; ++kind)
    EXPECT_EQ("blocked", Attempt(peer, kind, blocked));
  SharedProfileResult private_result;
  barc_private_session_open_window(SharedProfileCompleted, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  const int32_t private_id = private_result.Get<1>();
  auto* private_owner = SharedWindow(private_id);
  Navigate(private_owner, https_.GetURL("a.test", "/title1.html"));
  auto* private_page = private_owner->GetTabStripModel()->GetActiveWebContents();
  EXPECT_EQ("blocked", Attempt(private_page, 0, blocked));
  EXPECT_EQ("open", Attempt(private_page, 1, allowed));
  for (int kind = 1; kind != 4; ++kind)
    EXPECT_EQ("blocked", Attempt(private_page, kind, blocked));
  net::test_server::InstallDefaultWebSocketHandlers(embedded_test_server());
  net::test_server::RegisterWebSocketHandler<net::test_server::WebSocketEchoHandler>(
      embedded_test_server(), "/native-ws");
  ASSERT_TRUE(embedded_test_server()->Start());
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, barc_window_tab_at(work_id, 0), 0, "", 0));
  EXPECT_EQ("open", Attempt(work->GetTabStripModel()->GetActiveWebContents(), 0,
      net::test_server::GetWebSocketURL(*embedded_test_server(), "/echo-with-no-extension")));
  EXPECT_EQ("blocked", Attempt(work->GetTabStripModel()->GetActiveWebContents(), 0,
      net::test_server::GetWebSocketURL(*embedded_test_server(), "/native-ws")));

}

IN_PROC_BROWSER_TEST_F(BarcNativeWebSocketBrowserTest,
                       NativeWebSocketExtensionCancellationAndIgnoredRedirectRemainAuthoritative) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  InstallNativeBlocker(work_id, NativeWebSocketRules());
  Navigate(work, https_.GetURL("a.test", "/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  const auto allowed = net::test_server::GetWebSocketURL(https_, "a.test", "/echo-with-no-extension");
  const auto blocked = net::test_server::GetWebSocketURL(https_, "a.test", "/native-ws");
  extensions::TestExtensionDir dir;
  dir.WriteManifest(R"({"manifest_version":3,"name":"Socket policy ordering",
    "version":"1.0","permissions":["declarativeNetRequest"],
    "host_permissions":["<all_urls>"],"background":{"service_worker":"worker.js"}})");
  dir.WriteFile(FILE_PATH_LITERAL("worker.js"), content::JsReplace(R"(
    chrome.declarativeNetRequest.updateDynamicRules({addRules:[
      {id:1,priority:1,action:{type:'block'},condition:{urlFilter:'/echo',resourceTypes:['websocket']}},
      {id:2,priority:1,action:{type:'redirect',redirect:{url:$1}},
       condition:{urlFilter:'ignored-redirect',resourceTypes:['websocket']}}
    ]}).then(()=>chrome.test.sendMessage('native-socket-extension-ready'));
  )", https_.GetURL("a.test", "/native-ws")));
  ExtensionTestMessageListener ready("native-socket-extension-ready");
  ready.set_browser_context(work->GetProfile());
  extensions::ChromeTestExtensionLoader loader(work->GetProfile());
  const auto extension = loader.LoadExtension(dir.UnpackedPath());
  ASSERT_TRUE(extension);
  ready.set_extension_id(extension->id());
  ASSERT_TRUE(ready.WaitUntilSatisfied());
  EXPECT_EQ("blocked", Attempt(page, 0, allowed));
  // Upstream DNR intentionally ignores redirect actions for sockets. A native
  // gate must not turn this into a redirect or bypass extension cancellation.
  EXPECT_EQ("open", Attempt(page, 0,
      net::test_server::GetWebSocketURL(https_, "a.test", "/close?ignored-redirect")));
  // Native exceptions do not override extension cancellation.
  ASSERT_EQ(1, barc_blocker_set_tab_policy(work_id, barc_window_tab_at(work_id, 0), 1, "", 0));
  EXPECT_EQ("blocked", Attempt(page, 0, allowed));
}

namespace {
class HoldingNativeSocketClient final : public ChromeContentBrowserClient {
 public:
  void CheckWebSocketConnection(content::BrowserContext*, content::RenderFrameHost* frame,
      const GURL&, const url::Origin&, base::OnceCallback<void(int)> callback) override {
    ASSERT_TRUE(frame);  // An expired document must never arrive as a worker.
    pending = std::move(callback);
    seen.SetValue();
  }
  base::OnceCallback<void(int)> pending;
  base::test::TestFuture<void> seen;
};
}  // namespace

IN_PROC_BROWSER_TEST_F(BarcNativeWebSocketBrowserTest,
                       NativeWebSocketDeferredAdmissionCannotBorrowReplacementDocument) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  Navigate(work, https_.GetURL("a.test", "/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  const auto socket = net::test_server::GetWebSocketURL(https_, "a.test", "/stale-ws");
  HoldingNativeSocketClient client;
  {
    content::ScopedContentBrowserClientSetting setting(&client);
    ASSERT_TRUE(content::ExecJs(page, content::JsReplace("window.pendingSocket = new WebSocket($1);", socket)));
    ASSERT_TRUE(client.seen.Wait());
    const auto old = page->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    Navigate(work, https_.GetURL("a.test", "/title2.html"));
    ASSERT_TRUE(!old.AsRenderFrameHostIfValid() || !old.AsRenderFrameHostIfValid()->IsActive());
    std::move(client.pending).Run(net::OK);
  }
  EXPECT_EQ("open", Attempt(page, 0, socket));
  EXPECT_EQ(1, CountingNativeSocket::handshakes.load());
}

namespace {
class HoldingExtensionSocketClient final : public ChromeContentBrowserClient {
 public:
  bool WillInterceptWebSocket(content::RenderFrameHost*) override { return intercept; }
  void CreateWebSocket(content::RenderFrameHost*, WebSocketFactory factory,
      const GURL& url, const net::SiteForCookies&,
      const std::optional<std::string>&,
      mojo::PendingRemote<network::mojom::WebSocketHandshakeClient> client,
      WebSocketOptions options) override {
    pending_factory = std::move(factory);
    pending_url = url;
    pending_client = std::move(client);
    pending_header = std::move(options.header_client);
    seen.SetValue();
  }
  void CheckWebSocketConnection(content::BrowserContext* context, content::RenderFrameHost* frame,
      const GURL& url, const url::Origin& origin, base::OnceCallback<void(int)> callback) override {
    ++checks;
    ChromeContentBrowserClient::CheckWebSocketConnection(context, frame, url, origin, std::move(callback));
  }
  bool intercept = true;
  int checks = 0;
  WebSocketFactory pending_factory;
  GURL pending_url;
  mojo::PendingRemote<network::mojom::WebSocketHandshakeClient> pending_client;
  mojo::PendingRemote<network::mojom::TrustedHeaderClient> pending_header;
  base::test::TestFuture<void> seen;
};
}  // namespace
IN_PROC_BROWSER_TEST_F(BarcNativeWebSocketBrowserTest,
                       NativeWebSocketExpiredExtensionFactoryNeverBecomesWorkerRequest) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  Navigate(work, https_.GetURL("a.test", "/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  const auto socket = net::test_server::GetWebSocketURL(https_, "a.test", "/stale-ws");
  HoldingExtensionSocketClient client;
  {
    content::ScopedContentBrowserClientSetting setting(&client);
    ASSERT_TRUE(content::ExecJs(page, content::JsReplace("window.pendingSocket = new WebSocket($1);", socket)));
    ASSERT_TRUE(client.seen.Wait());
    Navigate(work, https_.GetURL("a.test", "/title2.html"));
    client.intercept = false;
    std::move(client.pending_factory).Run(client.pending_url, {},
        std::move(client.pending_client), mojo::NullRemote(), std::move(client.pending_header));
    EXPECT_EQ(0, client.checks);
  }
  EXPECT_EQ("open", Attempt(page, 0, socket));
  EXPECT_EQ(1, CountingNativeSocket::handshakes.load());
}

IN_PROC_BROWSER_TEST_F(BarcNativeWebSocketBrowserTest,
                       NativeWebSocketCancelledHandshakeCannotStartAfterPolicyReply) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  Navigate(work, https_.GetURL("a.test", "/title1.html"));
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  const auto socket = net::test_server::GetWebSocketURL(https_, "a.test", "/stale-ws");
  HoldingNativeSocketClient client;
  {
    content::ScopedContentBrowserClientSetting setting(&client);
    ASSERT_TRUE(content::ExecJs(page, content::JsReplace("window.pendingSocket = new WebSocket($1);", socket)));
    ASSERT_TRUE(client.seen.Wait());
    ASSERT_EQ("closed", content::EvalJs(page, R"(
      new Promise(resolve => {
        pendingSocket.onclose = () => resolve('closed');
        pendingSocket.close();
      })
    )"));
    std::move(client.pending).Run(net::OK);
  }
  EXPECT_EQ("open", Attempt(page, 0, socket));
  EXPECT_EQ(1, CountingNativeSocket::handshakes.load());
}

namespace {
struct VaultFocusEvents {
  uint64_t observation = 0;
  uint64_t focus = 0;
  int kind = -1;
  std::string origin;
  int cancelled = 0;
  __weak NSView* view = nil;
  static void Tab(void*, uint64_t, int32_t, int32_t, int32_t,
                  const char*, const char*, int32_t, uint32_t) {}
  static void Focus(void* context, uint64_t observation, uint64_t focus,
      const char* origin, int32_t kind, void* view, double, double, double width, double height) {
    auto* events = static_cast<VaultFocusEvents*>(context);
    EXPECT_EQ(events->observation, observation);
    events->focus = focus;
    if (!focus) { ++events->cancelled; return; }
    EXPECT_TRUE(view);
    EXPECT_GT(width, 0);
    EXPECT_GT(height, 0);
    events->kind = kind;
    events->origin = origin;
    events->view = (__bridge NSView*)view;
  }
};
std::unique_ptr<net::test_server::HttpResponse> VaultForm(
    const net::test_server::HttpRequest& request) {
  if (request.relative_url != "/vault-form") return nullptr;
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_content_type("text/html");
  response->set_content("<form><input id=u autocomplete=username>"
      "<input id=p type=password autocomplete=current-password>"
      "<input id=otp autocomplete=one-time-code></form><button id=blur>Leave</button>");
  return response;
}
}  // namespace

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, VaultFocusedPasswordAndOtpUseTypedFieldCapabilities) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&VaultForm));
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL url = embedded_test_server()->GetURL("/vault-form");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), url));
  auto* contents = browser()->tab_strip_model()->GetActiveWebContents();
  const int32_t window = browser()->GetSessionID().id();
  VaultFocusEvents events;
  events.observation = barc_tab_observe(window, barc_window_tab_at(window, 0), VaultFocusEvents::Tab, &events);
  ASSERT_NE(0u, events.observation);
  base::ScopedClosureRunner stop(base::BindOnce([](uint64_t token) { barc_tab_unobserve(token); }, events.observation));
  ASSERT_EQ(1, barc_tab_observe_vault(events.observation, VaultFocusEvents::Focus));
  contents->Focus();
  content::SimulateMouseClickOrTapElementWithId(contents, "p");
  ASSERT_TRUE(base::test::RunUntil([&] { return events.focus != 0; }));
  EXPECT_EQ(url::Origin::Create(url).Serialize(), events.origin);
  EXPECT_EQ(0, events.kind);
  const uint64_t password = events.focus;
  ASSERT_EQ(1, barc_tab_vault_focus_is_current(events.observation, password));
  ASSERT_EQ(1, barc_tab_fill_vault(events.observation, password, "synthetic-user", "synthetic-password"));
  EXPECT_EQ(0, barc_tab_fill_vault(events.observation, password, "wrong", "replayed"));
  EXPECT_EQ("synthetic-user:synthetic-password", content::EvalJs(contents, "u.value+':'+p.value"));
  content::SimulateMouseClickOrTapElementWithId(contents, "otp");
  ASSERT_TRUE(base::test::RunUntil([&] { return events.focus != password && events.kind == 1; }));
  ASSERT_EQ(1, barc_tab_fill_vault(events.observation, events.focus, "", "123456"));
  EXPECT_EQ("123456", content::EvalJs(contents, "otp.value"));
  ASSERT_EQ(1, barc_tab_observe_vault(events.observation, nullptr));
  content::SimulateMouseClickOrTapElementWithId(contents, "p");
  content::RunAllTasksUntilIdle();
  EXPECT_EQ(0, barc_tab_vault_focus_is_current(events.observation, password));
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, VaultFieldCapabilityEndsOnBlurNavigationAndUnobserve) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&VaultForm));
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), embedded_test_server()->GetURL("/vault-form")));
  auto* contents = browser()->tab_strip_model()->GetActiveWebContents();
  const int32_t window = browser()->GetSessionID().id();
  VaultFocusEvents events;
  events.observation = barc_tab_observe(window, barc_window_tab_at(window, 0), VaultFocusEvents::Tab, &events);
  ASSERT_NE(0u, events.observation);
  base::ScopedClosureRunner stop(base::BindOnce([](uint64_t token) { barc_tab_unobserve(token); }, events.observation));
  ASSERT_EQ(1, barc_tab_observe_vault(events.observation, VaultFocusEvents::Focus));
  contents->Focus();
  content::SimulateMouseClickOrTapElementWithId(contents, "p");
  ASSERT_TRUE(base::test::RunUntil([&] { return events.focus != 0; }));
  const uint64_t first = events.focus;
  content::SimulateMouseClickOrTapElementWithId(contents, "blur");
  ASSERT_TRUE(base::test::RunUntil([&] { return events.focus == 0; }));
  EXPECT_EQ(0, barc_tab_fill_vault(events.observation, first, "old", "old"));
  content::SimulateMouseClickOrTapElementWithId(contents, "p");
  ASSERT_TRUE(base::test::RunUntil([&] { return events.focus != 0; }));
  const uint64_t second = events.focus;
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), embedded_test_server()->GetURL("/title1.html")));
  EXPECT_EQ(0, barc_tab_vault_focus_is_current(events.observation, second));
  EXPECT_EQ(0, barc_tab_fill_vault(events.observation, second, "old", "old"));
  barc_tab_unobserve(events.observation);
  EXPECT_EQ(0, barc_tab_observe_vault(events.observation, VaultFocusEvents::Focus));
  EXPECT_EQ(0, barc_tab_fill_vault(events.observation, second, "old", "old"));
}


IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, VaultOwnedPickerNeedsRestoredNativeFocusAndCancellationCannotRevive) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&VaultForm));
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), embedded_test_server()->GetURL("/vault-form")));
  auto* contents = browser()->tab_strip_model()->GetActiveWebContents();
  const int32_t window = browser()->GetSessionID().id();
  VaultFocusEvents events;
  events.observation = barc_tab_observe(window, barc_window_tab_at(window, 0), VaultFocusEvents::Tab, &events);
  ASSERT_NE(0u, events.observation);
  base::ScopedClosureRunner stop(base::BindOnce([](uint64_t token) { barc_tab_unobserve(token); }, events.observation));
  ASSERT_EQ(1, barc_tab_observe_vault(events.observation, VaultFocusEvents::Focus));
  contents->Focus();
  content::SimulateMouseClickOrTapElementWithId(contents, "p");
  ASSERT_TRUE(base::test::RunUntil([&] { return events.focus != 0; }));
  const uint64_t focus = events.focus;
  NSView* original = events.view;
  NSWindow* owner = original.window;
  ASSERT_TRUE(owner);
  NSPopover* picker = [[NSPopover alloc] init];
  picker.behavior = NSPopoverBehaviorTransient;
  NSViewController* controller = [[NSViewController alloc] init];
  controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 180, 80)];
  picker.contentViewController = controller;
  [picker showRelativeToRect:NSMakeRect(5, 5, 10, 10) ofView:original preferredEdge:NSMaxYEdge];
  [controller.view.window makeKeyWindow];
  ASSERT_TRUE(base::test::RunUntil([&] { return !barc_tab_vault_focus_is_current(events.observation, focus); }));
  EXPECT_EQ(1, barc_tab_vault_field_is_current(events.observation, focus));
  EXPECT_EQ(0, barc_tab_fill_vault(events.observation, focus, "wrong", "unfocused"));
  // Models only the exact picker user's direct choice. No RPC restores focus.
  [picker close];
  [owner makeKeyWindow];
  ASSERT_TRUE([owner makeFirstResponder:original]);
  ASSERT_TRUE(base::test::RunUntil([&] { return barc_tab_vault_focus_is_current(events.observation, focus); }));
  ASSERT_EQ(1, barc_tab_fill_vault(events.observation, focus, "synthetic-user", "synthetic-password"));
  EXPECT_EQ("synthetic-password", content::EvalJs(contents, "p.value"));
  content::SimulateMouseClickOrTapElementWithId(contents, "otp");
  ASSERT_TRUE(base::test::RunUntil([&] { return events.focus != 0 && events.focus != focus; }));
  const uint64_t cancelled = events.focus;
  ASSERT_EQ(1, barc_tab_cancel_vault_focus(events.observation, cancelled));
  contents->Focus();
  EXPECT_EQ(0, barc_tab_vault_field_is_current(events.observation, cancelled));
  EXPECT_EQ(0, barc_tab_fill_vault(events.observation, cancelled, "", "654321"));
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, VaultFrameOriginAndFieldIdsNeverRetargetParent) {
  net::EmbeddedTestServer child_server;
  child_server.RegisterRequestHandler(base::BindRepeating(&VaultForm));
  ASSERT_TRUE(child_server.Start());
  const GURL child_url = child_server.GetURL("/vault-form");
  embedded_test_server()->RegisterRequestHandler(base::BindLambdaForTesting(
      [child_url](const net::test_server::HttpRequest& request) -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/vault-parent") return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_content_type("text/html");
        response->set_content("<form><input id=u autocomplete=username><input id=p type=password autocomplete=current-password></form>"
            "<iframe src='" + child_url.spec() + "'></iframe>");
        return response;
      }));
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), embedded_test_server()->GetURL("/vault-parent")));
  auto* contents = browser()->tab_strip_model()->GetActiveWebContents();
  auto* child = content::ChildFrameAt(contents->GetPrimaryMainFrame(), 0);
  ASSERT_TRUE(child);
  const int32_t window = browser()->GetSessionID().id();
  VaultFocusEvents events;
  events.observation = barc_tab_observe(window, barc_window_tab_at(window, 0), VaultFocusEvents::Tab, &events);
  ASSERT_NE(0u, events.observation);
  base::ScopedClosureRunner stop(base::BindOnce([](uint64_t token) { barc_tab_unobserve(token); }, events.observation));
  ASSERT_EQ(1, barc_tab_observe_vault(events.observation, VaultFocusEvents::Focus));
  contents->Focus();
  ASSERT_TRUE(content::ExecJs(child, "p.focus()"));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.focus != 0; }));
  EXPECT_EQ(url::Origin::Create(child_url).Serialize(), events.origin);
  const uint64_t child_focus = events.focus;
  ASSERT_EQ(1, barc_tab_fill_vault(events.observation, child_focus, "child-user", "child-password"));
  EXPECT_EQ("child-user:child-password", content::EvalJs(child, "u.value+':'+p.value"));
  EXPECT_EQ(":", content::EvalJs(contents, "u.value+':'+p.value"));
  ASSERT_TRUE(content::ExecJs(contents, "p.focus()"));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.focus != 0 && events.focus != child_focus; }));
  const uint64_t parent_focus = events.focus;
  EXPECT_EQ(0, barc_tab_cancel_vault_focus(events.observation, child_focus));
  EXPECT_EQ(1, barc_tab_vault_focus_is_current(events.observation, parent_focus));
  EXPECT_EQ(0, barc_tab_fill_vault(events.observation, child_focus, "wrong", "wrong"));
  EXPECT_EQ(":", content::EvalJs(contents, "u.value+':'+p.value"));
}

namespace {
struct VaultSaveEvents {
  uint64_t observation = 0, submission = 0;
  int offers = 0;
  std::string origin, username;
  static void Tab(void*, uint64_t, int32_t, int32_t, int32_t,
                  const char*, const char*, int32_t, uint32_t) {}
  static void Save(void* pointer, uint64_t observation, uint64_t submission,
                   const char* origin, const char* username, const char*, void*) {
    auto& events = *static_cast<VaultSaveEvents*>(pointer);
    EXPECT_EQ(events.observation, observation);
    events.submission = submission;
    if (submission) {
      ++events.offers;
      events.origin = origin;
      events.username = username;
    }
  }
};
std::unique_ptr<password_manager::PasswordFormManagerForUI> VaultFormManager(
    const password_manager::PasswordForm& credentials) {
  auto manager = std::make_unique<testing::NiceMock<password_manager::MockPasswordFormManagerForUI>>();
  ON_CALL(*manager, GetPendingCredentials()).WillByDefault(testing::ReturnRefOfCopy(credentials));
  ON_CALL(*manager, GetURL()).WillByDefault(testing::ReturnRefOfCopy(credentials.url));
  ON_CALL(*manager, IsFetchCompleted()).WillByDefault(testing::Return(true));
  ON_CALL(*manager, GetBestMatches()).WillByDefault(testing::Return(base::span<const password_manager::StoredCredential>()));
  ON_CALL(*manager, GetFederatedMatches()).WillByDefault(testing::Return(base::span<const password_manager::StoredCredential>()));
  ON_CALL(*manager, GetInteractionsStats()).WillByDefault(testing::Return(base::span<const password_manager::InteractionsStats>()));
  ON_CALL(*manager, GetInsecureCredentials()).WillByDefault(testing::Return(base::span<const password_manager::StoredCredential>()));
  return manager;
}
}  // namespace

// Exercise the production ChromePasswordManagerClient save/update admission,
// not the Barc helper. Chromium's UI-manager object represents the accepted
// submission; its original origin must survive the completed login redirect.
IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, VaultSaveAdmissionOwnsOnePromptAcrossRedirectAndReplacement) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL login = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),login));
  auto* contents = browser()->tab_strip_model()->GetActiveWebContents();
  auto* client = ChromePasswordManagerClient::FromWebContents(contents);
  auto* ui = ManagePasswordsUIController::FromWebContents(contents);
  ASSERT_TRUE(client && ui);
  const auto original_state = ui->GetState();
  VaultSaveEvents events;
  const int32_t window = browser()->GetSessionID().id();
  events.observation = barc_tab_observe(window,barc_window_tab_at(window,0),VaultSaveEvents::Tab,&events);
  ASSERT_NE(0u,events.observation);
  base::ScopedClosureRunner stop(base::BindOnce([](uint64_t token) { barc_tab_unobserve(token); },events.observation));
  ASSERT_EQ(1,barc_tab_observe_vault_save(events.observation,VaultSaveEvents::Save));
  password_manager::PasswordForm credentials;
  credentials.url = login;
  credentials.username_value = u"synthetic-user";
  credentials.password_value = password_manager::PasswordString(std::u16string(u"synthetic-password"));
  // Successful redirects are already complete when normal save admission runs.
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),embedded_test_server()->GetURL("/title2.html")));
  ASSERT_TRUE(client->PromptUserToSaveOrUpdatePassword(VaultFormManager(credentials),false));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.offers == 1; }));
  EXPECT_EQ(url::Origin::Create(login).Serialize(),events.origin);
  EXPECT_EQ("synthetic-user",events.username);
  EXPECT_EQ(original_state,ui->GetState());  // No stock prompt alongside Pawl.
  const uint64_t first = events.submission;
  ASSERT_EQ(1,barc_tab_vault_save_is_current(events.observation,first));
  ASSERT_TRUE(client->PromptUserToSaveOrUpdatePassword(VaultFormManager(credentials),true));
  EXPECT_EQ(0,barc_tab_vault_save_is_current(events.observation,first));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.offers == 2; }));
  const uint64_t second = events.submission;
  EXPECT_NE(first,second);
  EXPECT_EQ(original_state,ui->GetState());
  EXPECT_EQ(0,barc_tab_cancel_vault_save(events.observation,first));
  // A refused newer submission must retire the still-active Pawl offer before
  // entering Chrome's fallback, leaving no second valid save prompt.
  credentials.username_value.clear();
  ASSERT_TRUE(client->PromptUserToSaveOrUpdatePassword(VaultFormManager(credentials),false));
  EXPECT_EQ(0,barc_tab_vault_save_is_current(events.observation,second));
  EXPECT_EQ(0,barc_tab_cancel_vault_save(events.observation,second));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.submission == 0; }));
  EXPECT_EQ(2,events.offers);  // Clear+replacement notifications are coalesced.
  EXPECT_EQ(password_manager::ui::PENDING_PASSWORD_STATE,ui->GetState());
  credentials.username_value = u"synthetic-user";
  // Disconnected/disabled consumer unregisters; normal Chromium retains its UI.
  ASSERT_EQ(1,barc_tab_observe_vault_save(events.observation,nullptr));
  ASSERT_TRUE(client->PromptUserToSaveOrUpdatePassword(VaultFormManager(credentials),false));
  EXPECT_EQ(password_manager::ui::PENDING_PASSWORD_STATE,ui->GetState());
  EXPECT_EQ(2,events.offers);
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, VaultSaveOwnerTransferRetiresSubmissionAndInvalidOriginFallsBack) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),embedded_test_server()->GetURL("/title1.html")));
  auto* contents = browser()->tab_strip_model()->GetActiveWebContents();
  auto* client = ChromePasswordManagerClient::FromWebContents(contents);
  VaultSaveEvents events;
  const int32_t window = browser()->GetSessionID().id();
  const int32_t tab = barc_window_tab_at(window,0);
  events.observation = barc_tab_observe(window,tab,VaultSaveEvents::Tab,&events);
  ASSERT_NE(0u,events.observation);
  base::ScopedClosureRunner stop(base::BindOnce([](uint64_t token) { barc_tab_unobserve(token); },events.observation));
  ASSERT_EQ(1,barc_tab_observe_vault_save(events.observation,VaultSaveEvents::Save));
  password_manager::PasswordForm credentials;
  credentials.url = embedded_test_server()->GetURL("/title1.html");
  credentials.username_value = u"synthetic-user";
  credentials.password_value = password_manager::PasswordString(std::u16string(u"synthetic-password"));
  ASSERT_TRUE(client->PromptUserToSaveOrUpdatePassword(VaultFormManager(credentials),false));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.submission != 0; }));
  const uint64_t serial = events.submission;
  auto* peer = CreateBrowser(browser()->GetProfile());
  ASSERT_EQ(1,barc_tab_transfer(window,tab,peer->GetSessionID().id()));
  EXPECT_EQ(0,barc_tab_vault_save_is_current(events.observation,serial));
  // Invalid privileged submission origin cannot become a Pawl save even if a
  // Chromium UI-manager was supplied. The unchanged stock branch remains owner.
  credentials.url = GURL("chrome://settings/");
  ASSERT_TRUE(client->PromptUserToSaveOrUpdatePassword(VaultFormManager(credentials),false));
  EXPECT_EQ(0,barc_tab_vault_save_is_current(events.observation,serial));
  const int offers = events.offers;
  credentials.url = embedded_test_server()->GetURL("/title1.html");
  credentials.username_value = std::u16string({u'a',u'\0',u'b'});
  ASSERT_TRUE(client->PromptUserToSaveOrUpdatePassword(VaultFormManager(credentials),false));
  credentials.username_value = u"synthetic-user";
  credentials.password_value = password_manager::PasswordString(std::u16string({u'a',u'\0',u'b'}));
  ASSERT_TRUE(client->PromptUserToSaveOrUpdatePassword(VaultFormManager(credentials),false));
  credentials.password_value = password_manager::PasswordString(std::u16string(65537,u'x'));
  ASSERT_TRUE(client->PromptUserToSaveOrUpdatePassword(VaultFormManager(credentials),false));
  credentials.password_value = password_manager::PasswordString(std::u16string(u"synthetic-password"));
  credentials.username_value = std::u16string(65537,u'x');
  ASSERT_TRUE(client->PromptUserToSaveOrUpdatePassword(VaultFormManager(credentials),false));
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(offers,events.offers);
  EXPECT_EQ(password_manager::ui::PENDING_PASSWORD_STATE,
      ManagePasswordsUIController::FromWebContents(contents)->GetState());
}


namespace {
std::string FixedTweaksConfig(std::string css, bool facebook, bool reddit,
    const std::vector<std::pair<std::string, std::string>>& scripts = {}) {
  base::DictValue value, youtube;
  value.Set("version", 1);
  youtube.Set("css", std::move(css));
  youtube.Set("frameThumbnails", false); youtube.Set("noHoverPreview", false);
  value.Set("youtube", std::move(youtube));
  value.Set("facebookReels", facebook); value.Set("facebookSuggested", facebook);
  value.Set("redditHot", reddit);
  base::ListValue entries;
  for (const auto& [host, source] : scripts) {
    base::DictValue script;
    script.Set("host", host); script.Set("includeSubdomains", false); script.Set("source", source);
    entries.Append(std::move(script));
  }
  value.Set("scripts", std::move(entries));
  return base::WriteJson(value).value();
}
int PublishFixedTweaks(const std::string& config) {
  return barc_page_tweaks_publish(reinterpret_cast<const uint8_t*>(config.data()), config.size());
}
void ConfigureFixedTweaksHTTPS(net::EmbeddedTestServer* server) {
  // These real hostnames are part of the production host-matching contract.
  // Their HSTS preloads require TLS even on a loopback fixture port. Generate
  // matching SANs under EmbeddedTestServer's normally verified test root.
  server->SetCertHostnames({"www.facebook.com", "www.youtube.com", "m.youtube.com",
      "www.reddit.com", "notfacebook.com", "other.test", "scripts.test", "away.test"});
  server->ServeFilesFromSourceDirectory("chrome/test/data");
}
void RegisterFixedTweaksDocument(net::EmbeddedTestServer* server) {
  server->RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request) -> std::unique_ptr<net::test_server::HttpResponse> {
        if (!request.relative_url.starts_with("/fixed-tweaks")) return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK); response->set_content_type("text/html");
        if (request.relative_url == "/fixed-tweaks-sandbox")
          response->AddCustomHeader("Content-Security-Policy", "sandbox allow-same-origin");
        response->set_content(R"(
          <!doctype html><title>fixed tweaks</title><div id=native-youtube-probe>visible</div>
          <input id=draft value=original>
          <script>
          window.firstInlineFacebook=window.__nookFBPrune===true;
          window.firstInlineYoutube=getComputedStyle(document.querySelector('#native-youtube-probe')).display;
          window.filteredEdges=JSON.parse(JSON.stringify({data:{viewer:{news_feed:{edges:[
            {node:{__typename:'ShowcaseFeedUnit'}},{node:{__typename:'Story'}}]}}}})).data.viewer.news_feed.edges.length;
          window.documentIdentity=crypto.randomUUID();
          </script>)");
        return response;
      }));
}
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       FixedPageTweaksRunBeforeInlineWithoutBlockerAndRespectFrameHost) {
  net::EmbeddedTestServer fixture_server(net::EmbeddedTestServer::TYPE_HTTPS);
  ConfigureFixedTweaksHTTPS(&fixture_server);
  RegisterFixedTweaksDocument(&fixture_server);
  ASSERT_TRUE(fixture_server.Start());
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  const auto config = FixedTweaksConfig("#native-youtube-probe{display:none!important}", true, true);
  ASSERT_EQ(1, PublishFixedTweaks(config));
  const int32_t window = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* owner = SharedWindow(window);
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("www.facebook.com", "/fixed-tweaks")));
  auto* page = owner->GetTabStripModel()->GetActiveWebContents();
  EXPECT_EQ(true, content::EvalJs(page, "firstInlineFacebook"));
  EXPECT_EQ(1, content::EvalJs(page, "filteredEdges"));
  ASSERT_TRUE(content::ExecJs(page, content::JsReplace(R"(
    new Promise(resolve=>{const f=document.createElement('iframe');f.onload=()=>resolve(true);f.src=$1;document.body.append(f);})
  )", fixture_server.GetURL("www.facebook.com", "/fixed-tweaks-child"))));
  auto* child = content::ChildFrameAt(page->GetPrimaryMainFrame(), 0);
  ASSERT_TRUE(child);
  EXPECT_EQ(false, content::EvalJs(child, "firstInlineFacebook"));
  EXPECT_EQ(2, content::EvalJs(child, "filteredEdges"));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("notfacebook.com", "/fixed-tweaks")));
  EXPECT_EQ(false, content::EvalJs(page, "firstInlineFacebook"));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("www.youtube.com", "/fixed-tweaks")));
  EXPECT_EQ("none", content::EvalJs(page, "firstInlineYoutube"));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("m.youtube.com", "/fixed-tweaks")));
  EXPECT_EQ("block", content::EvalJs(page, "firstInlineYoutube"));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("www.reddit.com", "/fixed-tweaks")));
  EXPECT_EQ("/r/example/hot/?sort=keep#section", content::EvalJs(page, R"(
    (()=>{const a=document.createElement('a');a.href='/r/example/?sort=keep#section';document.body.append(a);
    document.addEventListener('click',e=>e.preventDefault(),{once:true});a.click();return new URL(a.href).pathname+new URL(a.href).search+new URL(a.href).hash;})()
  )"));
  ASSERT_EQ(1, barc_page_tweaks_publish(nullptr, 0));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("www.facebook.com", "/fixed-tweaks")));
  EXPECT_EQ(false, content::EvalJs(page, "firstInlineFacebook"));
  EXPECT_EQ(2, content::EvalJs(page, "filteredEdges"));
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       OptInBoostAsyncBodiesAreSequentialIsolatedAndErrorsDoNotStopLaterScripts) {
  net::EmbeddedTestServer fixture_server(net::EmbeddedTestServer::TYPE_HTTPS);
  ConfigureFixedTweaksHTTPS(&fixture_server);
  RegisterFixedTweaksDocument(&fixture_server);
  ASSERT_TRUE(fixture_server.Start());
  const auto config = FixedTweaksConfig("", true, false, {
    {"www.facebook.com", "document.body.dataset.order='first';document.title='boost-awaiting';await new Promise(r=>document.addEventListener('fixture-release',r,{once:true}));document.body.dataset.order+='-awaited';return 1;"},
    {"www.facebook.com", "document.body.dataset.order+='-second';throw Error('expected test error');"},
    {"www.facebook.com", "document.body.dataset.order+='-third';document.body.dataset.world=typeof window.__nookFBFilter+':'+typeof globalThis.nookScriptSink;document.title='boost-finished';"}
  });
  ASSERT_EQ(1, PublishFixedTweaks(config));
  const int32_t window = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* owner = SharedWindow(window);
  auto* page = owner->GetTabStripModel()->GetActiveWebContents();
  content::TitleWatcher awaiting(page, u"boost-awaiting");
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("www.facebook.com", "/fixed-tweaks")));
  ASSERT_EQ(u"boost-awaiting", awaiting.WaitAndGetTitle());
  EXPECT_EQ("first", content::EvalJs(page, "document.body.dataset.order"));
  EXPECT_EQ(true, content::EvalJs(page, "firstInlineFacebook"));
  content::TitleWatcher finished(page, u"boost-finished");
  ASSERT_TRUE(content::ExecJs(page, "document.dispatchEvent(new Event('fixture-release'));"));
  ASSERT_EQ(u"boost-finished", finished.WaitAndGetTitle());
  EXPECT_EQ("first-awaited-second-third", content::EvalJs(page, "document.body.dataset.order"));
  EXPECT_EQ("undefined:undefined", content::EvalJs(page, "document.body.dataset.world"));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("other.test", "/fixed-tweaks")));
  EXPECT_EQ("undefined", content::EvalJs(page, "typeof document.body.dataset.order"));
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       FixedTweaksKeepUnrelatedAndEquivalentHistoryButRetireMaterialSource) {
  net::EmbeddedTestServer fixture_server(net::EmbeddedTestServer::TYPE_HTTPS);
  ConfigureFixedTweaksHTTPS(&fixture_server);
  RegisterFixedTweaksDocument(&fixture_server);
  ASSERT_TRUE(fixture_server.Start());
  const std::string source = "sessionStorage.nativeBoostRuns=String(1+Number(sessionStorage.nativeBoostRuns||0));document.body.dataset.runs=String(1+Number(document.body.dataset.runs||0));document.title='boost-once';";
  const auto config = FixedTweaksConfig("", false, false, {{"scripts.test", source}});
  ASSERT_EQ(1, PublishFixedTweaks(config));
  const int32_t window = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* owner = SharedWindow(window);
  auto* page = owner->GetTabStripModel()->GetActiveWebContents();
  content::TitleWatcher first(page, u"boost-once");
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("scripts.test", "/fixed-tweaks")));
  ASSERT_EQ(u"boost-once", first.WaitAndGetTitle());
  ASSERT_TRUE(content::ExecJs(page, "document.querySelector('#draft').value='live-draft';"));
  const auto identity_result = content::EvalJs(page, "documentIdentity");
  ASSERT_TRUE(identity_result.is_string()) << identity_result;
  const std::string identity = identity_result.ExtractString();
  auto document = page->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("away.test", "/title1.html")));
  auto* cached = document.AsRenderFrameHostIfValid();
  ASSERT_TRUE(cached);
  ASSERT_EQ(content::RenderFrameHost::LifecycleState::kInBackForwardCache, cached->GetLifecycleState());
  EXPECT_EQ(1, PublishFixedTweaks(config));
  EXPECT_EQ(1, PublishFixedTweaks(FixedTweaksConfig("body{color:red}", true, true, {{"scripts.test", source}})));
  EXPECT_EQ(cached, document.AsRenderFrameHostIfValid());
  content::TestNavigationObserver restored(page);page->GetController().GoBack();restored.Wait();
  EXPECT_EQ(cached, page->GetPrimaryMainFrame());
  EXPECT_EQ(identity, content::EvalJs(page, "documentIdentity"));
  EXPECT_EQ("live-draft", content::EvalJs(page, "document.querySelector('#draft').value"));
  EXPECT_EQ("1", content::EvalJs(page, "document.body.dataset.runs"));
  // document.open replaces the DOM but retains this document identity. Its
  // load completion must not rerun an already-consumed Boost chain.
  const auto token_before_open = page->GetPrimaryMainFrame()->GetDocumentToken();
  ASSERT_TRUE(content::ExecJs(page, "document.open();document.write('<title>opened document</title><input id=draft>');document.close();"));
  EXPECT_EQ(token_before_open, page->GetPrimaryMainFrame()->GetDocumentToken());
  EXPECT_EQ("1", content::EvalJs(page, "sessionStorage.nativeBoostRuns"));
  ASSERT_EQ(1, PublishFixedTweaks(FixedTweaksConfig("", false, false,
      {{"scripts.test", "document.body.dataset.runs='new-source';document.title='boost-new';"}})));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("away.test", "/title1.html")));
  EXPECT_FALSE(document.AsRenderFrameHostIfValid());
  content::TitleWatcher changed(page, u"boost-new");
  content::TestNavigationObserver replaced(page);page->GetController().GoBack();replaced.Wait();
  ASSERT_EQ(u"boost-new", changed.WaitAndGetTitle());
  EXPECT_EQ("new-source", content::EvalJs(page, "document.body.dataset.runs"));
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       FixedTweaksRespectScriptPolicyAndFrozenSourceRevocation) {
  net::EmbeddedTestServer fixture_server(net::EmbeddedTestServer::TYPE_HTTPS);
  ConfigureFixedTweaksHTTPS(&fixture_server);
  RegisterFixedTweaksDocument(&fixture_server);
  ASSERT_TRUE(fixture_server.Start());
  const auto config = FixedTweaksConfig("", true, false, {
    {"scripts.test", "document.title='boost-suspended';await new Promise(r=>document.addEventListener('fixture-release',r,{once:true}));document.title='old-body-finished';"},
    {"scripts.test", "document.body.dataset.forbidden='stale-continuation';"}
  });
  ASSERT_EQ(1, PublishFixedTweaks(config));
  const int32_t window = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* owner = SharedWindow(window);
  auto* page = owner->GetTabStripModel()->GetActiveWebContents();
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("scripts.test", "/fixed-tweaks-sandbox")));
  EXPECT_EQ("undefined", content::EvalJs(page, "typeof document.body.dataset.forbidden"));
  auto* settings = HostContentSettingsMapFactory::GetForProfile(owner->GetProfile());
  settings->SetDefaultContentSetting(ContentSettingsType::JAVASCRIPT, CONTENT_SETTING_BLOCK);
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("www.facebook.com", "/fixed-tweaks")));
  EXPECT_EQ("undefined", content::EvalJs(page, "typeof window.__nookFBPrune"));
  settings->SetDefaultContentSetting(ContentSettingsType::JAVASCRIPT, CONTENT_SETTING_ALLOW);
  content::TitleWatcher suspended(page, u"boost-suspended");
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("scripts.test", "/fixed-tweaks")));
  ASSERT_EQ(u"boost-suspended", suspended.WaitAndGetTitle());
  content::DOMMessageQueue lifecycle(page);
  ASSERT_TRUE(content::ExecJs(page, "document.addEventListener('freeze',()=>domAutomationController.send('frozen'));document.addEventListener('resume',()=>domAutomationController.send('resumed'));"));
  const int32_t peer = Open(kSharedPersonal, window, BARC_PROFILE_BLANK);
  ASSERT_EQ(1, barc_window_select(peer));
  page->SetPageFrozen(true);
  std::string message;
  ASSERT_TRUE(lifecycle.WaitForMessage(&message));EXPECT_EQ("\"frozen\"", message);
  // Invalid publication must revoke old permission, not keep the old source.
  const std::string invalid = "{}";
  ASSERT_EQ(0, PublishFixedTweaks(invalid));
  page->SetPageFrozen(false);
  ASSERT_TRUE(lifecycle.WaitForMessage(&message));EXPECT_EQ("\"resumed\"", message);
  content::TitleWatcher old_finished(page, u"old-body-finished");
  ASSERT_TRUE(content::ExecJs(page, "document.dispatchEvent(new Event('fixture-release'));"));
  ASSERT_EQ(u"old-body-finished", old_finished.WaitAndGetTitle());
  EXPECT_EQ("undefined", content::EvalJs(page, "typeof document.body.dataset.forbidden"));
  ASSERT_EQ(1, barc_window_select(window));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("scripts.test", "/fixed-tweaks")));
  EXPECT_EQ("fixed tweaks", content::EvalJs(page, "document.title"));
}


IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       BlockerResetKeepsIndependentTweakRevocationReceiver) {
  net::EmbeddedTestServer fixture_server(net::EmbeddedTestServer::TYPE_HTTPS);
  ConfigureFixedTweaksHTTPS(&fixture_server);
  RegisterFixedTweaksDocument(&fixture_server);
  ASSERT_TRUE(fixture_server.Start());
  ASSERT_EQ(1, PublishFixedTweaks(FixedTweaksConfig("", true, false, {
    {"www.facebook.com", "document.title='boost-waiting';await new Promise(r=>document.addEventListener('fixture-release',r,{once:true}));document.title='old-boost-completed';"},
    {"www.facebook.com", "document.body.dataset.forbidden='revoked';"}
  })));
  const int32_t window = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* owner = SharedWindow(window);
  InstallNativeBlocker(window, NativeCosmeticTestRules());
  auto* page = owner->GetTabStripModel()->GetActiveWebContents();
  content::TitleWatcher waiting(page, u"boost-waiting");
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("www.facebook.com", "/fixed-tweaks")));
  ASSERT_EQ(u"boost-waiting", waiting.WaitAndGetTitle());
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  // This round-trip orders the renderer cosmetic reset before independent
  // Boost removal; the document resource receiver must still observe it.
  EXPECT_EQ(true, content::EvalJs(page, "firstInlineFacebook"));
  ASSERT_EQ(1, PublishFixedTweaks(FixedTweaksConfig("", true, false)));
  content::TitleWatcher completed(page, u"old-boost-completed");
  ASSERT_TRUE(content::ExecJs(page, "document.dispatchEvent(new Event('fixture-release'));"));
  ASSERT_EQ(u"old-boost-completed", completed.WaitAndGetTitle());
  EXPECT_EQ("undefined", content::EvalJs(page, "typeof document.body.dataset.forbidden"));
  EXPECT_EQ(1, content::EvalJs(page, "JSON.parse(JSON.stringify({data:{viewer:{news_feed:{edges:[{node:{__typename:'ShowcaseFeedUnit'}},{node:{__typename:'Story'}}]}}}})).data.viewer.news_feed.edges.length"));
}


IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       RedditSortlessNavigationUsesOneInternalRedirect) {
  std::atomic<int> original_requests{0}, hot_requests{0};
  net::EmbeddedTestServer fixture_server(net::EmbeddedTestServer::TYPE_HTTPS);
  ConfigureFixedTweaksHTTPS(&fixture_server);
  fixture_server.RegisterRequestHandler(base::BindRepeating(
      [](std::atomic<int>* original, std::atomic<int>* hot,
         const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url == "/r/example/?keep=1") ++*original;
        else if (request.relative_url == "/r/example/hot/?keep=1") ++*hot;
        else return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK); response->set_content_type("text/html");
        response->set_content("<!doctype html><title>reddit navigation</title>");
        return response;
      }, &original_requests, &hot_requests));
  ASSERT_TRUE(fixture_server.Start());
  ASSERT_EQ(1, PublishFixedTweaks(FixedTweaksConfig("", false, true)));
  const int32_t window = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* owner = SharedWindow(window);
  const GURL input = fixture_server.GetURL("www.reddit.com", "/r/example/?keep=1#section");
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, input));
  auto* page = owner->GetTabStripModel()->GetActiveWebContents();
  EXPECT_EQ(fixture_server.GetURL("www.reddit.com", "/r/example/hot/?keep=1#section"), page->GetLastCommittedURL());
  EXPECT_EQ(0, original_requests.load()); EXPECT_EQ(1, hot_requests.load());
  ASSERT_EQ(1, barc_page_tweaks_publish(nullptr, 0));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, input));
  EXPECT_EQ(input, page->GetLastCommittedURL());
  EXPECT_EQ(1, original_requests.load()); EXPECT_EQ(1, hot_requests.load());
}

namespace {
std::string PawlEncode(base::span<const uint8_t> bytes) {
  std::string result;
  base::Base64UrlEncode(bytes,base::Base64UrlEncodePolicy::OMIT_PADDING,&result);
  return result;
}
struct PawlEvents {
  uint64_t observation = 0, request = 0;
  int operation = -1, requests = 0;
  std::string arguments;
  static void Tab(void*,uint64_t,int32_t,int32_t,int32_t,const char*,const char*,int32_t,uint32_t) {}
  static void Request(void* context,uint64_t observation,uint64_t request,int32_t operation,
                      const char* arguments,void*) {
    auto& self = *static_cast<PawlEvents*>(context);
    EXPECT_EQ(self.observation,observation);
    self.request = request;self.operation = operation;self.arguments = arguments;
    if (request) ++self.requests;
  }
};
class PawlDiscoveryObserver : public device::FidoDiscoveryBase::Observer {
 public:
  raw_ptr<device::FidoAuthenticator> authenticator = nullptr;
  bool started = false;
  void DiscoveryStarted(device::FidoDiscoveryBase*,bool success,
      std::vector<device::FidoAuthenticator*> authenticators) override {
    EXPECT_TRUE(success);ASSERT_EQ(1u,authenticators.size());authenticator = authenticators.front();started = true;
  }
  void AuthenticatorAdded(device::FidoDiscoveryBase*,device::FidoAuthenticator*) override {}
  void AuthenticatorRemoved(device::FidoDiscoveryBase*,device::FidoAuthenticator*) override {}
};
std::string PawlRegistrationReply(const std::string& rp) {
  // An upstream synthetic ES256 credential; none attestation needs no device
  // certificate or real vault. RP hash and UP+UV are explicit fixture inputs.
  auto raw = cbor::Reader::Read(base::span(device::test_data::kTestMakeCredentialResponse).subspan(1u));
  CHECK(raw && raw->is_map());
  auto auth = raw->GetMap().at(cbor::Value(2)).GetBytestring();
  const auto hash = crypto::hash::Sha256(rp);
  std::ranges::copy(hash,auth.begin());auth[32] |= 4;
  cbor::Value::MapValue object;
  object.emplace(cbor::Value("fmt"),cbor::Value("none"));
  object.emplace(cbor::Value("attStmt"),cbor::Value(cbor::Value::MapValue()));
  object.emplace(cbor::Value("authData"),cbor::Value(auth));
  auto attestation = device::AttestationObject::Parse(cbor::Value(object));CHECK(attestation);
  auto encoded = cbor::Writer::Write(cbor::Value(std::move(object)));CHECK(encoded);
  base::DictValue reply;
  reply.Set("credentialId",PawlEncode(attestation->GetCredentialId()));
  reply.Set("attestationObject",PawlEncode(*encoded));reply.Set("authenticatorData",PawlEncode(auth));
  reply.Set("publicKeyAlgorithm",-7);
  return *base::WriteJson(reply);
}
}  // namespace

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,PawlProviderMapsChromiumHashEs256AndAllowListResponses) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),embedded_test_server()->GetURL("/title1.html")));
  auto* contents = browser()->tab_strip_model()->GetActiveWebContents();
  auto* frame = contents->GetPrimaryMainFrame();
  const auto origin = frame->GetLastCommittedOrigin();const std::string rp = origin.host();
  EXPECT_FALSE(barc::CreateVaultPasskeyDiscovery(frame,origin,rp)); // Stock/disconnected path.
  PawlEvents events;
  const int32_t window = browser()->GetSessionID().id();
  events.observation = barc_tab_observe(window,barc_window_tab_at(window,0),PawlEvents::Tab,&events);
  ASSERT_NE(0u,events.observation);
  base::ScopedClosureRunner stop(base::BindOnce([](uint64_t token){barc_tab_unobserve(token);},events.observation));
  ASSERT_EQ(1,barc_tab_observe_vault_passkeys(events.observation,PawlEvents::Request));
  auto discovery = barc::CreateVaultPasskeyDiscovery(frame,origin,rp);ASSERT_TRUE(discovery);
  PawlDiscoveryObserver observer;discovery->set_observer(&observer);discovery->Start();
  ASSERT_TRUE(base::test::RunUntil([&]{return observer.started;}));
  auto* authenticator = observer.authenticator.get();ASSERT_TRUE(authenticator);
  EXPECT_EQ(std::string(barc::kPawlAuthenticatorId),authenticator->GetId());
  EXPECT_FALSE(authenticator->ShouldCheckPlatformCredentialStatus());
  bool initialized = false;authenticator->InitializeAuthenticator(base::BindLambdaForTesting([&]{initialized=true;}));
  ASSERT_TRUE(base::test::RunUntil([&]{return initialized;}));
  base::DictValue client;
  client.Set("type","webauthn.create");client.Set("challenge","AQ");client.Set("origin",origin.Serialize());
  const std::string client_data = *base::WriteJson(client);
  device::PublicKeyCredentialParams parameters({{device::CredentialType::kPublicKey,-7}});
  device::CtapMakeCredentialRequest make(client_data,device::PublicKeyCredentialRpEntity(rp),
      device::PublicKeyCredentialUserEntity({1},"synthetic-user","Synthetic"),std::move(parameters));
  device::MakeCredentialOptions make_options;
  std::optional<device::MakeCredentialStatus> make_status;
  std::optional<device::AuthenticatorMakeCredentialResponse> created;
  authenticator->MakeCredential(make,make_options,base::BindLambdaForTesting([&](device::MakeCredentialStatus status,std::optional<device::AuthenticatorMakeCredentialResponse> response){
    make_status=status;created=std::move(response);
  }));
  ASSERT_TRUE(base::test::RunUntil([&]{return events.request!=0;}));
  auto args = base::JSONReader::ReadDict(events.arguments,base::JSON_PARSE_RFC);ASSERT_TRUE(args);
  EXPECT_EQ(*args->FindString("clientDataHash"),PawlEncode(make.client_data_hash));
  EXPECT_EQ(*args->FindString("origin"),origin.Serialize());
  EXPECT_FALSE(make_status); // Await exact app consent/result, not automatic completion.
  const std::string reply = PawlRegistrationReply(rp);
  ASSERT_EQ(1,barc_tab_complete_vault_passkey(events.observation,events.request,1,reply.c_str()));
  ASSERT_TRUE(base::test::RunUntil([&]{return make_status.has_value();}));
  ASSERT_EQ(device::MakeCredentialStatus::kSuccess,*make_status);ASSERT_TRUE(created);
  const auto credential = created->attestation_object.GetCredentialId();
  client.Set("type","webauthn.get");
  device::CtapGetAssertionRequest get(rp,*base::WriteJson(client));
  get.allow_list.emplace_back(device::CredentialType::kPublicKey,credential);
  std::optional<device::GetAssertionStatus> get_status;
  std::vector<device::AuthenticatorGetAssertionResponse> assertions;
  authenticator->GetAssertion(get,device::CtapGetAssertionOptions(),base::BindLambdaForTesting([&](device::GetAssertionStatus status,std::vector<device::AuthenticatorGetAssertionResponse> responses){
    get_status=status;assertions=std::move(responses);
  }));
  ASSERT_TRUE(base::test::RunUntil([&]{return events.operation==1 && events.request!=0;}));
  auto hash = crypto::hash::Sha256(rp);
  device::AuthenticatorData auth(hash,true,true,false,false,1,std::nullopt,std::nullopt);
  base::DictValue asserted;
  asserted.Set("credentialId",PawlEncode(credential));asserted.Set("authenticatorData",PawlEncode(auth.SerializeToByteArray()));
  asserted.Set("signature",PawlEncode(std::array<uint8_t,3>{1,2,3}));asserted.Set("userHandle","AQ");
  auto encoded = base::WriteJson(asserted);ASSERT_TRUE(encoded);
  ASSERT_EQ(1,barc_tab_complete_vault_passkey(events.observation,events.request,1,encoded->c_str()));
  ASSERT_TRUE(base::test::RunUntil([&]{return get_status.has_value();}));
  ASSERT_EQ(device::GetAssertionStatus::kSuccess,*get_status);ASSERT_EQ(1u,assertions.size());
  EXPECT_EQ(credential,assertions.front().credential->id);
  EXPECT_EQ(std::vector<uint8_t>({1}),assertions.front().user_entity->id);
  discovery->set_observer(nullptr);
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,PawlProviderUnsupportedCancellationAndLateReplyNeverCompleteWrongDocument) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),embedded_test_server()->GetURL("/title1.html")));
  auto* contents = browser()->tab_strip_model()->GetActiveWebContents();auto* frame=contents->GetPrimaryMainFrame();
  const auto origin=frame->GetLastCommittedOrigin();const auto rp=origin.host();
  PawlEvents events;const int32_t window=browser()->GetSessionID().id();
  events.observation=barc_tab_observe(window,barc_window_tab_at(window,0),PawlEvents::Tab,&events);
  base::ScopedClosureRunner stop(base::BindOnce([](uint64_t token){barc_tab_unobserve(token);},events.observation));
  ASSERT_EQ(1,barc_tab_observe_vault_passkeys(events.observation,PawlEvents::Request));
  auto discovery=barc::CreateVaultPasskeyDiscovery(frame,origin,rp);ASSERT_TRUE(discovery);
  PawlDiscoveryObserver observer;discovery->set_observer(&observer);discovery->Start();
  ASSERT_TRUE(base::test::RunUntil([&]{return observer.started;}));
  auto* authenticator=observer.authenticator.get();
  device::CtapGetAssertionRequest empty(rp,"{}");
  empty.user_presence_required=false;
  std::optional<device::GetAssertionStatus> status;
  authenticator->GetAssertion(empty,device::CtapGetAssertionOptions(),base::BindLambdaForTesting([&](device::GetAssertionStatus value,std::vector<device::AuthenticatorGetAssertionResponse>){status=value;}));
  ASSERT_TRUE(status);EXPECT_NE(device::GetAssertionStatus::kSuccess,*status);EXPECT_EQ(0,events.requests);
  empty.user_presence_required=true;
  empty.allow_list.emplace_back(device::CredentialType::kPublicKey,std::vector<uint8_t>{1});
  auto unsupported=empty;unsupported.app_id="https://unsupported.invalid";
  status.reset();authenticator->GetAssertion(unsupported,device::CtapGetAssertionOptions(),base::BindLambdaForTesting([&](device::GetAssertionStatus value,std::vector<device::AuthenticatorGetAssertionResponse>){status=value;}));
  ASSERT_TRUE(status);EXPECT_NE(device::GetAssertionStatus::kSuccess,*status);EXPECT_EQ(0,events.requests);
  status.reset();authenticator->GetAssertion(empty,device::CtapGetAssertionOptions(),base::BindLambdaForTesting([&](device::GetAssertionStatus value,std::vector<device::AuthenticatorGetAssertionResponse>){status=value;}));
  ASSERT_TRUE(base::test::RunUntil([&]{return events.request!=0;}));
  const uint64_t cancelled=events.request;authenticator->Cancel();
  EXPECT_EQ(0,barc_tab_complete_vault_passkey(events.observation,cancelled,1,"{}"));
  base::RunLoop().RunUntilIdle();EXPECT_FALSE(status);
  authenticator->GetAssertion(empty,device::CtapGetAssertionOptions(),base::BindLambdaForTesting([&](device::GetAssertionStatus value,std::vector<device::AuthenticatorGetAssertionResponse>){status=value;}));
  ASSERT_TRUE(base::test::RunUntil([&]{return events.request!=0 && events.request!=cancelled;}));
  const uint64_t navigation_request=events.request;
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),embedded_test_server()->GetURL("/title2.html")));
  EXPECT_EQ(0,barc_tab_vault_passkey_is_current(events.observation,navigation_request));
  EXPECT_EQ(0,barc_tab_complete_vault_passkey(events.observation,navigation_request,1,"{}"));
  ASSERT_TRUE(base::test::RunUntil([&]{return status.has_value();}));
  EXPECT_NE(device::GetAssertionStatus::kSuccess,*status);
  ASSERT_EQ(1,barc_tab_observe_vault_passkeys(events.observation,nullptr));
  EXPECT_FALSE(barc::CreateVaultPasskeyDiscovery(contents->GetPrimaryMainFrame(),contents->GetPrimaryMainFrame()->GetLastCommittedOrigin(),rp));
  discovery->set_observer(nullptr);
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,PawlExplicitChoicePreservesStockPlatformRoutingWithoutResidentMetadata) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),embedded_test_server()->GetURL("localhost", "/title1.html")));
  auto* frame=browser()->tab_strip_model()->GetActiveWebContents()->GetPrimaryMainFrame();
  using Model=AuthenticatorRequestDialogModel;using Controller=AuthenticatorRequestDialogController;
  using Transport=device::FidoTransportProtocol;using Type=device::AuthenticatorType;
  // Independent scenarios: no stock match, explicit stock retry, explicit Pawl
  // retry after Chrome's normal automatic stock dispatch.
  for (const auto& [recognized, select_pawl] :
       {std::pair(false,true),std::pair(true,false),std::pair(true,true)}) {
    SCOPED_TRACE(testing::Message() << "recognized=" << recognized << " select_pawl=" << select_pawl);
    auto model=base::MakeRefCounted<Model>(frame);Controller controller(model.get(),frame);
    model->relying_party_id = frame->GetLastCommittedOrigin().host();
    auto rediscover = [&controller] {
      controller.saved_authenticators().emplace_back("stock-touchid",Transport::kInternal,Type::kTouchID);
      controller.saved_authenticators().emplace_back("stock-icloud",Transport::kInternal,Type::kICloudKeychain);
      controller.saved_authenticators().emplace_back(barc::kPawlAuthenticatorId,Transport::kInternal,Type::kOther);
    };
    rediscover();
    std::vector<std::string> dispatched;
    base::ScopedClosureRunner complete(base::BindOnce([](scoped_refptr<Model> model) {
      model->OnRequestComplete();
      base::RunLoop().RunUntilIdle();
    },model));
    controller.SetRequestCallback(base::BindLambdaForTesting([&](const std::string& id){dispatched.push_back(id);}));
    device::FidoRequestHandlerBase::TransportAvailabilityInfo tai;
    tai.request_type=device::FidoRequestType::kGetAssertion;tai.available_transports={Transport::kUsbHumanInterfaceDevice};
    if (recognized) tai.available_transports.insert(Transport::kInternal);
    tai.has_platform_authenticator_credential=recognized ? device::FidoRequestHandlerBase::RecognizedCredential::kHasRecognizedCredential : device::FidoRequestHandlerBase::RecognizedCredential::kNoRecognizedCredential;
    // Same required model publication as upstream UpdateModelBeforeStartFlow.
    tai.platform_has_biometrics = true;  // Synthetic configured Touch ID metadata.
    model->request_type=tai.request_type;
    model->resident_key_requirement=tai.resident_key_requirement;
    model->attestation_conveyance_preference=tai.attestation_conveyance_preference;
    model->ble_adapter_is_powered=tai.ble_status==device::FidoRequestHandlerBase::BleStatus::kOn;
    model->show_security_key_on_qr_sheet=tai.available_transports.contains(Transport::kUsbHumanInterfaceDevice);
    model->is_off_the_record=browser()->GetProfile()->IsOffTheRecord();
    model->platform_has_biometrics=tai.platform_has_biometrics;
    controller.StartFlow(tai,{});
    if (recognized) {
      // StartFlow legitimately auto-dispatches a known local match. Do not
      // invoke a hidden choice while the platform authenticator owns the UI.
      ASSERT_TRUE(base::test::RunUntil([&]{return !dispatched.empty();}));
      base::RunLoop().RunUntilIdle();
      ASSERT_EQ(std::vector<std::string>({"stock-touchid"}),dispatched);
      ASSERT_EQ(Model::Step::kPlatformAuthenticator,model->step());
      // The real "try another option" event returns to the chooser and
      // recreates discoveries. Re-seed only this fixture's synthetic results.
      model->StartOver();
      ASSERT_EQ(Model::Step::kMechanismSelection,model->step());
      ASSERT_TRUE(controller.saved_authenticators().empty());
      rediscover();
    } else {
      ASSERT_TRUE(dispatched.empty());
    }
    ASSERT_EQ(Model::Step::kMechanismSelection,model->step());
    const size_t before = dispatched.size();
    if (select_pawl) {
      auto pawl=std::ranges::find_if(model->mechanisms,[](const auto& mechanism){return std::holds_alternative<Model::Mechanism::PawlVault>(mechanism.type);});
      ASSERT_NE(model->mechanisms.end(),pawl);EXPECT_EQ(u"Pawl Vault",pawl->name);
      pawl->callback.Run();
    } else {
      auto stock=std::ranges::find_if(model->mechanisms,[](const auto& mechanism){
        auto* value=std::get_if<Model::Mechanism::Transport>(&mechanism.type);
        return value && value->value()==Transport::kInternal;
      });
      ASSERT_NE(model->mechanisms.end(),stock);stock->callback.Run();
    }
    ASSERT_TRUE(base::test::RunUntil([&]{return dispatched.size()>before;}));
    base::RunLoop().RunUntilIdle();
    EXPECT_EQ(before+1,dispatched.size());
    EXPECT_EQ(select_pawl ? barc::kPawlAuthenticatorId : "stock-touchid",dispatched.back());
    EXPECT_EQ(3u,controller.saved_authenticators().size());
    complete.RunAndReset();
    EXPECT_EQ(Model::Step::kClosed,model->step());
  }
}

namespace {
class PawlStockAuthenticator final : public device::FidoAuthenticator {
 public:
  explicit PawlStockAuthenticator(device::AuthenticatorType type):type_(type) {}
  void InitializeAuthenticator(base::OnceClosure callback) override { std::move(callback).Run(); }
  void MakeCredential(device::CtapMakeCredentialRequest,device::MakeCredentialOptions,MakeCredentialCallback) override { ADD_FAILURE(); }
  void GetAssertion(device::CtapGetAssertionRequest,device::CtapGetAssertionOptions,GetAssertionCallback) override { ADD_FAILURE(); }
  void Cancel() override {}
  device::AuthenticatorType GetType() const override { return type_; }
  std::string GetId() const override { return type_==device::AuthenticatorType::kTouchID ? "stock-touchid" : "stock-icloud"; }
  const device::AuthenticatorSupportedOptions& Options() const override { return options_; }
  std::optional<device::FidoTransportProtocol> AuthenticatorTransport() const override { return device::FidoTransportProtocol::kInternal; }
  base::WeakPtr<device::FidoAuthenticator> GetWeakPtr() override { return weak_factory_.GetWeakPtr(); }
 private:
  const device::AuthenticatorType type_;
  const device::AuthenticatorSupportedOptions options_;
  base::WeakPtrFactory<PawlStockAuthenticator> weak_factory_{this};
};
class PawlStockDiscovery final : public device::FidoDiscoveryBase {
 public:
  PawlStockDiscovery():FidoDiscoveryBase(device::FidoTransportProtocol::kInternal),
      touchid_(device::AuthenticatorType::kTouchID),icloud_(device::AuthenticatorType::kICloudKeychain) {}
  void Start() override {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,base::BindOnce([](base::WeakPtr<PawlStockDiscovery> self){
      if (self && self->observer()) self->observer()->DiscoveryStarted(self.get(),true,{&self->touchid_,&self->icloud_});
    },weak_factory_.GetWeakPtr()));
  }
 private:
  PawlStockAuthenticator touchid_,icloud_;
  base::WeakPtrFactory<PawlStockDiscovery> weak_factory_{this};
};
class PawlStockFactory final : public device::FidoDiscoveryFactory {
 public:
  std::vector<std::unique_ptr<device::FidoDiscoveryBase>> Create(device::FidoTransportProtocol transport) override {
    EXPECT_EQ(device::FidoTransportProtocol::kInternal,transport);
    std::vector<std::unique_ptr<device::FidoDiscoveryBase>> result;
    result.push_back(std::make_unique<PawlStockDiscovery>());return result;
  }
};
class PawlReadinessHandler final : public device::FidoRequestHandlerBase {
 public:
  PawlReadinessHandler(device::FidoDiscoveryFactory* factory,std::unique_ptr<device::FidoDiscoveryBase> pawl,bool recognized)
      :recognized_(recognized) {
    std::vector<std::unique_ptr<device::FidoDiscoveryBase>> additional;additional.push_back(std::move(pawl));
    InitDiscoveries(factory,std::move(additional),{device::FidoTransportProtocol::kInternal},false);
  }
  void Begin() { Start(); }
  std::vector<std::string> checked;
 private:
  void DispatchRequest(device::FidoAuthenticator*) override { ADD_FAILURE(); }
  void GetPlatformCredentialStatus(device::FidoAuthenticator* authenticator) override {
    EXPECT_TRUE(authenticator->ShouldCheckPlatformCredentialStatus());
    checked.push_back(authenticator->GetId());
    OnHavePlatformCredentialStatus(authenticator->GetType(),std::nullopt,{},
        authenticator->GetType()==device::AuthenticatorType::kICloudKeychain || recognized_ ?
        RecognizedCredential::kHasRecognizedCredential : RecognizedCredential::kNoRecognizedCredential);
  }
  const bool recognized_;
};
class PawlReadinessObserver final : public device::FidoRequestHandlerBase::Observer {
 public:
  int enumerated=0;
  std::optional<device::FidoRequestHandlerBase::TransportAvailabilityInfo> availability;
  void StartObserving(device::FidoRequestHandlerBase*) override {}
  void StopObserving(device::FidoRequestHandlerBase*) override {}
  void OnTransportAvailabilityEnumerated(device::FidoRequestHandlerBase::TransportAvailabilityInfo value) override {++enumerated;availability=std::move(value);}
  bool EmbedderControlsAuthenticatorDispatch(const device::FidoAuthenticator&) override {return true;}
  void BluetoothAdapterStatusChanged(device::FidoRequestHandlerBase::BleStatus) override {}
  void FidoAuthenticatorAdded(const device::FidoAuthenticator&) override {}
  void FidoAuthenticatorRemoved(std::string_view) override {}
  bool SupportsPIN() const override {return false;}
  void CollectPIN(CollectPINOptions,base::OnceCallback<void(std::u16string)>) override {ADD_FAILURE();}
  void FinishCollectToken() override {ADD_FAILURE();}
  void StartBioEnrollment(base::OnceClosure) override {ADD_FAILURE();}
  void OnSampleCollected(int) override {ADD_FAILURE();}
  void OnRetryUserVerification(int) override {ADD_FAILURE();}
};
}  // namespace
IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,PawlAdditionalDiscoveryDoesNotOverwriteStockReadinessOrHoldCancellation) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),embedded_test_server()->GetURL("/title1.html")));
  auto* contents=browser()->tab_strip_model()->GetActiveWebContents();auto* frame=contents->GetPrimaryMainFrame();
  const auto origin=frame->GetLastCommittedOrigin();
  PawlEvents events;const int32_t window=browser()->GetSessionID().id();
  events.observation=barc_tab_observe(window,barc_window_tab_at(window,0),PawlEvents::Tab,&events);
  base::ScopedClosureRunner stop(base::BindOnce([](uint64_t token){barc_tab_unobserve(token);},events.observation));
  ASSERT_EQ(1,barc_tab_observe_vault_passkeys(events.observation,PawlEvents::Request));
  for (bool recognized : {false,true}) {
    auto pawl=barc::CreateVaultPasskeyDiscovery(frame,origin,origin.host());ASSERT_TRUE(pawl);
    PawlStockFactory stock;PawlReadinessHandler handler(&stock,std::move(pawl),recognized);
    PawlReadinessObserver observer;handler.SetObserver(&observer);handler.Begin();
    ASSERT_TRUE(base::test::RunUntil([&]{return observer.enumerated==1;}));
    ASSERT_TRUE(observer.availability);
    EXPECT_EQ((std::vector<std::string>{"stock-touchid","stock-icloud"}),handler.checked);
    EXPECT_EQ(recognized ? device::FidoRequestHandlerBase::RecognizedCredential::kHasRecognizedCredential :
        device::FidoRequestHandlerBase::RecognizedCredential::kNoRecognizedCredential,
        observer.availability->has_platform_authenticator_credential);
    EXPECT_EQ(device::FidoRequestHandlerBase::RecognizedCredential::kHasRecognizedCredential,
        observer.availability->has_icloud_keychain_credential);
    EXPECT_TRUE(handler.HasAuthenticator(barc::kPawlAuthenticatorId));
    EXPECT_TRUE(handler.HasAuthenticator("stock-touchid"));EXPECT_TRUE(handler.HasAuthenticator("stock-icloud"));
    handler.CancelActiveAuthenticators();base::RunLoop().RunUntilIdle();
    EXPECT_EQ(1,observer.enumerated);EXPECT_FALSE(handler.HasAuthenticator(barc::kPawlAuthenticatorId));
    handler.RemoveObserver(&observer);
  }
}

namespace {
class PawlChooseInChromeDialog final : public ChromeAuthenticatorRequestDelegate::TestObserver {
 public:
  PawlChooseInChromeDialog() { ChromeAuthenticatorRequestDelegate::SetGlobalObserverForTesting(this); }
  ~PawlChooseInChromeDialog() { ChromeAuthenticatorRequestDelegate::SetGlobalObserverForTesting(nullptr); }
  int choices=0;
  void UIShown(ChromeAuthenticatorRequestDelegate* delegate) override {
    scoped_refptr<AuthenticatorRequestDialogModel> model=delegate->dialog_model();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,base::BindOnce(
        [](base::WeakPtr<PawlChooseInChromeDialog> self,scoped_refptr<AuthenticatorRequestDialogModel> model){
          if (!self) return;
          auto found=std::ranges::find_if(model->mechanisms,[](const auto& mechanism){
            return std::holds_alternative<AuthenticatorRequestDialogModel::Mechanism::PawlVault>(mechanism.type);
          });
          ASSERT_NE(model->mechanisms.end(),found);
          ++self->choices;found->callback.Run();
        },weak_factory_.GetWeakPtr(),std::move(model)));
  }
 private:
  base::WeakPtrFactory<PawlChooseInChromeDialog> weak_factory_{this};
};
struct PawlSyntheticApplication {
  uint64_t observation=0;
  int requests=0;
  std::vector<uint8_t> credential;
  std::vector<std::string> hashes;
  std::vector<size_t> assertion_allow_counts;
  static void Request(void* pointer,uint64_t observation,uint64_t request,int32_t operation,const char* arguments,void*) {
    if (!request) return;
    auto& self=*static_cast<PawlSyntheticApplication*>(pointer);ASSERT_EQ(self.observation,observation);
    auto args=base::JSONReader::ReadDict(arguments,base::JSON_PARSE_RFC);ASSERT_TRUE(args);
    const auto* rp=args->FindString("rpId");const auto* hash=args->FindString("clientDataHash");ASSERT_TRUE(rp && hash);
    self.hashes.push_back(*hash);++self.requests;
    std::string result;
    if (operation==0) {
      result=PawlRegistrationReply(*rp);
      auto reply=base::JSONReader::ReadDict(result,base::JSON_PARSE_RFC);ASSERT_TRUE(reply);
      std::string bytes;ASSERT_TRUE(base::Base64UrlDecode(*reply->FindString("credentialId"),base::Base64UrlDecodePolicy::DISALLOW_PADDING,&bytes));
      self.credential.assign(bytes.begin(),bytes.end());
    } else {
      ASSERT_EQ(1,operation);
      const auto* allowed=args->FindList("allowCredentials");ASSERT_TRUE(allowed);
      self.assertion_allow_counts.push_back(allowed->size());
      const auto rp_hash=crypto::hash::Sha256(*rp);
      device::AuthenticatorData auth(rp_hash,true,true,false,false,1,std::nullopt,std::nullopt);
      base::DictValue reply;reply.Set("credentialId",PawlEncode(self.credential));
      reply.Set("authenticatorData",PawlEncode(auth.SerializeToByteArray()));
      reply.Set("signature",PawlEncode(std::array<uint8_t,8>{0x30,6,2,1,1,2,1,1}));reply.Set("userHandle","AQ");
      result=*base::WriteJson(reply);
    }
    ASSERT_EQ(1,barc_tab_complete_vault_passkey(observation,request,1,result.c_str()));
  }
};
}  // namespace
// Match upstream WebAuthnBrowserTest's adapter seam. Transport discovery and
// Chrome's normal chooser remain enabled; this fixture excludes physical BLE.
class BarcPawlWebAuthnBrowserTest : public BarcBridgeBrowserTest {
 public:
  void SetUpOnMainThread() override {
    BarcBridgeBrowserTest::SetUpOnMainThread();
    bluetooth_ = base::MakeRefCounted<testing::NiceMock<device::MockBluetoothAdapter>>();
    ON_CALL(*bluetooth_, IsPresent()).WillByDefault(testing::Return(true));
    ON_CALL(*bluetooth_, IsPowered()).WillByDefault(testing::Return(true));
    ON_CALL(*bluetooth_, GetAddress()).WillByDefault(testing::Return("00:11:22:33:44:55"));
    device::BluetoothAdapterFactory::SetAdapterForTesting(bluetooth_);
    // Upstream allows retained Chrome references; the factory itself is weak.
    testing::Mock::AllowLeak(bluetooth_.get());
  }
  void TearDownOnMainThread() override {
    BarcBridgeBrowserTest::TearDownOnMainThread();
    bluetooth_.reset();
  }
 private:
  scoped_refptr<device::MockBluetoothAdapter> bluetooth_;
};

IN_PROC_BROWSER_TEST_F(BarcPawlWebAuthnBrowserTest,PawlNormalWebAuthnCreateThenAllowListAssertionUsesChromeCeremonyAndClientData) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),embedded_test_server()->GetURL("localhost", "/title1.html")));
  auto* contents=browser()->tab_strip_model()->GetActiveWebContents();
  const int32_t window=browser()->GetSessionID().id();PawlSyntheticApplication app;
  app.observation=barc_tab_observe(window,barc_window_tab_at(window,0),PawlEvents::Tab,&app);
  ASSERT_NE(0u,app.observation);
  base::ScopedClosureRunner stop(base::BindOnce([](uint64_t token){barc_tab_unobserve(token);},app.observation));
  ASSERT_EQ(1,barc_tab_observe_vault_passkeys(app.observation,PawlSyntheticApplication::Request));
  PawlChooseInChromeDialog chooser;
  const auto create_result=content::EvalJs(contents,R"JS((async()=>{
    const c=await navigator.credentials.create({publicKey:{challenge:new Uint8Array([1,2,3]),
      rp:{name:'Synthetic Pawl'},user:{id:new Uint8Array([1]),name:'synthetic-user',displayName:'Synthetic'},
      pubKeyCredParams:[{type:'public-key',alg:-7}],
      authenticatorSelection:{residentKey:'required',userVerification:'required'},attestation:'none'}});
    window.pawlSyntheticCredential=Array.from(new Uint8Array(c.rawId));
    return JSON.stringify({client:btoa(String.fromCharCode(...new Uint8Array(c.response.clientDataJSON))),
      algorithm:c.response.getPublicKeyAlgorithm(),type:c.type});
  })())JS");
  ASSERT_TRUE(create_result.is_ok()) << create_result;
  ASSERT_TRUE(create_result.is_string()) << create_result;
  const std::string create=create_result.ExtractString();
  auto created=base::JSONReader::ReadDict(create,base::JSON_PARSE_RFC);ASSERT_TRUE(created);
  EXPECT_EQ(-7,created->FindInt("algorithm"));EXPECT_EQ("public-key",*created->FindString("type"));
  std::string client;ASSERT_TRUE(base::Base64Decode(*created->FindString("client"),&client));
  auto client_json=base::JSONReader::ReadDict(client,base::JSON_PARSE_RFC);ASSERT_TRUE(client_json);
  EXPECT_EQ("webauthn.create",*client_json->FindString("type"));EXPECT_EQ("AQID",*client_json->FindString("challenge"));
  EXPECT_EQ(contents->GetPrimaryMainFrame()->GetLastCommittedOrigin().Serialize(),*client_json->FindString("origin"));
  ASSERT_EQ(1u,app.hashes.size());EXPECT_EQ(PawlEncode(crypto::hash::Sha256(client)),app.hashes.front());
  const auto get_result=content::EvalJs(contents,R"JS((async()=>{
    const c=await navigator.credentials.get({publicKey:{challenge:new Uint8Array([4,5,6]),
      allowCredentials:[{type:'public-key',id:new Uint8Array(window.pawlSyntheticCredential)}],userVerification:'required'}});
    return JSON.stringify({client:btoa(String.fromCharCode(...new Uint8Array(c.response.clientDataJSON))),
      rpHash:Array.from(new Uint8Array(c.response.authenticatorData).slice(0,32)),
      user:Array.from(new Uint8Array(c.response.userHandle)),id:Array.from(new Uint8Array(c.rawId))});
  })())JS");
  ASSERT_TRUE(get_result.is_ok()) << get_result;
  ASSERT_TRUE(get_result.is_string()) << get_result;
  const std::string get=get_result.ExtractString();
  auto asserted=base::JSONReader::ReadDict(get,base::JSON_PARSE_RFC);ASSERT_TRUE(asserted);
  ASSERT_TRUE(base::Base64Decode(*asserted->FindString("client"),&client));
  client_json=base::JSONReader::ReadDict(client,base::JSON_PARSE_RFC);ASSERT_TRUE(client_json);
  EXPECT_EQ("webauthn.get",*client_json->FindString("type"));EXPECT_EQ("BAUG",*client_json->FindString("challenge"));
  EXPECT_EQ(contents->GetPrimaryMainFrame()->GetLastCommittedOrigin().Serialize(),*client_json->FindString("origin"));
  ASSERT_EQ(2u,app.hashes.size());EXPECT_EQ(PawlEncode(crypto::hash::Sha256(client)),app.hashes.back());
  base::ListValue expected_hash;for (auto byte:crypto::hash::Sha256(contents->GetLastCommittedURL().host())) expected_hash.Append(byte);
  EXPECT_EQ(expected_hash,*asserted->FindList("rpHash"));
  EXPECT_EQ(2,app.requests);EXPECT_EQ(2,chooser.choices);
  // Chromium rejects an invalid RP before the Pawl provider or app is reached.
  EXPECT_EQ("SecurityError",content::EvalJs(contents,R"JS(navigator.credentials.create({publicKey:{
    challenge:new Uint8Array([1]),rp:{id:'unrelated.invalid',name:'Invalid'},
    user:{id:new Uint8Array([1]),name:'synthetic',displayName:'Synthetic'},pubKeyCredParams:[{type:'public-key',alg:-7}]}})
    .then(()=> 'unexpected-success',error=>error.name))JS"));
  EXPECT_EQ(2,app.requests);
}

IN_PROC_BROWSER_TEST_F(BarcPawlWebAuthnBrowserTest,PawlNormalModalEmptyAllowListReturnsActualUserHandleWithoutResidentMetadata) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),embedded_test_server()->GetURL("localhost", "/title1.html")));
  auto* contents=browser()->tab_strip_model()->GetActiveWebContents();
  const int32_t window=browser()->GetSessionID().id();PawlSyntheticApplication app;
  app.observation=barc_tab_observe(window,barc_window_tab_at(window,0),PawlEvents::Tab,&app);
  ASSERT_NE(0u,app.observation);
  base::ScopedClosureRunner stop(base::BindOnce([](uint64_t token){barc_tab_unobserve(token);},app.observation));
  ASSERT_EQ(1,barc_tab_observe_vault_passkeys(app.observation,PawlSyntheticApplication::Request));
  PawlChooseInChromeDialog chooser;
  ASSERT_EQ(true,content::EvalJs(contents,R"JS((async()=>{
    const credential=await navigator.credentials.create({publicKey:{challenge:new Uint8Array([1]),
      rp:{name:'Synthetic Pawl'},user:{id:new Uint8Array([1]),name:'synthetic-user',displayName:'Synthetic'},
      pubKeyCredParams:[{type:'public-key',alg:-7}],authenticatorSelection:{residentKey:'required',userVerification:'required'}}});
    window.pawlResidentCredential=Array.from(new Uint8Array(credential.rawId));return true;
  })())JS"));
  EXPECT_EQ(true,content::EvalJs(contents,R"JS((async()=>{
    const credential=await navigator.credentials.get({publicKey:{challenge:new Uint8Array([7,8,9]),userVerification:'required'}});
    const client=JSON.parse(new TextDecoder().decode(credential.response.clientDataJSON));
    return credential.type==='public-key' && client.type==='webauthn.get' && client.challenge==='BwgJ' && client.origin===location.origin &&
      JSON.stringify(Array.from(new Uint8Array(credential.rawId)))===JSON.stringify(window.pawlResidentCredential) &&
      JSON.stringify(Array.from(new Uint8Array(credential.response.userHandle)))==='[1]';
  })())JS"));
  EXPECT_EQ(std::vector<size_t>({0u}),app.assertion_allow_counts);
  EXPECT_EQ(2,app.requests);EXPECT_EQ(2,chooser.choices);
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,PawlAvailabilityUsesExactFrameReadinessAndRetainsDisconnectedStockAndGuestFallback) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),embedded_test_server()->GetURL("localhost", "/title1.html")));
  auto* contents=browser()->tab_strip_model()->GetActiveWebContents();auto* frame=contents->GetPrimaryMainFrame();
  auto* delegate=content::GetContentClientForTesting()->browser()->GetWebAuthenticationDelegate();ASSERT_TRUE(delegate);
  base::test::TestFuture<std::optional<bool>> stock;
  delegate->IsUserVerifyingPlatformAuthenticatorAvailableOverride(frame,stock.GetCallback());
  const auto stock_override=stock.Get();
  EXPECT_FALSE(barc::IsVaultPasskeyAvailable(frame));
  PawlEvents events;const int32_t window=browser()->GetSessionID().id();
  events.observation=barc_tab_observe(window,barc_window_tab_at(window,0),PawlEvents::Tab,&events);
  ASSERT_NE(0u,events.observation);
  base::ScopedClosureRunner stop(base::BindOnce([](uint64_t token){barc_tab_unobserve(token);},events.observation));
  ASSERT_EQ(1,barc_tab_observe_vault_passkeys(events.observation,PawlEvents::Request));
  ASSERT_TRUE(barc::IsVaultPasskeyAvailable(frame));
  base::test::TestFuture<std::optional<bool>> connected;
  delegate->IsUserVerifyingPlatformAuthenticatorAvailableOverride(frame,connected.GetCallback());
  EXPECT_EQ(std::optional<bool>(true),connected.Get());
  EXPECT_EQ(true,content::EvalJs(contents,"PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()"));
  // Another live WebContents cannot borrow the selected page's connected consumer.
  auto unrelated=content::WebContents::Create(content::WebContents::CreateParams(browser()->GetProfile()));
  EXPECT_FALSE(barc::IsVaultPasskeyAvailable(unrelated->GetPrimaryMainFrame()));
  ASSERT_EQ(1,barc_tab_observe_vault_passkeys(events.observation,nullptr));
  EXPECT_FALSE(barc::IsVaultPasskeyAvailable(frame));
  base::test::TestFuture<std::optional<bool>> disconnected;
  delegate->IsUserVerifyingPlatformAuthenticatorAvailableOverride(frame,disconnected.GetCallback());
  EXPECT_EQ(stock_override,disconnected.Get());
  // An in-memory Guest context, no Browser/window or real profile admission.
  TestingProfile::Builder builder;builder.SetGuestSession();auto guest=builder.Build();
  auto guest_contents=content::WebContents::Create(content::WebContents::CreateParams(guest.get()));
  base::test::TestFuture<std::optional<bool>> guest_result;
  delegate->IsUserVerifyingPlatformAuthenticatorAvailableOverride(guest_contents->GetPrimaryMainFrame(),guest_result.GetCallback());
  EXPECT_EQ(std::optional<bool>(false),guest_result.Get());
}


namespace {
void RegisterSponsorDocument(net::EmbeddedTestServer* server) {
  server->RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request) -> std::unique_ptr<net::test_server::HttpResponse> {
        if (!request.relative_url.starts_with("/watch")) return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK); response->set_content_type("text/html");
        response->set_content("<!doctype html><title>Sponsor fixture</title><div id=movie_player><video></video></div>");
        return response;
      }));
}
std::string SponsorConfig(bool enabled) {
  auto parsed = base::JSONReader::Read(FixedTweaksConfig("", false, false), base::JSON_PARSE_RFC);
  base::DictValue options;
  if (enabled) { options.Set("sponsor", "auto"); options.Set("intro", "manual"); }
  parsed->GetDict().Set("sponsorBlock", std::move(options));
  return base::WriteJson(*parsed).value();
}
std::string SponsorReplyBody(std::string video) {
  return "[{\"videoID\":\"" + video + "\",\"segments\":[{\"UUID\":\"" + std::string(64, 'a') +
      "\",\"segment\":[1,3],\"category\":\"sponsor\",\"actionType\":\"skip\"},"
      "{\"UUID\":\"" + std::string(64, 'b') + "\",\"segment\":[4,6],\"category\":\"intro\",\"actionType\":\"mute\"},"
      "{\"UUID\":\"" + std::string(64, 'c') + "\",\"segment\":[0,999999],\"category\":\"sponsor\",\"actionType\":\"skip\"}]}]";
}
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       SponsorBlockExactVideoReplyCacheAndPrivateTelemetry) {
  net::EmbeddedTestServer fixture_server(net::EmbeddedTestServer::TYPE_HTTPS);
  ConfigureFixedTweaksHTTPS(&fixture_server);
  RegisterSponsorDocument(&fixture_server);
  ASSERT_TRUE(fixture_server.Start());
  ASSERT_EQ(1, PublishFixedTweaks(SponsorConfig(true)));
  int fetches = 0, reports = 0;
  content::URLLoaderInterceptor interceptor(base::BindLambdaForTesting(
      [&](content::URLLoaderInterceptor::RequestParams* request) {
        if (request->url_request.url.host() != "sponsor.ajay.app") return false;
        EXPECT_EQ(network::mojom::CredentialsMode::kOmit, request->url_request.credentials_mode);
        EXPECT_EQ(network::mojom::RedirectMode::kError, request->url_request.redirect_mode);
        EXPECT_TRUE(request->url_request.referrer.is_empty());
        if (request->url_request.url.path().starts_with("/api/skipSegments/")) {
          ++fetches;
          EXPECT_EQ(4u, request->url_request.url.ExtractFileName().size());
          content::URLLoaderInterceptor::WriteResponse("HTTP/1.1 200 OK\nContent-Type: application/json\n\n",
              SponsorReplyBody("abcdefghijk"), request->client.get());
        } else {
          ++reports; EXPECT_EQ("POST", request->url_request.method);
          content::URLLoaderInterceptor::WriteResponse("HTTP/1.1 200 OK\n\n", "", request->client.get());
        }
        return true;
      }));
  const int32_t regular = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  SharedProfileResult private_result;
  barc_private_session_open_window(SharedProfileCompleted, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  for (const int32_t id : {regular, private_result.Get<1>()}) {
    auto* owner = SharedWindow(id);
    const auto video_url = fixture_server.GetURL("www.youtube.com", "/watch?v=abcdefghijk");
    auto* settings = HostContentSettingsMapFactory::GetForProfile(owner->GetProfile());
    // OTR default writes are intentionally ignored by DefaultProvider. Use an
    // exact origin exception so this receiver-only fixture disables JS there too.
    settings->SetContentSettingDefaultScope(video_url, video_url,
        ContentSettingsType::JAVASCRIPT, CONTENT_SETTING_BLOCK);
    ASSERT_EQ(CONTENT_SETTING_BLOCK, settings->GetContentSetting(video_url, video_url,
        ContentSettingsType::JAVASCRIPT));
    ASSERT_NO_FATAL_FAILURE(Navigate(owner, video_url));
    ASSERT_EQ("undefined", content::EvalJs(owner->GetTabStripModel()->GetActiveWebContents(),
        "typeof window.__nookSponsorBlock", content::EXECUTE_SCRIPT_DEFAULT_OPTIONS,
        ISOLATED_WORLD_ID_NOOK_PAGE_TWEAKS));
    auto* frame = owner->GetTabStripModel()->GetActiveWebContents()->GetPrimaryMainFrame();
    const auto document = frame->GetDocumentToken();
    mojo::Remote<chrome::mojom::NookCosmeticResourcesHost> host;
    NativeContentBlocker::BindCosmeticResources(frame, host.BindNewPipeAndPassReceiver());
    base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> initial;
    host->GetResources(document, initial.GetCallback()); ASSERT_TRUE(initial.Take());
    base::test::TestFuture<chrome::mojom::NookSponsorReplyPtr> fetched;
    host->GetSponsorSegments(document, "abcdefghijk", fetched.GetCallback());
    auto reply = fetched.Take(); ASSERT_TRUE(reply); ASSERT_EQ(2u, reply->segments.size());
    EXPECT_EQ("skip", reply->segments[0]->action); EXPECT_EQ("mute", reply->segments[1]->action);
    EXPECT_EQ("manual", reply->options.at("intro"));
    const int count = fetches;
    base::test::TestFuture<chrome::mojom::NookSponsorReplyPtr> cached;
    host->GetSponsorSegments(document, "abcdefghijk", cached.GetCallback()); ASSERT_TRUE(cached.Take());
    EXPECT_EQ(count, fetches);
    host->ReportSponsorSegment(document, "abcdefghijk", std::string(64, 'c'));
    host.FlushForTesting(); EXPECT_EQ(id == regular ? 0 : 1, reports);
    host->ReportSponsorSegment(document, "abcdefghijk", std::string(64, 'a'));
    if (id == regular) ASSERT_TRUE(base::test::RunUntil([&] { return reports == 1; }));
    host->ReportSponsorSegment(document, "abcdefghijk", std::string(64, 'a'));
    host.FlushForTesting(); EXPECT_EQ(1, reports);
    base::test::TestFuture<chrome::mojom::NookSponsorReplyPtr> foreign;
    host->GetSponsorSegments(document, "zzzzzzzzzzz", foreign.GetCallback()); EXPECT_FALSE(foreign.Take());
  }
  EXPECT_EQ(2, fetches); EXPECT_EQ(1, reports);
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       SponsorBlockLateVideoAndConfigurationRepliesAreRetired) {
  net::EmbeddedTestServer fixture_server(net::EmbeddedTestServer::TYPE_HTTPS);
  ConfigureFixedTweaksHTTPS(&fixture_server);
  RegisterSponsorDocument(&fixture_server);
  ASSERT_TRUE(fixture_server.Start());
  ASSERT_EQ(1, PublishFixedTweaks(SponsorConfig(true)));
  mojo::Remote<network::mojom::URLLoaderClient> held;
  content::URLLoaderInterceptor interceptor(base::BindLambdaForTesting(
      [&](content::URLLoaderInterceptor::RequestParams* request) {
        if (request->url_request.url.host() != "sponsor.ajay.app") return false;
        held = std::move(request->client); return true;
      }));
  auto* owner = SharedWindow(Open(kSharedWork, 0, BARC_PROFILE_BLANK));
  HostContentSettingsMapFactory::GetForProfile(owner->GetProfile())->SetDefaultContentSetting(
      ContentSettingsType::JAVASCRIPT, CONTENT_SETTING_BLOCK);
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("www.youtube.com", "/watch?v=abcdefghijk")));
  auto* page = owner->GetTabStripModel()->GetActiveWebContents();
  auto* frame = page->GetPrimaryMainFrame(); const auto document = frame->GetDocumentToken();
  mojo::Remote<chrome::mojom::NookCosmeticResourcesHost> host;
  NativeContentBlocker::BindCosmeticResources(frame, host.BindNewPipeAndPassReceiver());
  base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> initial;
  host->GetResources(document, initial.GetCallback()); ASSERT_TRUE(initial.Take());
  base::test::TestFuture<chrome::mojom::NookSponsorReplyPtr> old;
  host->GetSponsorSegments(document, "abcdefghijk", old.GetCallback());
  ASSERT_TRUE(base::test::RunUntil([&] { return held.is_bound(); }));
  ASSERT_TRUE(content::ExecJs(page, "history.pushState(null,'','?v=zzzzzzzzzzz')"));
  content::URLLoaderInterceptor::WriteResponse("HTTP/1.1 200 OK\nContent-Type: application/json\n\n",
      SponsorReplyBody("abcdefghijk"), held.get());
  EXPECT_FALSE(old.Take()); held.reset();
  base::test::TestFuture<chrome::mojom::NookSponsorReplyPtr> disabled;
  host->GetSponsorSegments(document, "zzzzzzzzzzz", disabled.GetCallback());
  ASSERT_TRUE(base::test::RunUntil([&] { return held.is_bound(); }));
  ASSERT_EQ(1, PublishFixedTweaks(SponsorConfig(false)));
  EXPECT_FALSE(disabled.Take());
  content::URLLoaderInterceptor::WriteResponse("HTTP/1.1 200 OK\nContent-Type: application/json\n\n",
      SponsorReplyBody("zzzzzzzzzzz"), held.get());
  host.FlushForTesting();
}


IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       SponsorBlockIsolatedControllerRoundTripAndDisableCleanup) {
  net::EmbeddedTestServer fixture_server(net::EmbeddedTestServer::TYPE_HTTPS);
  ConfigureFixedTweaksHTTPS(&fixture_server);
  fixture_server.RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request) -> std::unique_ptr<net::test_server::HttpResponse> {
        if (!request.relative_url.starts_with("/watch")) return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK); response->set_content_type("text/html");
        response->set_content("<!doctype html><title>Sponsor fixture</title><div id=movie_player><video></video></div>");
        return response;
      }));
  ASSERT_TRUE(fixture_server.Start());
  ASSERT_EQ(1, PublishFixedTweaks(SponsorConfig(true)));
  mojo::Remote<network::mojom::URLLoaderClient> held;
  content::URLLoaderInterceptor interceptor(base::BindLambdaForTesting(
      [&](content::URLLoaderInterceptor::RequestParams* request) {
        if (request->url_request.url.host() != "sponsor.ajay.app") return false;
        held = std::move(request->client); return true;
      }));
  auto* owner = SharedWindow(Open(kSharedWork, 0, BARC_PROFILE_BLANK));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("www.youtube.com", "/watch?v=abcdefghijk")));
  auto* page = owner->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(base::test::RunUntil([&] { return held.is_bound(); }));
  EXPECT_EQ("undefined", content::EvalJs(page, "typeof window.__nookSponsorBlock"));
  EXPECT_EQ(true, content::EvalJs(page, R"(
    (()=>{const controller=window.__nookSponsorBlock;const receive=controller.receiveSegments;
      controller.receiveSegments=function(segments,options,video){
        document.body.dataset.sponsorReply=segments.map(s=>s.actionType).join(',')+':'+options.intro+':'+video;
        return receive.call(controller,segments,options,video);
      };return typeof controller.stop==='function';})()
  )", content::EXECUTE_SCRIPT_DEFAULT_OPTIONS, ISOLATED_WORLD_ID_NOOK_PAGE_TWEAKS));
  content::URLLoaderInterceptor::WriteResponse("HTTP/1.1 200 OK\nContent-Type: application/json\n\n",
      SponsorReplyBody("abcdefghijk"), held.get());
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(page, "document.body.dataset.sponsorReply || ''") == "skip,mute:manual:abcdefghijk";
  }));
  ASSERT_EQ(1, PublishFixedTweaks(SponsorConfig(false)));
  EXPECT_EQ("undefined", content::EvalJs(page, "typeof window.__nookSponsorBlock",
      content::EXECUTE_SCRIPT_DEFAULT_OPTIONS, ISOLATED_WORLD_ID_NOOK_PAGE_TWEAKS));
  EXPECT_EQ("skip,mute:manual:abcdefghijk", content::EvalJs(page, "document.body.dataset.sponsorReply"));
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       SponsorRetirementAccessorMayReplaceDOMReentrantly) {
  net::EmbeddedTestServer fixture_server(net::EmbeddedTestServer::TYPE_HTTPS);
  ConfigureFixedTweaksHTTPS(&fixture_server);
  fixture_server.RegisterRequestHandler(base::BindRepeating(
      [](const net::test_server::HttpRequest& request) -> std::unique_ptr<net::test_server::HttpResponse> {
        if (!request.relative_url.starts_with("/watch")) return nullptr;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK); response->set_content_type("text/html");
        response->set_content("<!doctype html><title>Before retirement</title><div id=movie_player><video></video></div>");
        return response;
      }));
  ASSERT_TRUE(fixture_server.Start());
  ASSERT_EQ(1, PublishFixedTweaks(SponsorConfig(true)));
  content::URLLoaderInterceptor interceptor(base::BindLambdaForTesting(
      [&](content::URLLoaderInterceptor::RequestParams* request) {
        if (request->url_request.url.host() != "sponsor.ajay.app") return false;
        content::URLLoaderInterceptor::WriteResponse("HTTP/1.1 200 OK\nContent-Type: application/json\n\n",
            "[]", request->client.get()); return true;
      }));
  auto* owner = SharedWindow(Open(kSharedWork, 0, BARC_PROFILE_BLANK));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, fixture_server.GetURL("www.youtube.com", "/watch?v=abcdefghijk")));
  auto* page = owner->GetTabStripModel()->GetActiveWebContents();
  ASSERT_EQ(true, content::EvalJs(page, R"(
    (()=>{const controller=window.__nookSponsorBlock;
      Object.defineProperty(controller,'stop',{get(){
        document.open();document.write('<title>Replacement during retirement</title><body data-retired=yes>');document.close();
        window.__nookSponsorBlock={replacement:true};
        return ()=>{};
      }});return true;})()
  )", content::EXECUTE_SCRIPT_DEFAULT_OPTIONS, ISOLATED_WORLD_ID_NOOK_PAGE_TWEAKS));
  content::TitleWatcher replacement(page, u"Replacement during retirement");
  ASSERT_EQ(1, PublishFixedTweaks(SponsorConfig(false)));
  EXPECT_EQ(u"Replacement during retirement", replacement.WaitAndGetTitle());
  EXPECT_EQ("yes", content::EvalJs(page, "document.body.dataset.retired"));
  EXPECT_EQ(true, content::EvalJs(page, "window.__nookSponsorBlock.replacement===true",
      content::EXECUTE_SCRIPT_DEFAULT_OPTIONS, ISOLATED_WORLD_ID_NOOK_PAGE_TWEAKS));
}


namespace {
void ConfigureSocialHTTPS(net::EmbeddedTestServer* server) {
  server->SetCertHostnames({"a.test", "b.test", "c.test", "tenant.github.io", "github.io"});
}
std::string SocialConfig(bool enabled, const std::vector<std::string>& sites = {"a.test"}) {
  auto parsed = base::JSONReader::Read(SponsorConfig(false), base::JSON_PARSE_RFC);
  base::ListValue domains; if (enabled) for (const auto& site : sites) domains.Append(site);
  parsed->GetDict().Set("mediaDownloadSites", std::move(domains));
  return base::WriteJson(*parsed).value();
}
void SocialTarget(Profile* profile, const base::FilePath& directory) {
  DownloadPrefs::FromDownloadManager(profile->GetDownloadManager())->SetDownloadPath(directory);
  profile->GetPrefs()->SetBoolean(prefs::kPromptForDownload, false);
}
std::unique_ptr<download::DownloadUrlParameters> MediaRequest(content::RenderFrameHost* frame, const GURL& url) {
  auto params = frame->CreateDownloadUrlParameters(url, TRAFFIC_ANNOTATION_FOR_TESTS);
  params->set_download_source(download::DownloadSource::NATIVE_SOCIAL_MEDIA);
  params->set_content_initiated(false); params->set_has_user_gesture(true);
  params->set_require_safety_checks(true);
  params->set_credentials_mode(network::mojom::CredentialsMode::kOmit);
  return params;
}
class SocialListData final : public DownloadsListTracker {
 public:
  using DownloadsListTracker::DownloadsListTracker;
  using DownloadsListTracker::CreateDownloadData;
};
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       SocialMediaResponseRestrictionAndPersistedRetryGuards) {
  base::ScopedAllowBlockingForTesting allow;
  base::ScopedTempDir targets; ASSERT_TRUE(targets.CreateUniqueTempDir());
  std::atomic<int> requests{0};
  net::EmbeddedTestServer server(net::EmbeddedTestServer::TYPE_HTTPS); ConfigureSocialHTTPS(&server);
  server.RegisterRequestHandler(base::BindRepeating(
      [](std::atomic<int>* requests, const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (!request.relative_url.starts_with("/media/")) return nullptr;
        ++*requests;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_code(net::HTTP_OK); response->AddCustomHeader("Cache-Control", "no-store");
        const auto path = request.relative_url;
        response->set_content_type(path.find("html") != std::string::npos ? "text/html" :
            path.find("octet") != std::string::npos ? "application/octet-stream" :
            path.find("absent") != std::string::npos ? "" :
            path.find("video") != std::string::npos ? "video/mp4" : "image/png");
        response->set_content(std::string(64, '\0'));
        return response;
      }, &requests));
  ASSERT_TRUE(server.Start());
  auto* owner = SharedWindow(Open(kSharedWork, 0, BARC_PROFILE_BLANK));
  auto* manager = owner->GetProfile()->GetDownloadManager(); SocialTarget(owner->GetProfile(), targets.GetPath());
  auto* frame = owner->GetTabStripModel()->GetActiveWebContents()->GetPrimaryMainFrame();
  download::DownloadItem* refused = nullptr;
  for (const auto& [path, accepted] : std::vector<std::pair<std::string, bool>>{
      {"/media/image.png", true}, {"/media/video.mp4", true}, {"/media/octet.jpg", true}, {"/media/octet.mp3", true},
      {"/media/absent.mp4", true}, {"/media/html.jpg", false}, {"/media/octet.jpg.dmg", false},
      {"/media/image.jpg.dmg", true}}) {
    content::DownloadTestObserverTerminal terminal(manager, 1, content::DownloadTestObserver::ON_DANGEROUS_DOWNLOAD_FAIL);
    auto params = MediaRequest(frame, server.GetURL("a.test", path));
    base::test::TestFuture<download::DownloadItem*, download::DownloadInterruptReason> started;
    params->set_callback(started.GetCallback()); manager->DownloadUrl(std::move(params));
    auto* item = started.Get<0>(); ASSERT_TRUE(item); terminal.WaitForFinished();
    EXPECT_EQ(download::DownloadSource::NATIVE_SOCIAL_MEDIA, item->GetDownloadSource());
    if (accepted) {
      EXPECT_EQ(download::DownloadItem::COMPLETE, item->GetState());
      EXPECT_TRUE(base::PathExists(item->GetTargetFilePath()));
      EXPECT_NE(".dmg", item->GetTargetFilePath().FinalExtension());
    } else {
      EXPECT_EQ(download::DownloadItem::INTERRUPTED, item->GetState());
      EXPECT_EQ(download::DOWNLOAD_INTERRUPT_REASON_FILE_BLOCKED, item->GetLastReason());
      EXPECT_TRUE(item->GetFullPath().empty() || !base::PathExists(item->GetFullPath()));
      refused = item;
    }
  }
  ASSERT_TRUE(refused); EXPECT_FALSE(refused->CanResume());
  const int count = requests.load();
  refused->Resume(true); EXPECT_EQ(download::DownloadItem::INTERRUPTED, refused->GetState());
  DownloadItemModel model(refused); DownloadCommands commands(model.GetWeakPtr());
  EXPECT_FALSE(model.IsCommandEnabled(&commands, DownloadCommands::RETRY));
  SocialListData tracker(manager, {}); EXPECT_FALSE(tracker.CreateDownloadData(refused)->retry);
  content::TestWebUI web_ui; web_ui.set_web_contents(owner->GetTabStripModel()->GetActiveWebContents());
  DownloadsDOMHandler dom({}, {}, manager, &web_ui);
  dom.RetryDownload(base::NumberToString(refused->GetId()));
  DownloadBubbleUIController bubble(owner);
  bubble.ProcessDownloadButtonPress(model.GetWeakPtr(), DownloadCommands::RETRY, true);
  base::RunLoop().RunUntilIdle(); EXPECT_EQ(count, requests.load());
  // The persisted source survives the actual database conversion and carries
  // the same non-retry identity across a future browser restart.
  EXPECT_EQ(download::DownloadSource::NATIVE_SOCIAL_MEDIA,
      download::DownloadDBConversions::DownloadSourceFromProto(download::DownloadDBConversions::DownloadSourceToProto(refused->GetDownloadSource())));
}

IN_PROC_BROWSER_TEST_F(BarcNativeCosmeticCacheBrowserTest,
                       SocialTrustedControlKeepsProfileAuthAndOmittedCDNRedirects) {
  base::ScopedAllowBlockingForTesting allow;
  base::ScopedTempDir targets; ASSERT_TRUE(targets.CreateUniqueTempDir());
  std::atomic<int> credential_escape{0}, suffix_requests{0}; std::atomic<bool> cdn_cookie{false}, suffix_omit{true};
  net::EmbeddedTestServer server(net::EmbeddedTestServer::TYPE_HTTPS); ConfigureSocialHTTPS(&server);
  server.RegisterRequestHandler(base::BindRepeating(
      [](net::EmbeddedTestServer* server, std::atomic<int>* escaped, std::atomic<bool>* cdn_cookie,
         const net::test_server::HttpRequest& request) -> std::unique_ptr<net::test_server::HttpResponse> {
        auto response = std::make_unique<net::test_server::BasicHttpResponse>(); response->set_code(net::HTTP_OK);
        response->AddCustomHeader("Cache-Control", "no-store");
        if (request.relative_url == "/start") {
          response->set_content_type("text/html"); response->AddCustomHeader("Referrer-Policy", "no-referrer");
          response->set_content("<!doctype html><style>body{margin:0}</style><img id=media src='/auth.png' style='width:200px;height:200px'>"); return response;
        }
        const auto cookie = request.headers.find("Cookie"), referrer = request.headers.find("Referer");
        if (request.relative_url == "/credential-redirect") {
          response->set_code(net::HTTP_FOUND); response->AddCustomHeader("Location", server->GetURL("b.test", "/escape-target.png").spec()); return response;
        }
        if (request.relative_url == "/escape-target.png") ++*escaped;
        if (request.relative_url == "/cdn-redirect") {
          if (cookie != request.headers.end()) *cdn_cookie = true;
          response->set_code(net::HTTP_FOUND); response->AddCustomHeader("Location", server->GetURL("c.test", "/cdn.png").spec()); return response;
        }
        if (request.relative_url != "/auth.png" && request.relative_url != "/cdn.png" && request.relative_url != "/escape-target.png") return nullptr;
        if (request.relative_url == "/cdn.png" && cookie != request.headers.end()) *cdn_cookie = true;
        if (request.relative_url == "/auth.png" && (cookie == request.headers.end() || cookie->second.find("auth=") == std::string::npos)) {
          response->set_code(net::HTTP_UNAUTHORIZED); response->set_content_type("text/html"); response->set_content("auth required"); return response;
        }
        std::string png; CHECK(base::Base64Decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==", &png));
        response->set_content_type("image/png"); response->set_content(png + "\ncookie=" + (cookie == request.headers.end() ? "" : cookie->second) +
            "\nreferrer=" + (referrer == request.headers.end() ? "" : referrer->second)); return response;
      }, &server, &credential_escape, &cdn_cookie));
  content::URLLoaderInterceptor observe_credentials(base::BindLambdaForTesting(
      [&](content::URLLoaderInterceptor::RequestParams* request) {
        if (request->url_request.url.host() == "github.io" && request->url_request.url.path() == "/cdn.png") {
          ++suffix_requests;
          if (request->url_request.credentials_mode != network::mojom::CredentialsMode::kOmit) suffix_omit = false;
        }
        return false;  // Observe mode, but keep the actual verified HTTPS request.
      }));
  ASSERT_TRUE(server.Start()); ASSERT_EQ(1, PublishFixedTweaks(SocialConfig(true)));
  const int32_t window = Open(kSharedWork, 0, BARC_PROFILE_BLANK); auto* owner = SharedWindow(window);
  auto* profile = owner->GetProfile(); auto* manager = profile->GetDownloadManager(); SocialTarget(profile, targets.GetPath());
  ASSERT_TRUE(content::SetCookie(profile, server.GetURL("a.test", "/"), "auth=Work; Secure; SameSite=Strict"));
  ASSERT_TRUE(content::SetCookie(profile, server.GetURL("b.test", "/"), "secret=B; Secure; SameSite=None"));
  ASSERT_TRUE(content::SetCookie(profile, server.GetURL("c.test", "/"), "secret=C; Secure; SameSite=None"));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, server.GetURL("a.test", "/start")));
  auto* page = owner->GetTabStripModel()->GetActiveWebContents();
  NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
  ASSERT_EQ(1, barc_window_attach_native_shell(window, (__bridge void*)header)); ASSERT_EQ(1, barc_window_show(window));
  content::SimulateEndOfPaintHoldingOnPrimaryMainFrame(page);
  content::WaitForHitTestData(page->GetPrimaryMainFrame());
  EXPECT_EQ("undefined", content::EvalJs(page, "typeof nookSocialDownloadNative"));
  content::SimulateMouseEvent(page, blink::WebInputEvent::Type::kMouseMove, gfx::Point(100, 100));
  ASSERT_TRUE(base::test::RunUntil([&] { return content::EvalJs(page, "document.documentElement.lastElementChild.tagName==='DIV'") == true; }));
  content::DownloadTestObserverTerminal trusted(manager, 1, content::DownloadTestObserver::ON_DANGEROUS_DOWNLOAD_FAIL);
  content::SimulateMouseClickAt(page, 0, blink::WebMouseEvent::Button::kLeft, gfx::Point(176, 24)); trusted.WaitForFinished();
  content::DownloadManager::DownloadVector items; manager->GetAllDownloads(&items); ASSERT_EQ(1u, items.size());
  ASSERT_EQ(download::DownloadItem::COMPLETE, items[0]->GetState()) << items[0]->GetLastReason();
  EXPECT_EQ(download::DownloadSource::NATIVE_SOCIAL_MEDIA, items[0]->GetDownloadSource());
  std::string bytes; ASSERT_TRUE(base::ReadFileToString(items[0]->GetTargetFilePath(), &bytes));
  EXPECT_FALSE(gfx::PNGCodec::Decode(base::as_byte_span(bytes)).drawsNothing());
  EXPECT_NE(std::string::npos, bytes.find("auth=Work")); EXPECT_EQ(std::string::npos, bytes.find("referrer=https:"));
  auto* frame = page->GetPrimaryMainFrame(); const auto document = frame->GetDocumentToken();
  mojo::Remote<chrome::mojom::NookCosmeticResourcesHost> host;
  NativeContentBlocker::BindCosmeticResources(frame, host.BindNewPipeAndPassReceiver());
  base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> initial; host->GetResources(document, initial.GetCallback()); ASSERT_TRUE(initial.Take());
  for (const auto& [url, complete] : std::vector<std::pair<GURL, bool>>{
      {server.GetURL("b.test", "/cdn-redirect"), true}, {server.GetURL("a.test", "/credential-redirect"), false}}) {
    content::SimulateMouseClickAt(page, 0, blink::WebMouseEvent::Button::kLeft, gfx::Point(350, 350));
    ASSERT_TRUE(base::test::RunUntil([&] { return frame->HasTransientUserActivation(); }));
    content::DownloadTestObserverTerminal finished(manager, 1, content::DownloadTestObserver::ON_DANGEROUS_DOWNLOAD_FAIL);
    base::test::TestFuture<bool> accepted;
    host->SaveSocialMedia(document, url.spec(), static_cast<int32_t>(net::ReferrerPolicy::NO_REFERRER), accepted.GetCallback()); ASSERT_TRUE(accepted.Get());
    finished.WaitForFinished();
    EXPECT_EQ(0, credential_escape.load()); EXPECT_FALSE(cdn_cookie.load());
    manager->GetAllDownloads(&items);
    auto found = std::ranges::find_if(items, [&](const auto& item) { return item->GetOriginalUrl() == url; }); ASSERT_NE(items.end(), found);
    EXPECT_EQ(complete ? download::DownloadItem::COMPLETE : download::DownloadItem::INTERRUPTED, (*found)->GetState());
    if (complete) {
      ASSERT_TRUE(base::ReadFileToString((*found)->GetTargetFilePath(), &bytes));
      EXPECT_EQ(std::string::npos, bytes.find("secret=")); EXPECT_EQ(std::string::npos, bytes.find("referrer=https:"));
    }
  }
  ASSERT_TRUE(content::SetCookie(profile, server.GetURL("tenant.github.io", "/"), "auth=Tenant; Secure; SameSite=Strict"));
  ASSERT_TRUE(content::SetCookie(profile, server.GetURL("github.io", "/"), "suffixSecret=1; Secure; SameSite=None"));
  ASSERT_EQ(1, PublishFixedTweaks(SocialConfig(true, {"tenant.github.io"})));
  ASSERT_NO_FATAL_FAILURE(Navigate(owner, server.GetURL("tenant.github.io", "/start")));
  frame = page->GetPrimaryMainFrame(); const auto tenant_document = frame->GetDocumentToken();
  host.reset(); NativeContentBlocker::BindCosmeticResources(frame, host.BindNewPipeAndPassReceiver());
  base::test::TestFuture<chrome::mojom::NookCosmeticResourcesPtr> tenant_initial;
  host->GetResources(tenant_document, tenant_initial.GetCallback()); ASSERT_TRUE(tenant_initial.Take());
  content::SimulateEndOfPaintHoldingOnPrimaryMainFrame(page); content::WaitForHitTestData(frame);
  content::SimulateMouseClickAt(page, 0, blink::WebMouseEvent::Button::kLeft, gfx::Point(350, 350));
  ASSERT_TRUE(base::test::RunUntil([&] { return frame->HasTransientUserActivation(); }));
  content::DownloadTestObserverTerminal suffix_finished(manager, 1, content::DownloadTestObserver::ON_DANGEROUS_DOWNLOAD_FAIL);
  base::test::TestFuture<bool> suffix_accepted;
  host->SaveSocialMedia(tenant_document, server.GetURL("github.io", "/cdn.png").spec(),
      static_cast<int32_t>(net::ReferrerPolicy::NO_REFERRER), suffix_accepted.GetCallback()); ASSERT_TRUE(suffix_accepted.Get());
  suffix_finished.WaitForFinished(); EXPECT_GT(suffix_requests.load(), 0); EXPECT_TRUE(suffix_omit.load()); EXPECT_FALSE(cdn_cookie.load());
  ASSERT_EQ(1, PublishFixedTweaks(SocialConfig(false)));
  content::SimulateMouseClickAt(page, 0, blink::WebMouseEvent::Button::kLeft, gfx::Point(350, 350));
  ASSERT_TRUE(base::test::RunUntil([&] { return frame->HasTransientUserActivation(); }));
  base::test::TestFuture<bool> disabled;
  host->SaveSocialMedia(tenant_document, server.GetURL("a.test", "/auth.png").spec(), static_cast<int32_t>(net::ReferrerPolicy::NO_REFERRER), disabled.GetCallback()); EXPECT_FALSE(disabled.Get());
}

class BarcSocialParallelDownloadBrowserTest : public BarcNativeCosmeticCacheBrowserTest {
 public:
  BarcSocialParallelDownloadBrowserTest() {
    parallel_features_.InitWithFeaturesAndParameters(
        {{download::features::kParallelDownloading,
          {{download::kMinSliceSizeFinchKey, "1048576"}}}}, {});
  }
 private:
  base::test::ScopedFeatureList parallel_features_;
};

IN_PROC_BROWSER_TEST_F(BarcSocialParallelDownloadBrowserTest,
                       SocialMediaCancellationAndInterruptedResumeDoNotRestart) {
  base::ScopedAllowBlockingForTesting allow;
  base::ScopedTempDir targets; ASSERT_TRUE(targets.CreateUniqueTempDir());
  net::EmbeddedTestServer server(net::EmbeddedTestServer::TYPE_HTTPS); ConfigureSocialHTTPS(&server);
  net::test_server::ControllableHttpResponse control_response(&server, "/parallel-control.png");
  net::test_server::ControllableHttpResponse response(&server, "/slow.png"); ASSERT_TRUE(server.Start());
  auto* owner = SharedWindow(Open(kSharedWork, 0, BARC_PROFILE_BLANK));
  auto* manager = owner->GetProfile()->GetDownloadManager(); SocialTarget(owner->GetProfile(), targets.GetPath());
  // Large declared length, strong validator and range support qualify the job;
  // only seven body bytes are ever sent or allocated for either response.
  constexpr char headers[] = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n"
      "Content-Length: 8388608\r\nETag: \"media-v1\"\r\nAccept-Ranges: bytes\r\n\r\npartial";
  auto* frame = owner->GetTabStripModel()->GetActiveWebContents()->GetPrimaryMainFrame();
  auto control_params = MediaRequest(frame, server.GetURL("a.test", "/parallel-control.png"));
  control_params->set_download_source(download::DownloadSource::UNKNOWN);
  base::test::TestFuture<download::DownloadItem*, download::DownloadInterruptReason> control_started;
  control_params->set_callback(control_started.GetCallback());
  manager->DownloadUrl(std::move(control_params)); control_response.WaitForRequest();
  control_response.Send(headers);
  auto* control = control_started.Get<0>(); ASSERT_TRUE(control);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return control->GetDownloadFile() && !control->GetFullPath().empty();
  }));
  ASSERT_TRUE(control->IsParallelDownload());
  control->Cancel(true); control_response.Done();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return control->GetFullPath().empty() || !base::PathExists(control->GetFullPath());
  }));
  auto params = MediaRequest(frame, server.GetURL("a.test", "/slow.png"));
  base::test::TestFuture<download::DownloadItem*, download::DownloadInterruptReason> started;
  params->set_callback(started.GetCallback()); manager->DownloadUrl(std::move(params)); response.WaitForRequest();
  response.Send(headers);
  auto* item = started.Get<0>(); ASSERT_TRUE(item);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return item->GetDownloadFile() && !item->GetFullPath().empty();
  }));
  EXPECT_EQ(download::DownloadSource::NATIVE_SOCIAL_MEDIA, item->GetDownloadSource());
  EXPECT_FALSE(item->IsParallelDownload());
  // Pausing this existing stream remains supported; only restart is forbidden.
  item->Pause(); EXPECT_TRUE(item->IsPaused());
  item->Resume(true); EXPECT_FALSE(item->IsPaused());
  EXPECT_EQ(download::DownloadItem::IN_PROGRESS, item->GetState());
  response.Done(); ASSERT_TRUE(base::test::RunUntil([&] { return item->GetState() == download::DownloadItem::INTERRUPTED; }));
  EXPECT_FALSE(item->CanResume()); item->Resume(true); EXPECT_EQ(download::DownloadItem::INTERRUPTED, item->GetState());
  item->Cancel(true); EXPECT_EQ(download::DownloadItem::CANCELLED, item->GetState());
  EXPECT_TRUE(item->GetFullPath().empty() || !base::PathExists(item->GetFullPath()));
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, HistoryMenuResolvesStableEntriesLive) {
  ASSERT_TRUE(embedded_test_server()->Start());
  auto* contents = browser()->tab_strip_model()->GetActiveWebContents();
  const int32_t window = browser()->GetSessionID().id();
  const int32_t tab = tabs::TabInterface::GetFromContents(contents)->GetHandle().raw_value();
  const GURL first = embedded_test_server()->GetURL("/title1.html");
  const GURL second = embedded_test_server()->GetURL("/title2.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), first));
  const int first_id = contents->GetController().GetLastCommittedEntry()->GetUniqueID();
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), second));
  const int second_id = contents->GetController().GetLastCommittedEntry()->GetUniqueID();
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), first));
  const size_t required = barc_tab_copy_history(window, tab, 0, nullptr, 0);
  ASSERT_GT(required, 1u);
  std::vector<char> bytes(required, 0);
  ASSERT_EQ(required, barc_tab_copy_history(window, tab, 0, bytes.data(), bytes.size()));
  auto entries = base::JSONReader::ReadList(bytes.data(), base::JSON_PARSE_RFC);
  ASSERT_TRUE(entries); ASSERT_GE(entries->size(), 2u);
  EXPECT_EQ(second_id, (*entries)[0].GetDict().FindInt("id"));
  EXPECT_EQ(first_id, (*entries)[1].GetDict().FindInt("id"));
  EXPECT_EQ(0, barc_tab_go_to_history_entry(window + 100000, tab, first_id));
  // An intervening same-tab navigation does not invalidate the user's choice.
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), second));
  EXPECT_EQ(1, barc_tab_go_to_history_entry(window, tab, first_id));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_EQ(first_id, contents->GetController().GetLastCommittedEntry()->GetUniqueID());
  // A new navigation prunes the captured forward entry, even for its same URL.
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), second));
  EXPECT_EQ(0, barc_tab_go_to_history_entry(window, tab, second_id));
}
