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
#include <vector>
#include <objc/runtime.h>

#include "bark/browser/ui/bark_window_host.h"
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
#include "components/password_manager/core/common/password_manager_util.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/strings/utf_string_conversions.h"
#include "base/strings/string_util.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/version_info/version_info.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/ui/autofill/key_press_handler_registration.h"
#include "components/input/native_web_keyboard_event.h"
#include "ui/events/keycodes/keyboard_codes.h"
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
#include "build/build_config.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/focused_node_details.h"
#include "content/public/browser/web_contents.h"
#include "device/vr/buildflags/buildflags.h"
#include "ui/base/base_window.h"
#include "ui/gfx/geometry/insets.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "skia/ext/image_operations.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/image/image.h"
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
// The vault approves these exact fields for this document. Chromium can merge
// renderer forms, so a split widget must also share its original form and frame.
using VaultCodeFields = std::vector<autofill::FieldGlobalId>;

bool IsVaultCodeInput(const autofill::AutofillField& field) {
  using enum autofill::FormControlType;
  const auto type = field.form_control_type();
  return field.is_focusable() && field.is_visible() && field.is_enabled() &&
         !field.is_readonly() && (type == kInputText || type == kInputTelephone ||
                                  type == kInputNumber || type == kInputPassword) &&
         (field.html_type() == autofill::HtmlFieldType::kUnspecified ||
          field.html_type() == autofill::HtmlFieldType::kOneTimeCode);
}

bool HasVaultCodeHint(const autofill::AutofillField& field) {
  using password_manager::util::IsLikelyOtp;
  return field.html_type() == autofill::HtmlFieldType::kOneTimeCode ||
         field.Type().GetTypes().contains(autofill::ONE_TIME_CODE) ||
         IsLikelyOtp(field.name_attribute(), field.id_attribute(), {}) ||
         IsLikelyOtp(field.label(), field.aria_label(), {}) ||
         IsLikelyOtp(field.placeholder(), {}, {});
}

VaultCodeFields CodeFieldsFor(const autofill::FormStructure& form,
                             const autofill::AutofillField& trigger) {
  if (!IsVaultCodeInput(trigger)) return {};
  if (trigger.max_length() != 1) {
    return HasVaultCodeHint(trigger) ? VaultCodeFields{trigger.global_id()}
                                     : VaultCodeFields{};
  }
  const auto& fields = form.fields();
  auto first = std::ranges::find(fields, &trigger, &std::unique_ptr<autofill::AutofillField>::get);
  if (first == fields.end()) return {};
  const auto is_box = [&](const auto& f) {
    return f->max_length() == 1 && IsVaultCodeInput(*f) &&
           f->renderer_form_id() == trigger.renderer_form_id() &&
           f->origin() == trigger.origin() &&
           (!f->IsPasswordInputElement() || HasVaultCodeHint(*f));
  };
  while (first != fields.begin() && is_box(*std::prev(first))) --first;
  auto last = std::find_if_not(first, fields.end(), is_box);
  if (last - first < 4 || last - first > 8 ||
      !std::any_of(first, last, [](const auto& f) { return HasVaultCodeHint(*f); }))
    return {};
  VaultCodeFields result;
  for (auto it = first; it != last; ++it) result.push_back((*it)->global_id());
  return result;
}

class NativeBlockInfoBar final : public ConfirmInfoBarDelegate {
 public:
  explicit NativeBlockInfoBar(base::RepeatingClosure continue_request)
      : continue_request_(std::move(continue_request)) {}
  InfoBarIdentifier GetIdentifier() const override {
    return BARC_NATIVE_CONTENT_BLOCK_INFOBAR_DELEGATE;
  }
  bool EqualsDelegate(infobars::InfoBarDelegate* other) const override {
    return other->GetIdentifier() == GetIdentifier();
  }
  std::u16string GetMessageText() const override {
    return u"Barc blocked this page.";
  }
  int GetButtons() const override { return BUTTON_OK; }
  std::u16string GetButtonLabel(InfoBarButton) const override { return u"Continue"; }
  bool Accept() override {
    // The exact app page owns the exception. Keep the bar if it refuses the
    // request; the navigation it starts expires the bar.
    auto request = continue_request_;
    request.Run();
    return false;
  }
  // Shown after its blocked page committed, so any later page leaves that one.
  // Continuing loads the same URL, which replaces the blocked page's entry, and
  // Chromium's default keeps a bar across a replacement.
  bool ShouldExpire(const NavigationDetails& details) const override {
    return details.is_navigation_to_different_page;
  }
 private:
  const base::RepeatingClosure continue_request_;
};

class TabObservation;
using Observations = std::map<uint64_t, std::shared_ptr<TabObservation>>;
Observations& ObservationTable() {
  static base::NoDestructor<Observations> table;
  return *table;
}
class TabObservation : public content::WebContentsObserver,
                       public autofill::AutofillManager::Observer,
                       public chrome::mojom::NookTranslationClient,
                       public media_session::mojom::MediaSessionObserver,
                       public content::BrowsingDataRemover::Observer,
                       public ProfileManagerObserver,
                       public TabStripModelObserver,
                       public favicon::FaviconDriverObserver,
                       public std::enable_shared_from_this<TabObservation> {
 public:
  TabObservation(uint64_t token, tabs::TabInterface* tab,
                 BarcTabCallback callback, void* context)
      : content::WebContentsObserver(tab->GetContents()), token_(token),
        tab_(tab->GetHandle()), callback_(callback), context_(context) {
    detach_ = tab->RegisterWillDetach(base::BindRepeating(
        &TabObservation::Detach, base::Unretained(this)));
    insert_ = tab->RegisterDidInsert(base::BindRepeating(
        &TabObservation::Inserted, base::Unretained(this)));
    discard_ = tab->RegisterWillDiscardContents(base::BindRepeating(
        &TabObservation::Discard, base::Unretained(this)));
    picker_deactivate_ = tab->RegisterWillDeactivate(base::BindRepeating(
        [](TabObservation* self, tabs::TabInterface*) { self->CancelPicker(); },
        base::Unretained(this)));
    BindOwner();
  }
  ~TabObservation() override { vault_callback_ = nullptr; vault_focus_.reset(); UnbindOwner(); }
  int32_t tab_id() const { return tab_.raw_value(); }
  bool active() const { return active_; }
  int CloseSelecting(int32_t successor) {
    auto keep_alive = shared_from_this();
    auto* tab = tab_.Get();
    if (!active_ || closing_ || !tab || !tab->GetBrowserWindowInterface() || !web_contents())
      return 0;
    close_successor_ = successor;
    if (!web_contents()->NeedToFireBeforeUnloadOrUnloadEvents()) ShowCloseSuccessor();
    tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (!active_ || closing_ || !owner || !web_contents()) return 0;
    owner->GetTabStripModel()->CloseWebContents(
        web_contents(), TabCloseTypes::CLOSE_USER_GESTURE |
                            TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
    return 1;
  }
  void ShowCloseSuccessor() {
    const int32_t successor = std::exchange(close_successor_, 0);
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* next = owner ? LookupTab(owner, successor) : nullptr;
    if (!next || next == tab || !tab->IsActivated()) return;
    auto* strip = owner->GetTabStripModel();
    strip->ActivateTabAt(strip->GetIndexOfTab(next));
  }
  struct VaultSubmission {
    uint64_t token;
    base::WeakPtr<BrowserWindowInterface> owner;
    std::string origin, username, password;
  };
  BarcVaultSaveCallback vault_save_callback_ = nullptr;
  std::optional<VaultSubmission> vault_submission_;
  uint64_t vault_submission_serial_ = 0;
  bool vault_save_notification_posted_ = false;
  int32_t close_successor_ = 0;
  // The physical widget can be shared by several profile clients. A vault
  // interaction belongs to the selected tab actually mounted in its Bark root.
  views::Widget* MountedVaultWidget() const {
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* host = bark::BarkWindowHost::ForBrowser(owner);
    if (!host || host->closing() || !host->widget() || owner->IsDeleteScheduled() ||
        !owner->IsSelectedForNativeWindow() ||
        owner->GetTabStripModel()->GetActiveTab() != tab ||
        !web_contents() || tab->GetContents() != web_contents() ||
        owner->GetProfile() != web_contents()->GetBrowserContext() ||
        UnloadController::From(owner)->is_attempting_to_close_browser() ||
        UnloadController::From(owner)->owner_close_admitted()) {
      return nullptr;
    }
    return host->IsPageMounted(web_contents()) ? host->widget() : nullptr;
  }
  bool VaultSaveCurrent(uint64_t serial) const {
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    return active_ && !closing_ && !discovery_stopped && vault_save_callback_ &&
        vault_submission_ && serial && vault_submission_->token == serial &&
        web_contents() && tab && tab->GetContents() == web_contents() && owner &&
        !owner->IsDeleteScheduled() && !owner->GetProfile()->IsOffTheRecord() &&
        owner == vault_submission_->owner.get() &&
        MountedVaultWidget();
  }
  void NotifyVaultSave() {
    if (vault_save_notification_posted_) return;
    vault_save_notification_posted_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
        base::BindOnce([](std::weak_ptr<TabObservation> weak) {
          auto self = weak.lock();
          if (!self) return;
          self->vault_save_notification_posted_ = false;
          if (!self->active_ || !self->vault_save_callback_) return;
          auto callback = self->vault_save_callback_;
          // Copies survive a synchronous application callback retiring the offer.
          auto submission = self->vault_submission_;
          NSView* view = nil;
          if (submission && self->VaultSaveCurrent(submission->token)) {
            if (auto* widget = self->web_contents()->GetRenderWidgetHostView())
              view = widget->GetNativeView().GetNativeNSView();
          }
          base::AutoReset depth(&navigation_callback_depth, navigation_callback_depth + 1);
          callback(self->context_.get(), self->token_, view ? submission->token : 0,
              view ? submission->origin.c_str() : "",
              view ? submission->username.c_str() : "",
              view ? submission->password.c_str() : "", (__bridge void*)view);
        }, weak_from_this()));
  }
  void ClearVaultSave() {
    if (!vault_submission_) return;
    vault_submission_.reset();
    NotifyVaultSave();
  }
  void ObserveVaultSave(BarcVaultSaveCallback callback) {
    ClearVaultSave();
    vault_save_callback_ = callback;
    ObserveVaultOwner();
  }
  bool OfferVaultSave(const password_manager::PasswordForm& credentials) {
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    // A newer validated submission supersedes this owner's earlier offer even
    // when unsupported credentials must fall through to the stock Chrome UI.
    if (vault_submission_ && vault_submission_->owner.get() == owner)
      ClearVaultSave();
    const auto origin = url::Origin::Create(credentials.url);
    if (!vault_save_callback_ || !active_ || closing_ || discovery_stopped || !owner ||
        owner->GetProfile()->IsOffTheRecord() || !MountedVaultWidget() ||
        origin.opaque() || !(origin.scheme() == "https" ||
            (origin.scheme() == "http" && net::IsLocalhost(origin.GetURL()))) ||
        credentials.username_value.empty() || credentials.password_value.empty() ||
        credentials.username_value.size() > 65536 || credentials.password_value.size() > 65536) return false;
    const std::string username = base::UTF16ToUTF8(credentials.username_value);
    const std::string password = base::UTF16ToUTF8(credentials.password_value.value());
    if (username.size() > 65536 || password.size() > 65536 ||
        username.find('\0') != std::string::npos || password.find('\0') != std::string::npos) return false;
    CHECK_NE(vault_submission_serial_, UINT64_MAX);
    vault_submission_.emplace(VaultSubmission{++vault_submission_serial_, owner->GetWeakPtr(),
        origin.Serialize(), username, password});
    NotifyVaultSave();
    return true;
  }
  struct VaultPasskey {
    uint64_t serial;
    content::WeakDocumentPtr document;
    base::WeakPtr<BrowserWindowInterface> owner;
    base::WeakPtr<views::Widget> widget;
    int operation;
    std::string arguments;
    base::OnceCallback<void(std::optional<std::string>)> reply;
  };
  std::optional<VaultPasskey> vault_passkey_;
  BarcVaultPasskeyCallback vault_passkey_callback_ = nullptr;
  uint64_t vault_passkey_serial_ = 0;
  bool vault_passkey_notification_posted_ = false;
  bool VaultPasskeyCurrent(uint64_t serial) const {
    if (!serial || !vault_passkey_ || vault_passkey_->serial != serial ||
        !vault_passkey_callback_ || !active_ || closing_ || discovery_stopped || !web_contents()) return false;
    return VaultPasskeyContextCurrent(vault_passkey_->document,vault_passkey_->owner,vault_passkey_->widget);
  }
  bool VaultPasskeyContextCurrent(const content::WeakDocumentPtr& document,
      const base::WeakPtr<BrowserWindowInterface>& expected_owner,
      const base::WeakPtr<views::Widget>& widget) const {
    if (!vault_passkey_callback_ || !active_ || closing_ || discovery_stopped || !web_contents()) return false;
    auto* frame = document.AsRenderFrameHostIfValid();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (!frame || !frame->IsActive() || !frame->IsRenderFrameLive() || !owner ||
        owner != expected_owner.get() || owner->IsDeleteScheduled() ||
        frame->GetBrowserContext() != owner->GetProfile()) return false;
    return widget && MountedVaultWidget() == widget.get();
  }
  void NotifyVaultPasskey() {
    if (vault_passkey_notification_posted_) return;
    vault_passkey_notification_posted_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
        base::BindOnce([](std::weak_ptr<TabObservation> weak) {
          auto self = weak.lock(); if (!self) return;
          self->vault_passkey_notification_posted_ = false;
          auto callback = self->vault_passkey_callback_;
          if (!callback || !self->active_) return;
          uint64_t serial = 0; int operation = 0; std::string arguments;
          NSView* view = nil;
          if (self->vault_passkey_ && self->VaultPasskeyCurrent(self->vault_passkey_->serial)) {
            auto* widget = self->web_contents()->GetRenderWidgetHostView();
            if (widget) view = widget->GetNativeView().GetNativeNSView();
            if (view) { serial = self->vault_passkey_->serial;
              operation = self->vault_passkey_->operation; arguments = self->vault_passkey_->arguments; }
          }
          base::AutoReset depth(&navigation_callback_depth,navigation_callback_depth + 1);
          callback(self->context_.get(),self->token_,serial,operation,arguments.c_str(),(__bridge void*)view);
        },weak_from_this()));
  }
  void CancelVaultPasskey() {
    if (!vault_passkey_) return;
    auto reply = std::move(vault_passkey_->reply);
    vault_passkey_.reset(); NotifyVaultPasskey();
    // Leave native ownership/model stacks before invoking the request handler.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
        base::BindOnce(std::move(reply),std::nullopt));
  }
  void ObserveVaultPasskeys(BarcVaultPasskeyCallback callback) {
    CancelVaultPasskey(); vault_passkey_callback_ = callback; ObserveVaultOwner();
  }
  base::OnceClosure StartVaultPasskey(content::RenderFrameHost* frame,int operation,
      std::string arguments,base::OnceCallback<void(std::optional<std::string>)> reply) {
    auto* tab = tab_.Get(); auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* widget = MountedVaultWidget();
    if (!vault_passkey_callback_ || !frame || !widget ||
        vault_passkey_ || !frame->IsActive() ||
        content::WebContents::FromRenderFrameHost(frame) != web_contents()) {
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
          base::BindOnce(std::move(reply),std::nullopt)); return {};
    }
    CHECK_NE(vault_passkey_serial_,UINT64_MAX);
    const uint64_t serial = ++vault_passkey_serial_;
    vault_passkey_.emplace(VaultPasskey{serial,frame->GetWeakDocumentPtr(),owner->GetWeakPtr(),
        widget->GetWeakPtr(),operation,std::move(arguments),std::move(reply)});
    if (!VaultPasskeyCurrent(serial)) { CancelVaultPasskey(); return {}; }
    NotifyVaultPasskey();
    return base::BindOnce([](std::weak_ptr<TabObservation> weak,uint64_t serial) {
      if (auto self = weak.lock(); self && self->vault_passkey_ && self->vault_passkey_->serial == serial)
        self->CancelVaultPasskey();
    },weak_from_this(),serial);
  }
  bool CompleteVaultPasskey(uint64_t serial,bool accepted,std::optional<std::string> result) {
    if (!vault_passkey_ || vault_passkey_->serial != serial) return false;
    const bool current = VaultPasskeyCurrent(serial);
    auto reply = std::move(vault_passkey_->reply); vault_passkey_.reset(); NotifyVaultPasskey();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
        base::BindOnce(std::move(reply),current && accepted ? std::move(result) : std::nullopt));
    return current;
  }
  // An exact Blink input-driven focus change can precede Autofill parsing.
  // Document identity also prevents a same-origin replacement borrowing it.
  std::optional<content::GlobalDOMNodeId> pending_vault_focus_;
  autofill::KeyPressHandlerRegistration vault_keys_;

  struct VaultFocus {
    uint64_t token;
    content::WeakDocumentPtr document;
    content::WeakDocumentPtr cache_document;
    base::WeakPtr<autofill::AutofillManager> manager;
    base::WeakPtr<BrowserWindowInterface> owner;
    base::WeakPtr<views::Widget> physical_widget;
    autofill::FormGlobalId form;
    autofill::FieldGlobalId field;
    autofill::FieldRendererId username;
    VaultCodeFields code_fields;
    gfx::RectF bounds;
  };
  void NotifyVaultFocus() {
    if (vault_notification_posted_) return;
    vault_notification_posted_ = true;
    // Leave upstream Autofill observer/model stacks before application callouts.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
        base::BindOnce([](std::weak_ptr<TabObservation> weak) {
          auto self = weak.lock();
          if (!self) return;
          self->vault_notification_posted_ = false;
          auto callback = self->vault_callback_;
          if (!callback || !self->active_ || self->closing_ || discovery_stopped) return;
          uint64_t serial = 0;
          std::string origin;
          int kind = 0;
          NSView* native = nil;
          gfx::RectF rect;
          if (self->vault_focus_ && self->VaultCurrent(self->vault_focus_->token)) {
            const auto& focus = *self->vault_focus_;
            serial = focus.token;
            origin = focus.document.AsRenderFrameHostIfValid()->GetLastCommittedOrigin().Serialize();
            kind = focus.code_fields.empty() ? 0 : 1;
            rect = focus.bounds;
            native = self->web_contents()->GetRenderWidgetHostView()->GetNativeView().GetNativeNSView();
          }
          if (!native) serial = 0;
          base::AutoReset depth(&navigation_callback_depth, navigation_callback_depth + 1);
          callback(self->context_.get(), self->token_, serial, origin.c_str(), kind,
                   (__bridge void*)native, rect.x(), rect.y(), rect.width(), rect.height());
        }, weak_from_this()));
  }
  void ClearVaultFocus() {
    pending_vault_focus_.reset();
    if (!vault_focus_) return;
    vault_focus_.reset();
    NotifyVaultFocus();
  }
  void ObserveVault(BarcVaultCallback callback) {
    auto hold = shared_from_this();
    ClearVaultFocus();
    vault_callback_ = callback;
    ObserveVaultOwner();
    ObserveVaultKeys();
    vault_managers_.Reset();
    if (callback && web_contents()) {
      if (auto* client = autofill::ContentAutofillClient::FromWebContents(web_contents()))
        vault_managers_.Observe(client, autofill::ScopedAutofillManagersObservation::InitializationPolicy::kObservePreexistingManagers);
    }
  }
  void ObserveVaultOwner() {
    vault_selection_ = {}; vault_active_ = {}; vault_inactive_ = {}; vault_tab_ = {};
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if ((!vault_callback_ && !vault_passkey_callback_ && !vault_save_callback_) || !owner) return;
    vault_selection_ = owner->RegisterNativeWindowSelectionChanged(base::BindRepeating(
        [](std::weak_ptr<TabObservation> weak) { if (auto self = weak.lock()) self->VaultOwnerChanged(); }, weak_from_this()));
    auto changed = base::BindRepeating([](std::weak_ptr<TabObservation> weak, BrowserWindowInterface*) {
      if (auto self = weak.lock()) self->VaultOwnerChanged();
    }, weak_from_this());
    vault_active_ = owner->RegisterDidBecomeActive(changed);
    vault_inactive_ = owner->RegisterDidBecomeInactive(changed);
    vault_tab_ = owner->RegisterActiveTabDidChange(changed);
  }
  bool VaultCurrent(uint64_t token, bool foreground = true) const {
    if (!token || !vault_callback_ || !vault_focus_ || vault_focus_->token != token ||
        !active_ || closing_ || discovery_stopped || !web_contents()) return false;
    auto* frame = vault_focus_->document.AsRenderFrameHostIfValid();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (!frame || !frame->IsActive() || !frame->IsRenderFrameLive() ||
        owner != vault_focus_->owner.get() || !owner || owner->IsDeleteScheduled() ||
        !owner->IsSelectedForNativeWindow() || owner->GetTabStripModel()->GetActiveTab() != tab ||
        UnloadController::From(owner)->is_attempting_to_close_browser() ||
        UnloadController::From(owner)->owner_close_admitted() ||
        LookupTab(owner, tab_id()) != tab || tab->GetContents() != web_contents() ||
        frame->GetBrowserContext() != owner->GetProfile() ||
        web_contents()->GetFocusedFrame() != frame ||
        autofill::FieldRendererId(frame->GetFocusedDOMNodeId().value()) !=
            vault_focus_->field.renderer_id) return false;
    auto* view = web_contents()->GetRenderWidgetHostView();
    if (!view || (foreground && !view->HasFocus())) return false;
    auto* widget = MountedVaultWidget();
    if (!widget || widget != vault_focus_->physical_widget.get()) return false;
    // Preserve the stock owned-prompt gate; Pawl never restores focus behind
    // an unrelated Chrome permission/install/modal widget.
    for (views::Widget* child : views::Widget::GetAllOwnedWidgets(widget->GetNativeView()))
      if (child->IsVisible()) return false;
    auto* cache_frame = vault_focus_->cache_document.AsRenderFrameHostIfValid();
    auto* manager = vault_focus_->manager.get();
    if (!cache_frame || !manager ||
        static_cast<autofill::ContentAutofillDriver&>(manager->driver()).render_frame_host() != cache_frame) return false;
    const auto* form = manager->FindCachedFormById(vault_focus_->form);
    const auto* field = form ? form->GetFieldById(vault_focus_->field) : nullptr;
    if (!field || !field->is_focusable()) return false;
    const auto code_fields = CodeFieldsFor(*form, *field);
    return code_fields == vault_focus_->code_fields &&
           (!code_fields.empty() || field->IsPasswordInputElement());
  }
  void InvalidateVaultIfNeeded() {
    if (vault_submission_ && !VaultSaveCurrent(vault_submission_->token)) ClearVaultSave();
    if (vault_passkey_ && !VaultPasskeyCurrent(vault_passkey_->serial)) CancelVaultPasskey();
    if (pending_vault_focus_ && !MountedVaultWidget()) pending_vault_focus_.reset();
    if (!vault_focus_) return;
    if (!VaultCurrent(vault_focus_->token, false)) ClearVaultFocus();
    else NotifyVaultFocus();
  }
  void VaultOwnerChanged() {
    pending_vault_focus_.reset();
    ObserveVaultKeys();
    InvalidateVaultIfNeeded();
  }
  void OnWebContentsFocused(content::RenderWidgetHost*) override {
    VaultOwnerChanged();
  }
  void OnWebContentsLostFocus(content::RenderWidgetHost*) override {
    pending_vault_focus_.reset();
    vault_keys_.Unregister();
    InvalidateVaultIfNeeded();
  }
  bool CancelVaultFocus(uint64_t token) {
    if (!vault_focus_ || vault_focus_->token != token) return false;
    ClearVaultFocus();
    return true;
  }
  autofill::FieldGlobalId VaultFieldId(content::RenderFrameHost* frame) const {
    auto* factory = autofill::ContentAutofillDriverFactory::FromWebContents(
        web_contents());
    if (!factory || !frame || !frame->GetFocusedDOMNodeId()) return {};
    for (auto* driver : factory->GetExistingDrivers()) {
      if (static_cast<autofill::ContentAutofillDriver*>(driver)
              ->render_frame_host() == frame) {
        return {driver->GetFrameToken(),
                autofill::FieldRendererId(frame->GetFocusedDOMNodeId().value())};
      }
    }
    return {};
  }
  void OnFocusChangedInPage(const content::FocusedNodeDetails& details) override {
    ClearVaultFocus();
    ObserveVaultKeys();
    using Focus = blink::mojom::FocusType;
    if (!vault_callback_ || !MountedVaultWidget() ||
        (details.focus_type != Focus::kMouse &&
         details.focus_type != Focus::kForward &&
         details.focus_type != Focus::kBackward)) return;
    auto* view = web_contents()->GetRenderWidgetHostView();
    auto* frame = details.global_dom_node_id.document.AsRenderFrameHostIfValid();
    if (!view || !view->HasFocus() || !frame ||
        frame != web_contents()->GetFocusedFrame() ||
        !details.global_dom_node_id.target_element_dom_id ||
        frame->GetFocusedDOMNodeId() !=
            details.global_dom_node_id.target_element_dom_id) return;
    pending_vault_focus_ = details.global_dom_node_id;
    TryAdmitPendingVaultFocus();
  }
  void OnAfterFormsSeen(autofill::AutofillManager&, base::span<const autofill::FormGlobalId>,
                       base::span<const autofill::FormGlobalId>) override {
    InvalidateVaultIfNeeded();
    TryAdmitPendingVaultFocus();
  }
  void OnAutofillManagerStateChanged(autofill::AutofillManager& manager,
      autofill::AutofillManager::LifecycleState,
      autofill::AutofillManager::LifecycleState state) override {
    if (vault_focus_ && vault_focus_->manager.get() == &manager &&
        state != autofill::AutofillManager::LifecycleState::kActive) ClearVaultFocus();
  }
  void OnAfterFocusOnFormField(autofill::AutofillManager& manager,
      autofill::FormGlobalId form, autofill::FieldGlobalId field) override {
    if (!pending_vault_focus_) return;
    auto* frame = pending_vault_focus_->document.AsRenderFrameHostIfValid();
    if (frame && frame->GetFocusedDOMNodeId() ==
                     pending_vault_focus_->target_element_dom_id &&
        VaultFieldId(frame) == field)
      AdmitVaultFieldGesture(manager, form, field);
  }
  void TryAdmitPendingVaultFocus() {
    if (!pending_vault_focus_) return;
    auto* frame = pending_vault_focus_->document.AsRenderFrameHostIfValid();
    if (!frame || frame != web_contents()->GetFocusedFrame() ||
        frame->GetFocusedDOMNodeId() !=
            pending_vault_focus_->target_element_dom_id) {
      ClearVaultFocus();
      return;
    }
    AdmitCachedVaultField(frame);
  }
  bool AdmitCachedVaultField(content::RenderFrameHost* frame) {
    const auto field = VaultFieldId(frame);
    if (!field.renderer_id) return false;
    auto* factory = autofill::ContentAutofillDriverFactory::FromWebContents(
        web_contents());
    autofill::AutofillManager* target = nullptr;
    autofill::FormGlobalId form;
    for (auto* driver : factory->GetExistingDrivers()) {
      auto& manager = driver->GetAutofillManager();
      if (driver->GetLifecycleState() !=
          autofill::AutofillManager::LifecycleState::kActive) continue;
      if (const auto* found = manager.FindCachedFormById(field)) {
        if (target) return false;
        target = &manager;
        form = found->global_id();
      }
    }
    if (!target) return false;
    AdmitVaultFieldGesture(*target, form, field);
    return vault_focus_.has_value();
  }
  void ObserveVaultKeys() {
    vault_keys_.Unregister();
    if (!vault_callback_ || !MountedVaultWidget()) return;
    auto* frame = web_contents()->GetFocusedFrame();
    if (!frame || !frame->GetRenderWidgetHost()) return;
    vault_keys_.Register(frame, base::BindRepeating(
        [](std::weak_ptr<TabObservation> weak, content::WeakDocumentPtr document,
           const input::NativeWebKeyboardEvent& event) {
          auto self = weak.lock();
          return self && self->OpenVaultForNativeArrow(document, event);
        }, weak_from_this(), frame->GetWeakDocumentPtr()));
  }
  bool OpenVaultForNativeArrow(const content::WeakDocumentPtr& document,
                               const input::NativeWebKeyboardEvent& event) {
    constexpr int kModified = blink::WebInputEvent::kShiftKey |
        blink::WebInputEvent::kControlKey | blink::WebInputEvent::kAltKey |
        blink::WebInputEvent::kMetaKey | blink::WebInputEvent::kIsAutoRepeat;
    NSEvent* native = event.os_event.Get();
    if (!native || native.type != NSEventTypeKeyDown ||
        event.windows_key_code != ui::VKEY_DOWN ||
        (event.GetModifiers() & kModified)) return false;
    auto* frame = document.AsRenderFrameHostIfValid();
    auto* widget = MountedVaultWidget();
    if (!frame || !widget || frame != web_contents()->GetFocusedFrame())
      return false;
    NSWindow* window = widget->GetNativeWindow().GetNativeNSWindow();
    auto* view = web_contents()->GetRenderWidgetHostView();
    if (!window || native.window != window || !window.isKeyWindow ||
        !view || !view->HasFocus()) return false;
    NSResponder* responder = window.firstResponder;
    NSView* page = view->GetNativeView().GetNativeNSView();
    if (![responder isKindOfClass:NSView.class] ||
        ![(NSView*)responder isDescendantOf:page] ||
        ([responder conformsToProtocol:@protocol(NSTextInputClient)] &&
         [(id<NSTextInputClient>)responder hasMarkedText])) return false;
    return AdmitCachedVaultField(frame);
  }
  void AdmitVaultFieldGesture(autofill::AutofillManager& manager,
      autofill::FormGlobalId form_id, autofill::FieldGlobalId field_id) {
    auto hold = shared_from_this();
    ClearVaultFocus();
    if (!vault_callback_ || !active_ || closing_ || discovery_stopped) return;
    auto* cache_frame = static_cast<autofill::ContentAutofillDriver&>(manager.driver()).render_frame_host();
    auto* factory = autofill::ContentAutofillDriverFactory::FromWebContents(web_contents());
    content::RenderFrameHost* frame = nullptr;
    if (factory) for (auto* driver : factory->GetExistingDrivers()) {
      if (driver->GetFrameToken() == field_id.frame_token)
        frame = static_cast<autofill::ContentAutofillDriver*>(driver)->render_frame_host();
    }
    if (!frame || frame->GetBrowserContext() != cache_frame->GetBrowserContext()) return;
    const auto origin = frame->GetLastCommittedOrigin();
    if (origin.opaque() || !(origin.scheme() == "https" ||
        (origin.scheme() == "http" && (origin.host() == "localhost" || origin.host() == "127.0.0.1")))) return;
    auto pair = manager.FindFormAndField(form_id, field_id);
    if (!pair.form_structure || !pair.autofill_field) return;
    auto code_fields = CodeFieldsFor(*pair.form_structure, *pair.autofill_field);
    if (code_fields.empty() && !pair.autofill_field->IsPasswordInputElement()) return;
    autofill::FieldRendererId username;
    if (code_fields.empty()) {
      for (const auto& field : pair.form_structure->fields()) {
        if (field->host_frame() == field_id.frame_token && field->is_focusable() &&
            (field->Type().GetTypes().contains(autofill::USERNAME) || field->autocomplete_attribute() == "username")) {
          if (username) return; // Ambiguous form never selects a username by guess.
          username = field->renderer_id();
        }
      }
    }
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* widget = MountedVaultWidget();
    if (!widget) return;
    CHECK_NE(vault_serial_, UINT64_MAX);
    const uint64_t serial = ++vault_serial_;
    vault_focus_.emplace(VaultFocus{serial, frame->GetWeakDocumentPtr(), cache_frame->GetWeakDocumentPtr(), manager.GetWeakPtr(), owner->GetWeakPtr(), widget->GetWeakPtr(), form_id, field_id, username, std::move(code_fields), pair.autofill_field->bounds()});
    if (!VaultCurrent(serial)) { vault_focus_.reset(); return; }
    NotifyVaultFocus();
  }
  bool FillVault(uint64_t token, const char* username, const char* secret) {
    auto hold = shared_from_this();
    if (navigation_callback_depth || !username || !secret ||
        // The trusted C caller supplies NUL-terminated borrowed UTF-8.
        // Bound parsing without retaining its pointers after this call.
        UNSAFE_BUFFERS(strnlen(username, 65537)) > 65536 ||
        UNSAFE_BUFFERS(strnlen(secret, 65537)) > 65536 ||
        !base::IsStringUTF8(username) || !base::IsStringUTF8(secret) || !VaultCurrent(token)) return false;
    const auto request = *vault_focus_;
    auto* frame = request.document.AsRenderFrameHostIfValid();
    auto* driver = password_manager::ContentPasswordManagerDriver::GetForRenderFrameHost(frame);
    if (!driver) return false;
    // Consume before sending a typed driver command; no reusable secret capability.
    vault_focus_.reset();
    if (!request.code_fields.empty()) {
      const std::string_view code(secret);
      if (code.empty() || code.size() > 8 || !base::IsStringASCII(code))
        return false;
      const auto& targets = request.code_fields;
      if (targets.size() > 1 && code.size() != targets.size()) return false;
      const auto* form = request.manager->FindCachedFormById(request.form);
      const auto* trigger = form->GetFieldById(request.field);
      if (targets.size() == 1 && trigger->max_length() && code.size() > trigger->max_length())
        return false;
      // Send one same-document Autofill operation so page input listeners receive
      // Chromium's normal fill events. There is no refill, submit, or page script.
      std::vector<autofill::FormFieldData> fields;
      absl::flat_hash_map<autofill::FieldGlobalId, autofill::FieldType> types;
      for (const auto& target : targets) {
        auto& data = fields.emplace_back(*form->GetFieldById(target));
        data.set_value(base::ASCIIToUTF16(targets.size() == 1 ? code :
                                          code.substr(fields.size() - 1, 1)));
        data.set_is_autofilled_according_to_renderer(true);
        data.set_force_override(true);
        types.emplace(target, autofill::ONE_TIME_CODE);
      }
      return request.manager->driver().ApplyFormAction(
          autofill::mojom::FormActionType::kFill, autofill::mojom::ActionPersistence::kFill,
          fields, autofill::FillId::Create(), /*supports_refill=*/false,
          trigger->origin(), types).size() == targets.size();
    }
    driver->FillSuggestionById(request.username, request.field.renderer_id,
        base::UTF8ToUTF16(username), base::UTF8ToUTF16(secret),
        autofill::AutofillSuggestionTriggerSource::kManualFallbackPasswords);
    return true;
  }

  bool closing() const { return closing_; }
  void RecordNativeBlock(int64_t navigation, const GURL& url) {
    if (active_ && !closing_ && navigation && navigation_ == navigation &&
        url.SchemeIsHTTPOrHTTPS()) blocked_url_ = url;
  }
  bool NativeBlockCurrent(int64_t navigation, const GURL& url) const {
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    return active_ && !closing_ && !discovery_stopped && web_contents() &&
        navigation_ == navigation && blocked_url_ == url && owner &&
        !owner->IsDeleteScheduled() && !UnloadController::From(owner)->owner_close_admitted() &&
        !UnloadController::From(owner)->is_attempting_to_close_browser() &&
        LookupTab(owner, tab_id()) == tab && tab->GetContents() == web_contents() &&
        web_contents()->GetBrowserContext() == owner->GetProfile();
  }
  void ShowNativeBlock(int64_t navigation, const GURL& url) {
    if (!NativeBlockCurrent(navigation, url)) return;
    auto* manager = infobars::ContentInfoBarManager::FromWebContents(web_contents());
    if (!manager) return;
    manager->AddInfoBar(ConfirmInfoBar::Create(std::make_unique<NativeBlockInfoBar>(
        base::BindRepeating([](std::weak_ptr<TabObservation> weak,
                              int64_t navigation, GURL url) {
          auto self = weak.lock();
          if (!self || !self->NativeBlockCurrent(navigation, url)) return;
          auto* tab = self->tab_.Get();
          auto* owner = tab->GetBrowserWindowInterface();
          if (!owner->IsSelectedForNativeWindow() ||
              owner->GetTabStripModel()->GetActiveTab() != tab) return;
          self->Emit(BARC_TAB_CONTINUE_NATIVE_BLOCK, 0, 0, &url);
        }, weak_from_this(), navigation, url))), true);
  }
  bool EnablePeek(int capability) {
    if (!active_ || closing_) return false;
    peek_enabled_ = capability & BARC_TAB_PEEK_CAPABLE;
    peek_on_shift_click_ = capability & BARC_TAB_PEEK_ON_SHIFT_CLICK;
    if (!peek_enabled_) { peek_request_.reset(); peek_current_serial_ = 0; }
    return true;
  }
  bool PeeksOnShiftClick() const { return peek_on_shift_click_; }
  bool TakeOptionClick() { return std::exchange(option_click_, false); }
  struct PeekRequest {
    PeekRequest(content::RenderFrameHost* frame, content::WebContents* contents,
                BrowserWindowInterface* owner, const content::OpenURLParams& params)
        : document(frame->GetWeakDocumentPtr()),
          main_document(contents->GetPrimaryMainFrame()->GetWeakDocumentPtr()),
          owner(owner->GetWeakPtr()), params(params) {}
    content::WeakDocumentPtr document;
    content::WeakDocumentPtr main_document;
    base::WeakPtr<BrowserWindowInterface> owner;
    content::OpenURLParams params;
  };
  bool CanRequestPeek(content::RenderFrameHost* frame) const {
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (!owner || owner->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
        !active_ || closing_ || !peek_enabled_ || PeekRoleFor(tab) ||
        barc::IsPeekCloseCommitted(tab) || !frame || !frame->IsActive() ||
        !web_contents() ||
        content::WebContents::FromRenderFrameHost(frame) != web_contents() ||
        !web_contents()->GetPrimaryMainFrame() ||
        Window(owner->GetSessionID().id()) != owner ||
        owner->GetProfile() != frame->GetBrowserContext() ||
        UnloadController::From(owner)->owner_close_admitted() ||
        !barc::CanResolveApplicationBrowser()) {
      return false;
    }

    const bool selected = owner->IsSelectedForNativeWindow() &&
                          owner->GetTabStripModel()->GetActiveTab() == tab;
    if (auto* host = bark::BarkWindowHost::ForBrowser(owner)) {
      return selected && !host->closing() &&
             !UnloadController::From(owner)->is_attempting_to_close_browser();
    }

    auto* view = BrowserView::GetBrowserViewForBrowser(owner);
    std::array<char, 37> identity{};
    const int32_t window = owner->GetSessionID().id();
    return view && !view->browser_widget()->HasPhysicalClosePending() &&
           (selected || view->browser_widget()->IsBarcPresentedPane(tab)) &&
           (barc_window_profile_uuid(window, identity.data(), identity.size()) ==
                identity.size() ||
            barc_window_private_session_uuid(window, identity.data(),
                                             identity.size()) == identity.size());
  }
  void RequestPeek(content::RenderFrameHost* frame,
                   const content::OpenURLParams& params) {
    if (!CanRequestPeek(frame) || !params.url.is_valid() ||
        params.url.SchemeIs("javascript") ||
        peek_serial_ == std::numeric_limits<int32_t>::max())
      return;
    auto keep_alive = shared_from_this();
    auto* owner = tab_.Get()->GetBrowserWindowInterface();
    if (!owner->IsSelectedForNativeWindow() ||
        owner->GetTabStripModel()->GetActiveTab() != tab_.Get()) {
      const auto document = frame->GetWeakDocumentPtr();
      BrowserView::GetBrowserViewForBrowser(owner)->browser_widget()
          ->SelectBarcPresentedContents(web_contents());
      frame = document.AsRenderFrameHostIfValid();
      auto* tab = tab_.Get();
      owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
      if (!frame || !owner || !owner->IsSelectedForNativeWindow() ||
          owner->GetTabStripModel()->GetActiveTab() != tab || !CanRequestPeek(frame)) {
        return;
      }
      web_contents()->Focus();
    }
    peek_request_.emplace(frame, web_contents(), owner, params);
    ++peek_serial_;
    peek_current_serial_ = peek_serial_;
    Emit(BARC_TAB_PEEK_REQUESTED, peek_serial_, 0, &params.url);
  }
  bool PeekRequestIsCurrent(int32_t serial) const {
    if (serial <= 0 || serial != peek_serial_ || !peek_request_)
      return false;
    auto* frame = peek_request_->document.AsRenderFrameHostIfValid();
    return CanRequestPeek(frame) && peek_request_->owner &&
        tab_.Get()->GetBrowserWindowInterface() == peek_request_->owner.get() &&
        peek_request_->main_document.AsRenderFrameHostIfValid() ==
            web_contents()->GetPrimaryMainFrame();
  }
  std::optional<PeekRequest> TakePeekRequest(int32_t serial) {
    if (!PeekRequestIsCurrent(serial))
      return std::nullopt;
    auto request = std::move(peek_request_);
    peek_request_.reset();
    return request;
  }
  bool PeekSerialIsCurrent(int32_t serial) const {
    return active_ && !closing_ && peek_current_serial_ == serial;
  }
  void Cancel() {
    auto keep_alive = shared_from_this();
    CancelFiles(false);
    ObserveVault(nullptr);
    ObserveVaultSave(nullptr);
    ObserveVaultPasskeys(nullptr);
    active_ = false;
    CancelPicker();
    CancelScript();
    peek_enabled_ = false;
    peek_request_.reset();
    peek_current_serial_ = 0;
    if (thumbnail_) {
      thumbnail_->cancelled.Set();
      thumbnail_.reset();
    }
    site_data_remover_.Reset();
    site_data_.reset();
    translation_receiver_.reset();
    translation_callback_ = nullptr;
    translation_document_ = {};
    media_callback_ = nullptr;
    media_receiver_.reset();
    media_snapshot_.reset();
    media_document_ = {};
    media_refresh_pending_ = false;
    active_ = false;
    callback_ = nullptr;
    context_ = nullptr;
    load_progress_callback_ = nullptr;
    load_progress_tasks_.InvalidateWeakPtrs();
    favicon_callback_ = nullptr;
    StopFaviconObservation();
    Observe(nullptr);
    UnbindOwner();
    detach_ = {};
    insert_ = {};
    discard_ = {};
  }
  bool CancelCapture(uint64_t request) {
    if (!thumbnail_ || thumbnail_->request != request) return false;
    thumbnail_->cancelled.Set();
    thumbnail_->callback = nullptr;
    // Keep the single slot occupied until the compositor/encoding callback
    // retires. Cancellation must not enqueue another large copy per call.
    return true;
  }
  bool ScreenshotAllowed() const {
    return web_contents() &&
        extensions::ExtensionsBrowserClient::Get()->IsScreenshotRestricted(web_contents()).has_value();
  }
  bool CaptureThumbnail(uint64_t request, BarcTabThumbnailCallback callback,
                        int32_t screenshot_width = 0) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || discovery_stopped || thumbnail_ || !request || !callback || !web_contents() ||
        screenshot_width < 0 || screenshot_width > 4096)
      return false;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* view = web_contents()->GetRenderWidgetHostView();
    auto* document = web_contents()->GetPrimaryMainFrame();
    if (!owner || owner->IsDeleteScheduled() ||
        UnloadController::From(owner)->owner_close_admitted() ||
        UnloadController::From(owner)->is_attempting_to_close_browser() ||
        LookupTab(owner, tab_id()) != tab || tab->GetContents() != web_contents() ||
        web_contents()->GetBrowserContext() != owner->GetProfile() ||
        !view || !document || !document->IsActive() || !ScreenshotAllowed())
      return false;
    if (screenshot_width) {
      if (!view->IsSurfaceAvailableForCopy()) return false;
    } else if (!owner->IsSelectedForNativeWindow() ||
        owner->GetTabStripModel()->GetActiveTab() != tab ||
        web_contents()->GetVisibility() != content::Visibility::VISIBLE || !view->IsShowing()) {
      return false;
    }
    const gfx::Size bounds = view->GetViewBounds().size();
    if (bounds.IsEmpty())
      return false;
    // Scale at copy time; never allocate a full-resolution screenshot first.
    const double native_scale = screenshot_width ? view->GetDeviceScaleFactor() : 1.0;
    const double scale = screenshot_width
        ? std::min(native_scale, static_cast<double>(screenshot_width) / bounds.width())
        : std::min(1.0, 400.0 / std::max(bounds.width(), bounds.height()));
    const double width = std::max(1.0, std::floor(bounds.width() * scale));
    const double height = std::max(1.0, std::floor(bounds.height() * scale));
    if (!std::isfinite(width) || !std::isfinite(height) ||
        width > 4096 || height > 4096 || width * height > 8 * 1024 * 1024)
      return false;
    const gfx::Size output(static_cast<int>(width), static_cast<int>(height));
    auto capture = std::make_shared<ThumbnailCapture>();
    capture->screenshot = screenshot_width != 0;
    capture->output = output;
    capture->owner = owner->GetWeakPtr();
    capture->document = document->GetWeakDocumentPtr();
    capture->navigation = navigation_;
    capture->request = request;
    capture->callback = callback;
    thumbnail_ = capture;
    view->CopyFromSurface(gfx::Rect(), output, base::Seconds(1),
        base::BindPostTaskToCurrentDefault(base::BindOnce(
            [](std::weak_ptr<TabObservation> weak,
               std::shared_ptr<ThumbnailCapture> capture,
               const content::CopyFromSurfaceResult& result) {
              if (auto self = weak.lock())
                self->ThumbnailCopied(std::move(capture), result);
            }, weak_from_this(), capture)));
    return true;
  }
  struct FileRequest : network::SimpleURLLoaderStreamConsumer,
                       std::enable_shared_from_this<FileRequest> {
    std::weak_ptr<TabObservation> observer;
    base::WeakPtr<BrowserWindowInterface> owner;
    content::WeakDocumentPtr document;
    int64_t navigation=0, bytes=0;
    uint64_t id=0;
    GURL url;
    base::FilePath temporary;
    std::string basename;
    base::ScopedFD directory;
    BarcFileCallback callback=nullptr;
    std::unique_ptr<network::SimpleURLLoader> loader;
    std::unique_ptr<net::FileStream> stream;
    scoped_refptr<net::DrainableIOBuffer> buffer;
    base::OnceClosure resume;
    ~FileRequest() override {
      if (directory.is_valid() && !basename.empty()) unlinkat(directory.get(),basename.c_str(),0);
    }
    void OnDataReceived(std::string_view data,base::OnceClosure continue_reading) override {
      auto request=shared_from_this();
      if (auto self=observer.lock()) self->FileData(request,data,std::move(continue_reading));
    }
    void OnComplete(bool success) override {
      auto request=shared_from_this();
      if (auto self=observer.lock()) self->FileComplete(request,success);
    }
    void OnRetry(base::OnceClosure) override {
      auto request=shared_from_this();
      if (auto self=observer.lock()) self->FinishFile(request,BARC_FILE_FAILED);
    }
  };
  struct PreparedFile {
    PreparedFile()=default;
    PreparedFile(PreparedFile&&)=default;
    PreparedFile& operator=(PreparedFile&& other) {
      if (this!=&other) {
        Cleanup();directory=std::move(other.directory);file=std::move(other.file);
        basename=std::move(other.basename);path=std::move(other.path);
      }
      return *this;
    }
    ~PreparedFile(){Cleanup();}
    void Cleanup(){if (directory.is_valid() && !basename.empty()) unlinkat(directory.get(),basename.c_str(),0);}
    base::ScopedFD directory;
    base::File file;
    std::string basename;
    base::FilePath path;
  };
  static void DeleteOwnedFile(base::ScopedFD directory,std::string basename,base::File file={}) {
    PreparedFile owned;owned.directory=std::move(directory);owned.basename=std::move(basename);owned.file=std::move(file);
    // The RAII payload also unlinks if shutdown rejects/drops this cleanup task.
    base::ThreadPool::PostTask(FROM_HERE,{base::MayBlock()},base::BindOnce(
        [](PreparedFile owned) {},std::move(owned)));
  }
  bool FileCurrent(const std::shared_ptr<FileRequest>& request,bool admitted=true) const {
    auto* frame = request->document.AsRenderFrameHostIfValid();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    const auto found=file_requests_.find(request->id);
    return (!admitted || (found!=file_requests_.end() && found->second==request)) &&
        active_ && !closing_ && !discovery_stopped && frame && frame->IsActive() &&
        web_contents() && frame == web_contents()->GetPrimaryMainFrame() &&
        navigation_ == request->navigation && owner && owner == request->owner.get() &&
        !owner->IsDeleteScheduled() && Window(owner->GetSessionID().id()) == owner &&
        LookupTab(owner, tab_id()) == tab && tab->GetContents() == web_contents() &&
        frame->GetBrowserContext() == owner->GetProfile() && !owner->GetProfile()->ShutdownStarted() &&
        !IsProfileDirectoryPendingDeletion(owner->GetProfile()->GetPath()) &&
        !UnloadController::From(owner)->owner_close_admitted() &&
        !UnloadController::From(owner)->is_attempting_to_close_browser();
  }
  void FinishFile(std::shared_ptr<FileRequest> request, int result, int status=0,
                  std::string mime={}, int64_t bytes=0, bool deliver=true) {
    auto hold = shared_from_this();
    auto found = file_requests_.find(request->id);
    if (found == file_requests_.end() || found->second != request) return;
    file_requests_.erase(found);
    if (file_requests_.empty()) file_profile_observation_.Reset();
    auto callback = std::exchange(request->callback, nullptr);
    request->loader.reset();
    request->stream.reset(); // Cancels writes using its descriptor, never a pathname.
    request->buffer=nullptr;request->resume.Reset();
    int descriptor=-1;
    const std::string temporary=request->temporary.value();
    if (result==BARC_FILE_OK && deliver && active_) descriptor=request->directory.release();
    else DeleteOwnedFile(std::move(request->directory),std::move(request->basename));
    if (deliver && active_ && callback) {
      base::AutoReset<int> scope(&navigation_callback_depth,navigation_callback_depth+1);
      callback(context_.get(),token_,request->id,result,status,
          descriptor>=0 ? temporary.c_str():"",mime.c_str(),bytes,descriptor);
    }
  }
  void CancelFiles(bool deliver=true) {
    auto requests = file_requests_;
    for (auto& [id, request] : requests) FinishFile(request, BARC_FILE_CANCELLED, 0, {}, 0, deliver);
  }
  void OnProfileMarkedForPermanentDeletion(Profile* profile) override {
    CancelFilesForProfile(profile->GetPath());
  }
  void OnProfileManagerDestroying() override { CancelFiles(); }
  bool CancelFile(uint64_t id) {
    auto found=file_requests_.find(id);
    if (found==file_requests_.end()) return false;
    FinishFile(found->second, BARC_FILE_CANCELLED);return true;
  }
  void CancelFilesForProfile(const base::FilePath& path) {
    if (web_contents() && Profile::FromBrowserContext(web_contents()->GetBrowserContext())->GetPath()==path)
      CancelFiles();
  }
  bool DownloadFile(uint64_t id, GURL url, base::FilePath directory, BarcFileCallback callback) {
    auto hold=shared_from_this();
    if (navigation_callback_depth || !id || !callback || file_requests_.size()>=6 ||
        file_requests_.contains(id) || !url.is_valid() || !url.SchemeIs("https") ||
        url.has_username() || url.has_password() || !directory.IsAbsolute() || !web_contents()) return false;
    auto* tab=tab_.Get();auto* owner=tab ? tab->GetBrowserWindowInterface():nullptr;
    auto* frame=web_contents()->GetPrimaryMainFrame();
    if (!owner || !frame) return false;
    auto request=std::make_shared<FileRequest>();
    request->id=id;request->owner=owner->GetWeakPtr();request->document=frame->GetWeakDocumentPtr();
    request->navigation=navigation_;request->url=std::move(url);request->callback=callback;
    if (!FileCurrent(request,false)) return false;
    if (!g_browser_process || !g_browser_process->profile_manager()) return false;
    request->observer=weak_from_this();
    file_requests_.emplace(id,request);
    if (!file_profile_observation_.IsObserving()) file_profile_observation_.Observe(g_browser_process->profile_manager());
    base::ThreadPool::PostTaskAndReplyWithResult(FROM_HERE,{base::MayBlock()},
        base::BindOnce([](base::FilePath directory) {
          PreparedFile prepared;base::FilePath canonical;
          if (!base::NormalizeFilePath(directory,&canonical) || canonical!=directory) return prepared;
          prepared.directory.reset(open(directory.value().c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));
          struct stat opened{},named{};
          if (!prepared.directory.is_valid() || fstat(prepared.directory.get(),&opened) ||
              stat(directory.value().c_str(),&named) || opened.st_dev!=named.st_dev || opened.st_ino!=named.st_ino)
            return prepared;
          prepared.basename=".devmcp-"+base::Uuid::GenerateRandomV4().AsLowercaseString();
          const int file=openat(prepared.directory.get(),prepared.basename.c_str(),O_CREAT|O_EXCL|O_WRONLY|O_CLOEXEC|O_NOFOLLOW,0600);
          if (file>=0) {prepared.file=base::File(file);prepared.path=directory.AppendASCII(prepared.basename);}
          else prepared.basename.clear();
          return prepared;
        },std::move(directory)),
        base::BindOnce([](std::weak_ptr<TabObservation> weak,std::shared_ptr<FileRequest> request,PreparedFile prepared) {
          auto self=weak.lock();
          if (!self || !self->file_requests_.contains(request->id) || self->file_requests_.at(request->id)!=request) {
            DeleteOwnedFile(std::move(prepared.directory),std::move(prepared.basename),std::move(prepared.file));return;
          }
          request->directory=std::move(prepared.directory);request->basename=std::move(prepared.basename);
          request->temporary=std::move(prepared.path);
          if (!prepared.file.IsValid()) {self->FinishFile(request,BARC_FILE_FAILED);return;}
          request->stream=std::make_unique<net::FileStream>(std::move(prepared.file),
              base::ThreadPool::CreateSequencedTaskRunner({base::MayBlock(),base::TaskPriority::USER_VISIBLE}));
          self->StartFile(request);
        },weak_from_this(),request));
    return true;
  }
  void StartFile(std::shared_ptr<FileRequest> request) {
    auto hold=shared_from_this();
    if (!FileCurrent(request)) {FinishFile(request,BARC_FILE_CANCELLED);return;}
    if (request->temporary.empty()) {FinishFile(request,BARC_FILE_FAILED);return;}
    auto* frame=request->document.AsRenderFrameHostIfValid();
    auto resource=std::make_unique<network::ResourceRequest>();
    resource->url=request->url;
    resource->site_for_cookies=frame->GetIsolationInfoForSubresources().site_for_cookies();
    resource->request_initiator=frame->GetLastCommittedOrigin();
    resource->trusted_params.emplace();
    resource->trusted_params->isolation_info=frame->GetIsolationInfoForSubresources();
    resource->credentials_mode=network::mojom::CredentialsMode::kInclude;
    resource->load_flags=net::LOAD_DO_NOT_SAVE_COOKIES | net::LOAD_DISABLE_CACHE;
    resource->do_not_prompt_for_login=true;
    const auto referrer=content::Referrer::SanitizeForRequest(request->url,
        content::Referrer(frame->GetLastCommittedURL(),network::mojom::ReferrerPolicy::kDefault));
    resource->referrer=referrer.url;
    resource->referrer_policy=content::Referrer::ReferrerPolicyForUrlRequest(referrer.policy);
    const auto& user_agent=web_contents()->GetUserAgentOverride();
    if (!user_agent.ua_string_override.empty()) resource->headers.SetHeader("User-Agent",user_agent.ua_string_override);
    static constexpr auto annotation=net::DefineNetworkTrafficAnnotation("barc_devmcp_download",R"(
      semantics { sender:"Nook DevMCP download tool" description:"User-authorized HTTPS GET to an owned temporary file in the configured tool directory." trigger:"Authorized developer tool call." data:"The exact Agent profile's normal destination cookies, user agent and sanitized referrer." destination:WEBSITE }
      policy { cookies_allowed:YES cookies_store:"The exact Agent profile storage partition." setting:"Developer mode and local browser tools must both be enabled." policy_exception_justification:"Explicit authenticated local developer tool request." })");
    request->loader=network::SimpleURLLoader::Create(std::move(resource),annotation);
    request->loader->SetTimeoutDuration(base::Seconds(30));
    request->loader->SetOnRedirectCallback(base::BindRepeating(
        [](std::weak_ptr<TabObservation> weak,std::weak_ptr<FileRequest> pending,const GURL&,
           const net::RedirectInfo& redirect,const network::mojom::URLResponseHead& response,std::vector<std::string>*) {
          auto self=weak.lock();auto request=pending.lock();if (!self || !request) return;
          if (!self->FileCurrent(request)) self->FinishFile(request,BARC_FILE_CANCELLED);
          else if (!redirect.new_url.SchemeIs("https") || redirect.new_url.has_username() || redirect.new_url.has_password())
            self->FinishFile(request,BARC_FILE_HTTP,response.headers ? response.headers->response_code():0);
        },weak_from_this(),std::weak_ptr<FileRequest>(request)));
    auto factory=frame->GetStoragePartition()->GetURLLoaderFactoryForBrowserProcess();
    if (!FileCurrent(request)) {FinishFile(request,BARC_FILE_CANCELLED);return;}
    request->loader->DownloadAsStream(factory.get(),request.get());
  }
  void FileData(std::shared_ptr<FileRequest> request,std::string_view data,base::OnceClosure resume) {
    auto hold=shared_from_this();
    if (!FileCurrent(request)) {FinishFile(request,BARC_FILE_CANCELLED);return;}
    if (data.size()>100*1024*1024-static_cast<size_t>(request->bytes)) {FinishFile(request,BARC_FILE_TOO_LARGE);return;}
    // Pinned network loading_params.cc caps its pipe at 2MiB. Keep at most
    // one such chunk while FileStream applies backpressure; never a whole body.
    if (data.size()>2*1024*1024 || request->buffer) {FinishFile(request,BARC_FILE_FAILED);return;}
    request->buffer=base::MakeRefCounted<net::DrainableIOBuffer>(
        base::MakeRefCounted<net::StringIOBuffer>(std::string(data)),data.size());
    request->resume=std::move(resume);WriteFile(request);
  }
  void WriteFile(std::shared_ptr<FileRequest> request) {
    if (!FileCurrent(request)) {FinishFile(request,BARC_FILE_CANCELLED);return;}
    auto result=request->stream->Write(request->buffer.get(),request->buffer->BytesRemaining(),
        base::BindOnce([](std::weak_ptr<TabObservation> weak,std::weak_ptr<FileRequest> pending,
                          base::expected<base::ByteSize,net::Error> result) {
          if (auto self=weak.lock()) if (auto request=pending.lock()) self->FileWritten(request,std::move(result));
        },weak_from_this(),std::weak_ptr<FileRequest>(request)));
    if (result || result.error()!=net::ERR_IO_PENDING) FileWritten(request,std::move(result));
  }
  void FileWritten(std::shared_ptr<FileRequest> request,base::expected<base::ByteSize,net::Error> result) {
    auto hold=shared_from_this();
    if (!FileCurrent(request)) {FinishFile(request,BARC_FILE_CANCELLED);return;}
    if (!result || result->InBytes()<=0 || result->InBytes()>static_cast<uint64_t>(request->buffer->BytesRemaining())) {
      FinishFile(request,BARC_FILE_FAILED);return;
    }
    const int bytes=static_cast<int>(result->InBytes());request->bytes+=bytes;request->buffer->DidConsume(bytes);
    if (request->buffer->BytesRemaining()) {WriteFile(request);return;}
    request->buffer=nullptr;
    auto resume=std::move(request->resume);std::move(resume).Run();
  }
  void FileComplete(std::shared_ptr<FileRequest> request,bool success) {
    auto hold=shared_from_this();
    if (!FileCurrent(request)) {FinishFile(request,BARC_FILE_CANCELLED);return;}
    const auto* response=request->loader->ResponseInfo();
    const int status=response && response->headers ? response->headers->response_code():0;
    std::string mime;if (response && response->headers) response->headers->GetMimeType(&mime);
    if (!success || request->buffer) {
      FinishFile(request,status && (status<200 || status>=300)?BARC_FILE_HTTP:BARC_FILE_FAILED,status,mime);return;
    }
    request->stream->Close(base::BindOnce(
        [](std::weak_ptr<TabObservation> weak,std::weak_ptr<FileRequest> pending,int status,std::string mime,net::Error result) {
          auto self=weak.lock();auto request=pending.lock();if (!self || !request) return;
          self->FinishFile(request,!self->FileCurrent(request)?BARC_FILE_CANCELLED:
              (result==net::OK?BARC_FILE_OK:BARC_FILE_FAILED),status,std::move(mime),request->bytes);
        },weak_from_this(),std::weak_ptr<FileRequest>(request),status,std::move(mime)));
  }
  std::map<uint64_t,std::shared_ptr<FileRequest>> file_requests_;
  base::ScopedObservation<ProfileManager,ProfileManagerObserver> file_profile_observation_{this};
  bool TranslationCurrent() const {
    auto* frame = translation_document_.AsRenderFrameHostIfValid();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    return !discovery_stopped && active_ && !closing_ && frame && web_contents() &&
        frame == web_contents()->GetPrimaryMainFrame() && frame->IsActive() &&
        frame->IsRenderFrameLive() && !frame->IsErrorDocument() && owner &&
        !owner->IsDeleteScheduled() && !UnloadController::From(owner)->owner_close_admitted() &&
        Window(owner->GetSessionID().id()) == owner && LookupTab(owner, tab_id()) == tab &&
        frame->GetBrowserContext() == owner->GetProfile();
  }
  static std::string TranslationPayload(const std::string& text, const std::string& language,
      const std::vector<chrome::mojom::NookTranslationNodePtr>& nodes) {
    if (text.size() > 8192 || language.size() > 256 || nodes.size() > 128) return {};
    base::ListValue list;
    size_t bytes = 0;
    for (const auto& node : nodes) {
      bytes += node->id.size() + node->text.size();
      if (node->id.size() > 32 || node->text.size() > 131072 || bytes > 512 * 1024) return {};
      list.Append(base::DictValue().Set("id", node->id).Set("text", node->text));
    }
    auto payload = base::WriteJson(base::DictValue().Set("text", text).Set("lang", language)
        .Set("nodes", std::move(list))).value_or(std::string());
    return payload.size() <= 512 * 1024 ? payload : std::string();
  }
  void NodesChanged(const blink::DocumentToken& document, uint64_t generation,
                    bool aborted, std::vector<chrome::mojom::NookTranslationNodePtr> nodes) override {
    auto keep_alive = shared_from_this();
    if (!TranslationCurrent() || generation != translation_generation_ || !translation_callback_) return;
    auto* frame = translation_document_.AsRenderFrameHostIfValid();
    if (frame->GetDocumentToken() != document) return;
    auto payload = TranslationPayload("", "", nodes);
    if (payload.empty()) return;
    base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
    translation_callback_(context_.get(), token_, generation, 0, aborted ? 2 : 0, payload.c_str());
  }
  struct PickerRequest {
    uint64_t request;
    int32_t window;
    base::WeakPtr<BrowserWindowInterface> owner;
    content::WeakDocumentPtr document;
    blink::DocumentToken token;
    BarcPickerCallback callback;
  };
  bool PickerCurrent() const {
    if (!picker_ || !active_ || closing_ || discovery_stopped || !web_contents()) return false;
    auto* owner = picker_->owner.get();
    auto* tab = tab_.Get();
    auto* frame = picker_->document.AsRenderFrameHostIfValid();
    return owner && Window(picker_->window) == owner && !owner->IsDeleteScheduled() &&
        !UnloadController::From(owner)->owner_close_admitted() &&
        !UnloadController::From(owner)->is_attempting_to_close_browser() &&
        tab && tab->IsActivated() && web_contents()->GetVisibility() == content::Visibility::VISIBLE &&
        tab->GetBrowserWindowInterface() == owner &&
        LookupTab(owner, tab_id()) == tab && tab->GetContents() == web_contents() &&
        web_contents()->GetBrowserContext() == owner->GetProfile() && frame &&
        frame == web_contents()->GetPrimaryMainFrame() && frame->IsActive() &&
        frame->IsRenderFrameLive() && !frame->IsErrorDocument();
  }
  void CancelPicker(uint64_t request = 0) {
    if (!picker_ || (request && picker_->request != request)) return;
    auto keep_alive = shared_from_this();
    auto pending = std::move(picker_);
    picker_.reset();
    if (picker_remote_.is_bound())
      picker_remote_->NookCancelBoostPicker(pending->token, token_, pending->request);
    picker_remote_.reset();
    base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
    pending->callback(context_.get(), token_, pending->request, "", 0);
  }
  void OnVisibilityChanged(content::Visibility visibility) override {
    auto keep_alive = shared_from_this();
    auto* tab = tab_.Get();
    if (visibility == content::Visibility::HIDDEN && tab && PeekRoleFor(tab) &&
        tab->GetContents() == web_contents() &&
        bark::BarkWindowHost::ForBrowser(tab->GetBrowserWindowInterface())) {
      SuspendPeekMedia();
    }
    if (visibility != content::Visibility::VISIBLE) {
      ClearVaultFocus();
      CancelPicker();
    }
  }
  bool StartPicker(uint64_t request, BarcPickerCallback callback) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || discovery_stopped || picker_ || !callback ||
        !request || request <= picker_request_ || !web_contents()) return false;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* frame = web_contents()->GetPrimaryMainFrame();
    if (!owner || !tab->IsActivated() || owner->IsDeleteScheduled() ||
        UnloadController::From(owner)->owner_close_admitted() ||
        UnloadController::From(owner)->is_attempting_to_close_browser() ||
        LookupTab(owner, tab_id()) != tab || tab->GetContents() != web_contents() ||
        web_contents()->GetBrowserContext() != owner->GetProfile() ||
        web_contents()->GetVisibility() != content::Visibility::VISIBLE ||
        !frame || !frame->IsActive() || !frame->IsRenderFrameLive() || frame->IsErrorDocument() ||
        !frame->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() ||
        frame->IsSandboxed(network::mojom::WebSandboxFlags::kScripts) ||
        !web_contents()->GetOrCreateWebPreferences().javascript_enabled ||
        HostContentSettingsMapFactory::GetForProfile(owner->GetProfile())->GetContentSetting(
            frame->GetLastCommittedURL(), frame->GetLastCommittedURL(),
            ContentSettingsType::JAVASCRIPT) == CONTENT_SETTING_BLOCK) return false;
    picker_request_ = request;
    picker_.emplace(PickerRequest{request, owner->GetSessionID().id(), owner->GetWeakPtr(),
        frame->GetWeakDocumentPtr(), frame->GetDocumentToken(), callback});
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&picker_remote_);
    if (!PickerCurrent()) { picker_.reset(); picker_remote_.reset(); return false; }
    picker_remote_->NookStartBoostPicker(picker_->token, token_, request,
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(base::BindOnce(
            [](std::weak_ptr<TabObservation> weak, uint64_t request, const std::string& selector) {
              auto self = weak.lock();
              if (!self || !self->picker_ || self->picker_->request != request) return;
              const bool current = self->PickerCurrent();
              auto callback = self->picker_->callback;
              self->picker_.reset(); self->picker_remote_.reset();
              const bool valid = current && selector.size() <= 2048 && base::IsStringUTF8(selector) &&
                  selector.find('\0') == std::string::npos;
              base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
              callback(self->context_.get(), self->token_, request,
                  valid ? selector.data() : "", valid ? selector.size() : 0);
            }, weak_from_this(), request), std::string()));
    return true;
  }
  std::optional<PickerRequest> picker_;
  uint64_t picker_request_ = 0;
  mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> picker_remote_;

  struct ScriptRequest {
    uint64_t request;
    int32_t window;
    base::WeakPtr<BrowserWindowInterface> owner;
    content::WeakDocumentPtr document;
    blink::DocumentToken token;
    BarcScriptCallback callback;
  };
  bool ScriptCurrent() const {
    if (!script_ || !active_ || closing_ || discovery_stopped || !web_contents()) return false;
    auto* owner = script_->owner.get();
    auto* tab = tab_.Get();
    auto* frame = script_->document.AsRenderFrameHostIfValid();
    return owner && Window(script_->window) == owner && !owner->IsDeleteScheduled() &&
        !UnloadController::From(owner)->owner_close_admitted() &&
        !UnloadController::From(owner)->is_attempting_to_close_browser() &&
        tab && tab->GetBrowserWindowInterface() == owner &&
        LookupTab(owner, tab_id()) == tab && tab->GetContents() == web_contents() &&
        web_contents()->GetBrowserContext() == owner->GetProfile() && frame &&
        frame == web_contents()->GetPrimaryMainFrame() && frame->IsActive() &&
        frame->IsRenderFrameLive() && !frame->IsErrorDocument();
  }
  void CancelScript(uint64_t request = 0) {
    if (!script_ || (request && script_->request != request)) return;
    auto keep_alive = shared_from_this();
    auto pending = std::move(script_);
    script_.reset();
    if (script_remote_.is_bound())
      script_remote_->NookCancelScript(pending->token, token_, pending->request);
    script_remote_.reset();
    auto callback = pending->callback;
    base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
    callback(context_.get(), token_, pending->request, BARC_SCRIPT_CANCELLED, "", 0, "", 0, 0);
  }
  bool EvaluateScript(uint64_t request, int32_t mode, int32_t world,
                      const std::string& source, BarcScriptCallback callback) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || discovery_stopped || script_ || !callback ||
        !request || request <= script_request_ || source.size() > 128 * 1024 ||
        (mode != 0 && mode != 1) || (world != 0 && world != 1) || !web_contents()) return false;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* frame = web_contents()->GetPrimaryMainFrame();
    if (!owner || owner->IsDeleteScheduled() ||
        UnloadController::From(owner)->owner_close_admitted() ||
        UnloadController::From(owner)->is_attempting_to_close_browser() ||
        LookupTab(owner, tab_id()) != tab || tab->GetContents() != web_contents() ||
        web_contents()->GetBrowserContext() != owner->GetProfile() ||
        !frame || !frame->IsActive() || !frame->IsRenderFrameLive() || frame->IsErrorDocument() ||
        !frame->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() ||
        frame->IsSandboxed(network::mojom::WebSandboxFlags::kScripts) ||
        !web_contents()->GetOrCreateWebPreferences().javascript_enabled ||
        HostContentSettingsMapFactory::GetForProfile(owner->GetProfile())->GetContentSetting(
            frame->GetLastCommittedURL(), frame->GetLastCommittedURL(),
            ContentSettingsType::JAVASCRIPT) == CONTENT_SETTING_BLOCK ||
        !DevToolsWindow::AllowDevToolsFor(owner->GetProfile(), web_contents())) return false;
    script_request_ = request;
    script_.emplace(ScriptRequest{request, owner->GetSessionID().id(), owner->GetWeakPtr(),
        frame->GetWeakDocumentPtr(), frame->GetDocumentToken(), callback});
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&script_remote_);
    if (!ScriptCurrent()) { script_.reset(); script_remote_.reset(); return false; }
    script_remote_->NookEvaluateScript(script_->token, token_, request, mode, world, source,
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(base::BindOnce(
            [](std::weak_ptr<TabObservation> weak, uint64_t request,
               chrome::mojom::NookScriptResultPtr result) {
              auto self = weak.lock();
              if (!self || !self->script_ || self->script_->request != request) return;
              const bool current = self->ScriptCurrent();
              auto callback = self->script_->callback;
              self->script_.reset();
              self->script_remote_.reset();
              const int status = !current ? BARC_SCRIPT_CANCELLED :
                  (result ? static_cast<int>(result->status) : BARC_SCRIPT_UNAVAILABLE);
              base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
              callback(self->context_.get(), self->token_, request, status,
                  result && current ? result->text.data() : "",
                  result && current ? result->text.size() : 0,
                  result && current ? result->json.data() : "",
                  result && current ? result->json.size() : 0,
                  result && current && result->is_string);
            }, weak_from_this(), request), chrome::mojom::NookScriptResultPtr()));
    return true;
  }
  std::optional<ScriptRequest> script_;
  uint64_t script_request_ = 0;
  mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> script_remote_;

  bool Translate(uint64_t generation, uint64_t request, int32_t operation,
                 const std::string& json, BarcTranslationCallback callback) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || !web_contents() || !generation || !request || !callback ||
        operation < 0 || operation > 3 || generation < translation_generation_ ||
        json.size() > 512 * 1024 || request <= translation_request_) return false;
    auto* frame = web_contents()->GetPrimaryMainFrame();
    if (!frame || !frame->IsActive() || !frame->IsRenderFrameLive() || frame->IsErrorDocument() ||
        !frame->GetLastCommittedURL().SchemeIsHTTPOrHTTPS()) return false;
    auto value = base::JSONReader::Read(json, base::JSON_PARSE_RFC);
    if (!value || !value->is_list() || value->GetList().size() > 128) return false;
    std::vector<chrome::mojom::NookTranslationNodePtr> pairs;
    size_t bytes = 0;
    for (const auto& entry : value->GetList()) {
      if (!entry.is_dict()) return false;
      const auto* id = entry.GetDict().FindString("id");
      const auto* text = entry.GetDict().FindString("text");
      if (!id || !text || id->size() > 32 || text->size() > 131072) return false;
      bytes += id->size() + text->size();
      if (bytes > 512 * 1024) return false;
      pairs.push_back(chrome::mojom::NookTranslationNode::New(*id, *text));
    }
    if (operation != 2 && !pairs.empty()) return false;
    const auto previous_document = translation_document_;
    if (operation == 0) translation_document_ = frame->GetWeakDocumentPtr();
    if (!TranslationCurrent() || (operation != 0 && generation != translation_generation_)) {
      translation_document_ = previous_document;
      return false;
    }
    if (generation != translation_generation_ ||
        previous_document.AsRenderFrameHostIfValid() != frame) {
      translation_receiver_.reset();
    }
    translation_generation_ = generation;
    translation_request_ = request;
    translation_callback_ = callback;
    mojo::PendingAssociatedRemote<chrome::mojom::NookTranslationClient> client;
    // Returning to a displayed page resumes the same script/observer. Replacing
    // its endpoint would signal abandonment and restore the translated DOM.
    if (operation == 1 && !translation_receiver_.is_bound()) {
      client = translation_receiver_.BindNewEndpointAndPassRemote();
      translation_receiver_.set_disconnect_handler(base::BindOnce(
          [](std::weak_ptr<TabObservation> weak) {
            if (auto self = weak.lock()) self->translation_receiver_.reset();
          }, weak_from_this()));
    }
    auto document = translation_document_;
    const auto document_token = frame->GetDocumentToken();
    mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> remote;
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&remote);
    if (!TranslationCurrent() || translation_request_ != request ||
        translation_document_.AsRenderFrameHostIfValid() != document.AsRenderFrameHostIfValid()) return false;
    auto* proxy = remote.get();
    proxy->NookTranslate(document_token, generation, operation, std::move(pairs), std::move(client),
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(base::BindOnce(
            [](mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame>,
               std::weak_ptr<TabObservation> weak, content::WeakDocumentPtr document,
               uint64_t generation, uint64_t request, int32_t operation,
               BarcTranslationCallback callback, bool applied, const std::string& text,
               const std::string& language, std::vector<chrome::mojom::NookTranslationNodePtr> nodes) {
              auto self = weak.lock();
              if (!self || !self->active_ || discovery_stopped || !self->callback_) return;
              const bool current = self->TranslationCurrent() && generation == self->translation_generation_ &&
                  self->translation_request_ == request &&
                  self->translation_document_.AsRenderFrameHostIfValid() == document.AsRenderFrameHostIfValid();
              auto payload = current && applied ? TranslationPayload(text, language, nodes) : std::string();
              if (current && (operation == 3 || (operation == 1 && !applied))) {
                self->translation_receiver_.reset(); self->translation_callback_ = nullptr;
              }
              base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
              callback(self->context_.get(), self->token_, generation, request,
                       !current ? 1 : (!applied || payload.empty() ? 2 : 0), payload.c_str());
            }, std::move(remote), weak_from_this(), document, generation, request, operation, callback),
            false, std::string(), std::string(), std::vector<chrome::mojom::NookTranslationNodePtr>()));
    return true;
  }

  bool SetUserCSS(uint64_t request, const GURL& expected_url,
                  std::string css, BarcStyleCallback callback) {
    auto keep_alive = shared_from_this();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* frame = web_contents() ? web_contents()->GetPrimaryMainFrame() : nullptr;
    if (!active_ || closing_ || !request || request <= style_request_ || !callback ||
        !owner || owner->IsDeleteScheduled() ||
        UnloadController::From(owner)->owner_close_admitted() || !frame ||
        !frame->IsActive() || !frame->IsRenderFrameLive() || frame->IsErrorDocument() ||
        owner->GetProfile() != web_contents()->GetBrowserContext() ||
        frame->GetBrowserContext() != owner->GetProfile() ||
        Window(owner->GetSessionID().id()) != owner ||
        LookupTab(owner, tab_id()) != tab || tab->GetContents() != web_contents() ||
        !expected_url.SchemeIsHTTPOrHTTPS() ||
        expected_url != frame->GetLastCommittedURL() ||
        css.size() > 16 * 1024 * 1024 || !base::IsStringUTF8(css)) return false;
    style_request_ = request;
    auto document = frame->GetWeakDocumentPtr();
    const auto document_token = frame->GetDocumentToken();
    auto expected_owner = owner->GetWeakPtr();
    mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> remote;
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&remote);
    // Interface binding can be overridden by embedders/tests. Do not retain
    // borrowed owners or let a nested request overwrite newer CSS admission.
    if (!active_ || closing_ || style_request_ != request || !expected_owner ||
        !web_contents() || !document.AsRenderFrameHostIfValid() ||
        document.AsRenderFrameHostIfValid() != web_contents()->GetPrimaryMainFrame() ||
        !tab_.Get() || tab_.Get()->GetBrowserWindowInterface() != expected_owner.get() ||
        expected_owner->IsDeleteScheduled() ||
        UnloadController::From(expected_owner.get())->owner_close_admitted()) return false;
    auto* proxy = remote.get();
    // Retain the associated remote until reply/error, following CoreTabHelper.
    // The callback holds no CSS buffer and publication ends on unobserve.
    proxy->SetNookBoostStyle(document_token, css,
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(base::BindOnce(
            [](mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame>,
               std::weak_ptr<TabObservation> weak,
               base::WeakPtr<BrowserWindowInterface> expected_owner,
               content::WeakDocumentPtr document, uint64_t request,
               BarcStyleCallback callback, bool applied) {
              auto self = weak.lock();
              if (discovery_stopped || !self || !self->active_ || !self->callback_ ||
                  self->style_request_ != request) return;
              auto* frame = document.AsRenderFrameHostIfValid();
              auto* tab = self->tab_.Get();
              auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
              const bool current = !self->closing_ && frame && self->web_contents() &&
                  frame == self->web_contents()->GetPrimaryMainFrame() &&
                  frame->IsActive() && frame->IsRenderFrameLive() && !frame->IsErrorDocument() &&
                  expected_owner && owner == expected_owner.get() &&
                  !owner->IsDeleteScheduled() &&
                  !UnloadController::From(owner)->owner_close_admitted() &&
                  Window(owner->GetSessionID().id()) == owner &&
                  LookupTab(owner, self->tab_id()) == tab &&
                  frame->GetBrowserContext() == owner->GetProfile();
              base::AutoReset<int> callback_scope(&navigation_callback_depth,
                                                  navigation_callback_depth + 1);
              callback(self->context_.get(), self->token_, request,
                       !current ? 1 : (applied ? 0 : 2));
            }, std::move(remote), weak_from_this(), expected_owner, document,
            request, callback), false));
    return true;
  }

  bool ClearSiteData(uint64_t request, int32_t action, BarcSiteDataCallback callback) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || site_data_ || !request || !callback ||
        action < BARC_SITE_COOKIES || action > BARC_SITE_COOKIES_AND_RELOAD ||
        !web_contents())
      return false;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* frame = web_contents()->GetPrimaryMainFrame();
    const GURL url = frame ? frame->GetLastCommittedURL() : GURL();
    if (!owner || owner->IsDeleteScheduled() || !owner->IsSelectedForNativeWindow() ||
        owner->GetTabStripModel()->GetActiveTab() != tab ||
        web_contents()->GetBrowserContext() != owner->GetProfile() || !frame ||
        !url.SchemeIsHTTPOrHTTPS() || frame->GetLastCommittedOrigin().opaque() ||
        frame->GetStorageKey().nonce().has_value() ||
        frame->GetStorageKey().top_level_site().opaque() ||
        (action == BARC_SITE_COOKIES_AND_RELOAD &&
         !chrome::IsCommandEnabled(owner, IDC_RELOAD)))
      return false;
    auto pending = std::make_shared<SiteDataRequest>();
    pending->owner = owner->GetWeakPtr();
    pending->document = frame->GetWeakDocumentPtr();
    pending->navigation = navigation_;
    pending->request = request;
    pending->action = action;
    pending->host = url.host();
    pending->keys = net::CookiePartitionKeyCollection::MatchesSite(
        frame->GetStorageKey().top_level_site());
    pending->callback = callback;
    site_data_ = pending;
    if (action == BARC_SITE_CACHE) {
      auto filter = content::BrowsingDataFilterBuilder::Create(
          content::BrowsingDataFilterBuilder::Mode::kDelete,
          content::BrowsingDataFilterBuilder::OriginMatchingMode::kOriginInAllContexts);
      filter->AddOrigin(frame->GetLastCommittedOrigin());
      filter->SetStoragePartitionConfig(frame->GetStoragePartition()->GetConfig());
      auto* remover = owner->GetProfile()->GetBrowsingDataRemover();
      site_data_remover_.Observe(remover);
      remover->RemoveWithFilterAndReply(base::Time(), base::Time::Max(),
          content::BrowsingDataRemover::DATA_TYPE_CACHE,
          content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB,
          std::move(filter), this);
    } else {
      frame->GetStoragePartition()->GetCookieManagerForBrowserProcess()->GetAllCookies(
          mojo::WrapCallbackWithDropHandler(base::BindOnce(
              [](std::weak_ptr<TabObservation> weak,
                 std::shared_ptr<SiteDataRequest> pending,
                 const std::vector<net::CanonicalCookie>& cookies) {
                if (auto self = weak.lock()) self->ClearExactCookies(pending, cookies);
              }, weak_from_this(), pending), base::BindOnce(
              [](std::weak_ptr<TabObservation> weak,
                 std::shared_ptr<SiteDataRequest> pending) {
                if (auto self = weak.lock()) self->FinishSiteData(pending, false);
              }, weak_from_this(), pending)));
    }
    return true;
  }
  void OnBrowsingDataRemoverDone(uint64_t failed) override {
    if (site_data_) FinishSiteData(site_data_, failed == 0);
  }
  void Emit(int32_t event, int32_t error = 0, uint32_t extra = 0,
            const GURL* event_url = nullptr) {
    auto keep_alive = shared_from_this();
    if (!active_ || !callback_)
      return;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    const int32_t window = owner ? owner->GetSessionID().id() : 0;
    uint32_t flags = extra;
    std::string url, title;
    if (web_contents()) {
      auto& controller = web_contents()->GetController();
      if (web_contents()->IsLoading())
        flags |= BARC_TAB_LOADING;
      if (web_contents()->IsAudioMuted())
        flags |= BARC_TAB_MUTED;
      if (web_contents()->IsCurrentlyAudible())
        flags |= BARC_TAB_AUDIBLE;
      flags |= BARC_TAB_PIP_STATE_KNOWN;
      if (web_contents()->HasPictureInPictureVideo())
        flags |= BARC_TAB_VIDEO_PIP;
      if (web_contents()->HasPictureInPictureDocument())
        flags |= BARC_TAB_DOCUMENT_PIP;
      if (controller.CanGoBack())
        flags |= BARC_TAB_BACK;
      if (controller.CanGoForward())
        flags |= BARC_TAB_FORWARD;
      if (owner && !closing_ && !discovery_stopped && !owner->IsDeleteScheduled() &&
          event != BARC_TAB_STARTED && event != BARC_TAB_CLOSED &&
          event != BARC_TAB_PEEK_REQUESTED && event != BARC_TAB_NATIVE_BLOCKED &&
          event != BARC_TAB_CONTINUE_NATIVE_BLOCK &&
          !(extra & BARC_TAB_PROVISIONAL) && !controller.GetPendingEntry() &&
          !owner->GetProfile()->IsOffTheRecord() &&
          web_contents()->GetBrowserContext() == owner->GetProfile()) {
        auto* entry = controller.GetLastCommittedEntry();
        auto* frame = web_contents()->GetPrimaryMainFrame();
        if (entry && frame && entry->GetPageType() == content::PAGE_TYPE_NORMAL &&
            barc::IsPawlPasswordManagementDocument(entry->GetURL(), entry->GetVirtualURL()) &&
            frame->IsActive() && frame->IsRenderFrameLive() &&
            frame->GetLastCommittedOrigin().opaque() &&
            frame->GetLastCommittedURL() == entry->GetURL()) {
          flags |= BARC_TAB_PAWL_MANAGEMENT;
        }
      }
      url = web_contents()->GetVisibleURL().spec();
      title = base::UTF16ToUTF8(web_contents()->GetTitle());
    }
    if (event_url)
      url = event_url->spec();
    base::AutoReset<int> callback_scope(&navigation_callback_depth,
                                        navigation_callback_depth + 1);
    callback_(context_.get(), token_, event, window, tab_id(), url.c_str(),
              title.c_str(), error, flags);
  }
  int SetFaviconCallback(BarcTabFaviconCallback callback) {
    if (!active_ || closing_ || (favicon_callback_ && callback))
      return 0;
    favicon_callback_ = callback;
    if (callback)
      BindFaviconDriver();
    else
      StopFaviconObservation();
    return 1;
  }

  void StopFaviconObservation() {
    favicon_driver_.Reset();
    favicon_tasks_.InvalidateWeakPtrs();
    favicon_pending_ = false;
  }

  void BindFaviconDriver() {
    if (!favicon_callback_ || !active_ || closing_ || !strip_ || !web_contents())
      return;
    auto* driver = favicon::ContentFaviconDriver::FromWebContents(web_contents());
    if (driver && !favicon_driver_.IsObservingSource(driver)) {
      favicon_driver_.Reset();
      favicon_driver_.Observe(driver);
    }
    ScheduleFavicon();
  }

  void OnFaviconUpdated(favicon::FaviconDriver* driver,
                        NotificationIconType type, const GURL&,
                        bool, const gfx::Image&) override {
    if (type == NON_TOUCH_16_DIP && favicon_driver_.IsObservingSource(driver))
      ScheduleFavicon();
  }

  void ScheduleFavicon() {
    if (!active_ || closing_ || !favicon_callback_ || favicon_pending_)
      return;
    favicon_pending_ = true;
    // Read after all navigation/favicon observers have updated the commit.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(
        FROM_HERE, base::BindOnce(&TabObservation::RefreshFavicon,
                                  favicon_tasks_.GetWeakPtr()));
  }

  void RefreshFavicon() {
    auto keep_alive = shared_from_this();
    favicon_pending_ = false;
    auto* contents = web_contents();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (!active_ || closing_ || discovery_stopped || !favicon_callback_ ||
        !contents || contents->IsBeingDestroyed() || !owner ||
        owner->IsDeleteScheduled() || strip_ != owner->GetTabStripModel() ||
        tab->GetContents() != contents ||
        owner->GetProfile() != contents->GetBrowserContext()) {
      return;
    }

    std::optional<std::vector<uint8_t>> bytes;
    const auto* entry = contents->GetController().GetLastCommittedEntry();
    auto* driver = favicon::ContentFaviconDriver::FromWebContents(contents);
    if (entry && !entry->IsInitialEntry() &&
        entry->GetPageType() == content::PAGE_TYPE_NORMAL &&
        driver && favicon_driver_.IsObservingSource(driver) &&
        driver->FaviconIsValid()) {
      SkBitmap bitmap = driver->GetFavicon().AsBitmap();
      constexpr int kMaxDimension = 32;
      const int longest = std::max(bitmap.width(), bitmap.height());
      if (longest > kMaxDimension) {
        const double scale = static_cast<double>(kMaxDimension) / longest;
        bitmap = skia::ImageOperations::Resize(
            bitmap, skia::ImageOperations::RESIZE_BEST,
            std::max(1, static_cast<int>(bitmap.width() * scale)),
            std::max(1, static_cast<int>(bitmap.height() * scale)));
      }
      if (!bitmap.drawsNothing())
        bytes = gfx::PNGCodec::EncodeBGRASkBitmap(bitmap, false);
    }
    if (bytes && bytes->size() > 32768)
      bytes.reset();
    base::AutoReset<int> scope(&navigation_callback_depth,
                              navigation_callback_depth + 1);
    favicon_callback_(context_.get(), token_,
                      bytes && !bytes->empty() ? bytes->data() : nullptr,
                      bytes ? bytes->size() : 0);
  }

  int SetLoadProgressCallback(BarcLoadProgressCallback callback) {
    if (!active_ || closing_ || !web_contents() ||
        (load_progress_callback_ && callback)) {
      return 0;
    }
    load_progress_callback_ = callback;
    load_progress_tasks_.InvalidateWeakPtrs();
    load_progress_pending_ = false;
    ScheduleLoadProgress();
    return 1;
  }
  void LoadProgressChanged(double) override { ScheduleLoadProgress(); }
  void ScheduleLoadProgress() {
    if (!active_ || closing_ || !load_progress_callback_ ||
        load_progress_pending_) {
      return;
    }
    load_progress_pending_ = true;
    // Sample the live page after lifecycle delivery. A nested loop inside a
    // navigation callback cannot deliver an old progress event after a reset.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(
        FROM_HERE, base::BindOnce(&TabObservation::RefreshLoadProgress,
                                  load_progress_tasks_.GetWeakPtr()));
  }
  void RefreshLoadProgress() {
    auto keep_alive = shared_from_this();
    load_progress_pending_ = false;
    auto* contents = web_contents();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (!active_ || closing_ || discovery_stopped || !load_progress_callback_ ||
        !contents || contents->IsBeingDestroyed() || !owner ||
        owner->IsDeleteScheduled() || strip_ != owner->GetTabStripModel() ||
        tab->GetContents() != contents ||
        owner->GetProfile() != contents->GetBrowserContext()) {
      return;
    }
    const double progress = contents->GetLoadProgress();
    if (!std::isfinite(progress) || progress < 0.0 || progress > 1.0) {
      return;
    }
    base::AutoReset<int> scope(&navigation_callback_depth,
                              navigation_callback_depth + 1);
    load_progress_callback_(context_.get(), token_, progress,
                            contents->IsLoading() ? 1 : 0);
  }
  int SetMediaCallback(BarcMediaCallback callback) {
    if (!active_ || closing_ || !web_contents() || (media_callback_ && callback)) return 0;
    media_callback_ = callback;
    media_receiver_.reset();
    media_snapshot_.reset();
    media_document_ = {};
    media_refresh_pending_ = false;
    if (callback) {
      if (auto* main = web_contents()->GetPrimaryMainFrame()) media_document_ = main->GetWeakDocumentPtr();
      if (navigation_callback_depth) ScheduleMediaRefresh();
      if (auto* session = content::MediaSession::GetIfExists(web_contents()))
        BindMedia(session);
      else
        RefreshMedia();
    }
    return 1;
  }
  void MediaSessionCreated(content::MediaSession* session) override {
    if (!media_callback_) return;
    auto keep_alive = shared_from_this();
    BindMedia(session);
  }
  void MediaSessionInfoChanged(media_session::mojom::MediaSessionInfoPtr) override { RefreshMedia(); }
  void MediaSessionMetadataChanged(const std::optional<media_session::MediaMetadata>&) override { RefreshMedia(); }
  void MediaSessionActionsChanged(const std::vector<media_session::mojom::MediaSessionAction>&) override { RefreshMedia(); }
  void MediaSessionImagesChanged(const base::flat_map<media_session::mojom::MediaSessionImageType,
                                 std::vector<media_session::MediaImage>>&) override {}
  void MediaSessionPositionChanged(const std::optional<media_session::MediaPosition>&) override {}
  void BindMedia(content::MediaSession* session) {
    media_receiver_.reset();
    session->AddObserver(media_receiver_.BindNewPipeAndPassRemote());
    RefreshMedia();
  }
  struct MediaSnapshot {
    uint32_t flags = 0;
    int32_t window = 0;
    std::string title, artist, album;
    bool operator==(const MediaSnapshot&) const = default;
  };
  void ScheduleMediaRefresh() {
    if (!active_ || !media_callback_ || !web_contents()) return;
    auto* main = web_contents()->GetPrimaryMainFrame();
    if (!main) return;
    if (media_refresh_pending_ && media_document_.AsRenderFrameHostIfValid() == main) return;
    auto document = main->GetWeakDocumentPtr();
    media_document_ = document;
    media_refresh_pending_ = true;
    // Non-nestable: a client may enter a modal loop inside a navigation callback.
    // Read after ALL native navigation observers reset the old media service.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(
        FROM_HERE, base::BindOnce([](std::weak_ptr<TabObservation> weak,
                                    content::WeakDocumentPtr expected) {
          auto self = weak.lock();
          auto* frame = expected.AsRenderFrameHostIfValid();
          if (!self || !self->active_ || !frame || !self->web_contents() ||
              frame != self->web_contents()->GetPrimaryMainFrame() ||
              !self->media_refresh_pending_ ||
              self->media_document_.AsRenderFrameHostIfValid() != frame) return;
          self->media_refresh_pending_ = false;
          self->media_snapshot_.reset();
          self->RefreshMedia();
        }, weak_from_this(), document));
  }
  void RefreshMedia(bool document_ended = false) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || !media_callback_ || !web_contents() ||
        (media_refresh_pending_ && !document_ended)) return;
    MediaSnapshot current;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    current.window = owner ? owner->GetSessionID().id() : 0;
    auto* session = content::MediaSession::GetIfExists(web_contents());
    auto* main = web_contents()->GetPrimaryMainFrame();
    if (!main) return;
    if (document_ended) {
      media_document_ = main->GetWeakDocumentPtr();
      media_refresh_pending_ = false;
    } else if (media_document_.AsRenderFrameHostIfValid() != main) {
      ScheduleMediaRefresh();
      return;
    }
    auto document = main->GetWeakDocumentPtr();
    // Observe only this actual page/profile. Query live state rather than using
    // queued Mojo payloads from a document/route that may already have ended.
    if (owner && !owner->IsDeleteScheduled() && (document_ended || tab->GetContents() == web_contents()) &&
        owner->GetProfile() == web_contents()->GetBrowserContext()) {
      if (document_ended) {
        // A real replacement ends the old controllable player, unlike a
        // transient unavailable route/owner. Clear its paused mini-player rank.
        current.flags = BARC_MEDIA_KNOWN;
      } else if (session) {
        auto* routed = session->GetRoutedFrame();
        const auto info = session->GetMediaSessionInfoSync();
        const bool valid_route = !routed || (routed->IsActive() &&
            routed->GetOutermostMainFrame() == main);
        if (info && valid_route && (!info->is_controllable || (routed && info->audio_video_states))) {
          current.flags = BARC_MEDIA_KNOWN;
          if (info->is_controllable) current.flags |= BARC_MEDIA_CONTROLLABLE;
          if (info->playback_state == media_session::mojom::MediaPlaybackState::kPlaying)
            current.flags |= BARC_MEDIA_PLAYING;
          if (info->audio_video_states) {
            for (const auto value : *info->audio_video_states) {
              if (value == media_session::mojom::MediaAudioVideoState::kAudioVideo ||
                  value == media_session::mojom::MediaAudioVideoState::kVideoOnly)
                current.flags |= BARC_MEDIA_VIDEO;
            }
          }
          const auto actions = session->GetMediaSessionActionsSync();
          auto has = [&](media_session::mojom::MediaSessionAction action) {
            return std::ranges::find(actions, action) != actions.end();
          };
          if (info->is_controllable && has(media_session::mojom::MediaSessionAction::kPlay)) current.flags |= BARC_MEDIA_CAN_PLAY;
          if (info->is_controllable && has(media_session::mojom::MediaSessionAction::kPause)) current.flags |= BARC_MEDIA_CAN_PAUSE;
          if (info->is_controllable && has(media_session::mojom::MediaSessionAction::kPreviousTrack)) current.flags |= BARC_MEDIA_PREVIOUS;
          if (info->is_controllable && has(media_session::mojom::MediaSessionAction::kNextTrack)) current.flags |= BARC_MEDIA_NEXT;
          if (web_contents()->IsCurrentlyAudible()) current.flags |= BARC_MEDIA_AUDIBLE;
          if (routed && !info->hide_metadata) {
            const auto& metadata = session->GetMediaSessionMetadata();
            current.title = base::UTF16ToUTF8(metadata.title.substr(0, 1024));
            current.artist = base::UTF16ToUTF8(metadata.artist.substr(0, 1024));
            current.album = base::UTF16ToUTF8(metadata.album.substr(0, 1024));
          }
        }
      }
    }
    if (!document.AsRenderFrameHostIfValid() ||
        (media_snapshot_ && *media_snapshot_ == current)) return;
    media_snapshot_ = current;
    const auto callback = media_callback_;
    void* context = context_.get();
    base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
    callback(context, token_, current.window, tab_id(), current.flags,
             current.title.c_str(), current.artist.c_str(), current.album.c_str());
  }
  void OnAudioStateChanged(bool) override {
    auto keep_alive = shared_from_this();
    Emit(BARC_TAB_STATE);
    RefreshMedia();
  }
  void SuspendPeekMedia() {
    content::MediaSession::Get(web_contents())->Suspend(
        media_session::mojom::MediaSession::SuspendType::kUI);
  }
  void MediaStartedPlaying(const MediaPlayerInfo&, const content::MediaPlayerId&) override {
    auto keep_alive = shared_from_this();
    auto* tab = tab_.Get();
    if (!tab || !PeekRoleFor(tab) || tab->GetContents() != web_contents()) return;
    auto* owner = tab->GetBrowserWindowInterface();
    if (bark::BarkWindowHost::ForBrowser(owner)) {
      if (web_contents()->GetVisibility() == content::Visibility::HIDDEN) {
        SuspendPeekMedia();
      }
      return;
    }
    auto* view = owner ? BrowserView::GetBrowserViewForBrowser(owner) : nullptr;
    if (!view || !view->browser_widget()->IsBarcPeekVisible(tab)) {
      SuspendPeekMedia();
    }
  }
  void MediaPictureInPictureChanged(bool) override { Emit(BARC_TAB_STATE); }
  void DidUpdateAudioMutingState(bool) override { Emit(BARC_TAB_STATE); }
  void RenderFrameDeleted(content::RenderFrameHost* frame) override {
    if (pending_vault_focus_ &&
        (!pending_vault_focus_->document.AsRenderFrameHostIfValid() ||
         pending_vault_focus_->document.AsRenderFrameHostIfValid() == frame))
      pending_vault_focus_.reset();
    if (vault_passkey_ && (!vault_passkey_->document.AsRenderFrameHostIfValid() ||
        vault_passkey_->document.AsRenderFrameHostIfValid() == frame)) CancelVaultPasskey();
    if (vault_focus_ && (!vault_focus_->document.AsRenderFrameHostIfValid() ||
        vault_focus_->document.AsRenderFrameHostIfValid() == frame)) ClearVaultFocus();
  }
  void DidStartNavigation(content::NavigationHandle* handle) override {
    auto keep_alive = shared_from_this();
    if (vault_passkey_ && !handle->IsSameDocument() &&
        (handle->IsInPrimaryMainFrame() || !vault_passkey_->document.AsRenderFrameHostIfValid() ||
         vault_passkey_->document.AsRenderFrameHostIfValid()->GetFrameTreeNodeId() == handle->GetFrameTreeNodeId()))
      CancelVaultPasskey();
    pending_vault_focus_.reset();
    if (vault_focus_ && (handle->IsInPrimaryMainFrame() ||
        (vault_focus_->document.AsRenderFrameHostIfValid() &&
         vault_focus_->document.AsRenderFrameHostIfValid()->GetFrameTreeNodeId() == handle->GetFrameTreeNodeId()))) ClearVaultFocus();
    if (handle->IsInPrimaryMainFrame() && thumbnail_)
      thumbnail_->cancelled.Set();
    if (handle->IsInPrimaryMainFrame() && site_data_) site_data_->cancelled = true;
    if (!handle->IsInPrimaryMainFrame() || handle->IsSameDocument())
      return;
    CancelPicker();
    CancelScript();
    CancelFiles();
    if (!active_) return;
    peek_request_.reset();
    peek_current_serial_ = 0;
    navigation_ = handle->GetNavigationId();
    blocked_url_.reset();
    committed_ = false;
    navigation_flags_ = handle->GetReloadType() != content::ReloadType::NONE
                            ? BARC_TAB_RELOAD
                            : 0;
    ScheduleLoadProgress();
    Emit(BARC_TAB_STARTED, 0, navigation_flags_, &handle->GetURL());
  }
  void DidGetUserInteraction(const blink::WebInputEvent& event) override {
    const int modifiers = blink::WebInputEvent::kAltKey | blink::WebInputEvent::kShiftKey |
        blink::WebInputEvent::kMetaKey | blink::WebInputEvent::kControlKey;
    option_click_ = event.GetType() == blink::WebInputEvent::Type::kMouseDown &&
        (event.GetModifiers() & modifiers) == blink::WebInputEvent::kAltKey;
  }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    auto keep_alive = shared_from_this();
    if (!handle->IsInPrimaryMainFrame())
      return;
    if (handle->IsSameDocument()) {
      if (handle->HasCommitted() && handle->GetNetErrorCode() == net::OK)
        Emit(BARC_TAB_COMMITTED, 0, BARC_TAB_SAME_DOCUMENT, &handle->GetURL());
      return;
    }
    if (handle->HasCommitted()) {
      ScheduleLoadProgress();
      BindFaviconDriver();
      CancelPicker();
      CancelFiles();
      translation_receiver_.reset();
      translation_callback_ = nullptr;
      translation_document_ = {};
      ScheduleMediaRefresh();
    }
    // A subscription cannot reconstruct starts or failures from before binding.
    // A real new primary commit is observable; otherwise report current state.
    if (!navigation_) {
      if (handle->HasCommitted() && handle->GetNetErrorCode() == net::OK)
        Emit(BARC_TAB_COMMITTED, 0, 0, &handle->GetURL());
      else
        Emit(BARC_TAB_STATE);
      RefreshMedia();
      return;
    }
    if (handle->GetNavigationId() != navigation_)
      return;
    if (handle->GetNetErrorCode() != net::OK) {
      committed_ = false;
      // Replacement can cancel the old request before the new DidStart arrives.
      // The public discard reason identifies that ordering without URL guesses.
      if (auto reason = handle->GetNavigationDiscardReason(); reason) {
        switch (*reason) {
          case content::NavigationDiscardReason::kNewReloadNavigation:
          case content::NavigationDiscardReason::kNewHistoryNavigation:
          case content::NavigationDiscardReason::kNewOtherNavigationBrowserInitiated:
          case content::NavigationDiscardReason::kNewOtherNavigationRendererInitiated:
          case content::NavigationDiscardReason::kNewDuplicateNavigation:
          case content::NavigationDiscardReason::kCommittedNavigation:
            Emit(BARC_TAB_STATE);
            return;
          default:
            break;
        }
      }
      const GURL displayed = web_contents()->GetLastCommittedURL();
      const int64_t failed_navigation = handle->GetNavigationId();
      const GURL failed_url = handle->GetURL();
      const bool native_blocked = handle->GetNetErrorCode() == net::ERR_BLOCKED_BY_CLIENT &&
          blocked_url_ == failed_url;
      Emit(BARC_TAB_FAILED, handle->GetNetErrorCode(), navigation_flags_ |
          (!handle->HasCommitted() ? BARC_TAB_PROVISIONAL : 0) |
          (handle->GetNetErrorCode() == net::ERR_ABORTED ? BARC_TAB_ABORTED : 0),
          &displayed);
      if (native_blocked && NativeBlockCurrent(failed_navigation, failed_url)) {
        Emit(BARC_TAB_NATIVE_BLOCKED, 0, 0, &failed_url);
        // Run after every DidFinishNavigation observer, including InfoBar
        // expiry. A newer navigation/owner invalidates this one weak task.
        base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(
            FROM_HERE, base::BindOnce([](std::weak_ptr<TabObservation> weak,
                                        int64_t navigation, GURL url) {
              if (auto self = weak.lock()) self->ShowNativeBlock(navigation, url);
            }, weak_from_this(), failed_navigation, failed_url));
      }
      RefreshMedia();
      return;
    }
    if (!handle->HasCommitted())
      return;
    committed_ = true;
    const GURL url = handle->GetURL();
    Emit(BARC_TAB_COMMITTED, 0, navigation_flags_, &url);
    // No borrowed NavigationHandle is touched after a media client callout.
    RefreshMedia();
  }
  void NavigationListPruned(const content::PrunedDetails&) override {
    Emit(BARC_TAB_STATE);
  }
  void NavigationEntriesDeleted() override { Emit(BARC_TAB_STATE); }
  void DidStartLoading() override {
    ScheduleLoadProgress();
    Emit(BARC_TAB_STATE);
  }
  void DidStopLoading() override {
    auto keep_alive = shared_from_this();
    ScheduleLoadProgress();
    if (committed_) {
      committed_ = false;
      Emit(BARC_TAB_FINISHED, 0, navigation_flags_);
    } else {
      Emit(BARC_TAB_STATE);
    }
  }
  void TitleWasSet(content::NavigationEntry*) override { Emit(BARC_TAB_TITLE); }
  void WebContentsDestroyed() override { Close(); }
  void BeforeUnloadFired(bool proceed) override {
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* controller = owner ? UnloadController::From(owner) : nullptr;
    // WebContents notifies before its delegate resets the window-close state.
    // Window/group refusal comes from the terminal window notification instead.
    const bool tab_close = !controller || !controller->is_attempting_to_close_browser();
    if (proceed && tab_close) {
      ShowCloseSuccessor();
      return;
    }
    close_successor_ = 0;
    if (!proceed && tab_close)
      Emit(BARC_TAB_CLOSE_CANCELLED);
  }
  void OnTabCloseCancelled(const tabs::TabInterface* tab) override {
    if (tab->GetHandle() == tab_)
      Emit(BARC_TAB_CLOSE_CANCELLED);
  }
  void OnTabStripModelDestroyed(TabStripModel* strip) override {
    if (strip_ == strip) {
      StopFaviconObservation();
      strip_ = nullptr;
      window_cancelled_ = {};
    }
  }
 private:
  BarcVaultCallback vault_callback_ = nullptr;
  uint64_t vault_serial_ = 0;
  bool vault_notification_posted_ = false;
  base::CallbackListSubscription vault_selection_, vault_active_, vault_inactive_, vault_tab_;
  std::optional<VaultFocus> vault_focus_;
  autofill::ScopedAutofillManagersObservation vault_managers_{this};
  struct ThumbnailCapture {
    ThumbnailCapture();
    ~ThumbnailCapture();
    base::WeakPtr<BrowserWindowInterface> owner;
    content::WeakDocumentPtr document;
    int64_t navigation = 0;
    uint64_t request = 0;
    BarcTabThumbnailCallback callback = nullptr;
    bool screenshot = false;
    gfx::Size output;
    base::AtomicFlag cancelled;
  };
  bool ThumbnailIsCurrent(const std::shared_ptr<ThumbnailCapture>& capture) {
    if (!active_ || closing_ || thumbnail_ != capture ||
        capture->cancelled.IsSet() || capture->navigation != navigation_ ||
        !capture->owner || capture->owner->IsDeleteScheduled() || !web_contents() ||
        discovery_stopped || UnloadController::From(capture->owner.get())->owner_close_admitted() ||
        UnloadController::From(capture->owner.get())->is_attempting_to_close_browser() ||
        !ScreenshotAllowed())
      return false;
    auto* document = capture->document.AsRenderFrameHostIfValid();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    return document && document == web_contents()->GetPrimaryMainFrame() &&
        owner == capture->owner.get() &&
        Window(owner->GetSessionID().id()) == owner &&
        LookupTab(owner, tab_id()) == tab && tab->GetContents() == web_contents() &&
        document->GetBrowserContext() == owner->GetProfile();
  }
  void FinishThumbnail(std::shared_ptr<ThumbnailCapture> capture,
                       std::vector<uint8_t> bytes = {}) {
    if (thumbnail_ != capture)
      return;
    auto keep_alive = shared_from_this();
    const bool current = ThumbnailIsCurrent(capture);
    thumbnail_.reset();
    if (!active_ || !capture->callback)
      return;
    base::AutoReset<int> callback_scope(&navigation_callback_depth,
                                        navigation_callback_depth + 1);
    capture->callback(context_.get(), token_, capture->request,
                      current && !bytes.empty() ? bytes.data() : nullptr,
                      current ? bytes.size() : 0);
  }
  void ThumbnailCopied(std::shared_ptr<ThumbnailCapture> capture,
                       const content::CopyFromSurfaceResult& result) {
    if (!ThumbnailIsCurrent(capture) || !result.has_value() ||
        result->bitmap.drawsNothing() || result->bitmap.width() > capture->output.width() ||
        result->bitmap.height() > capture->output.height()) {
      FinishThumbnail(std::move(capture));
      return;
    }
    SkBitmap bitmap = result->bitmap;
    bitmap.setImmutable();
    base::ThreadPool::PostTaskAndReplyWithResult(FROM_HERE,
        {base::TaskPriority::BEST_EFFORT},
        base::BindOnce([](std::shared_ptr<ThumbnailCapture> capture, SkBitmap bitmap) {
          if (capture->cancelled.IsSet())
            return std::vector<uint8_t>();
          auto encoded = capture->screenshot ? gfx::JPEGCodec::Encode(bitmap, 70)
              : gfx::PNGCodec::EncodeBGRASkBitmap(bitmap, false);
          const size_t limit = capture->screenshot ? 8 * 1024 * 1024 : 1024 * 1024;
          if (capture->cancelled.IsSet() || !encoded || encoded->size() > limit)
            return std::vector<uint8_t>();
          return std::move(*encoded);
        }, capture, std::move(bitmap)),
        base::BindOnce([](std::weak_ptr<TabObservation> weak,
                          std::shared_ptr<ThumbnailCapture> capture,
                          std::vector<uint8_t> bytes) {
          if (auto self = weak.lock())
            self->FinishThumbnail(std::move(capture), std::move(bytes));
        }, weak_from_this(), capture));
  }
  std::shared_ptr<ThumbnailCapture> thumbnail_;

  struct SiteDataRequest {
    SiteDataRequest();
    ~SiteDataRequest();
    base::WeakPtr<BrowserWindowInterface> owner;
    content::WeakDocumentPtr document;
    int64_t navigation = 0;
    uint64_t request = 0;
    int32_t action = BARC_SITE_COOKIES;
    std::string host;
    net::CookiePartitionKeyCollection keys;
    BarcSiteDataCallback callback = nullptr;
    bool cancelled = false;
  };
  bool SiteDataIsCurrent(const std::shared_ptr<SiteDataRequest>& pending) {
    if (!active_ || closing_ || site_data_ != pending || pending->cancelled ||
        pending->navigation != navigation_ || !pending->owner ||
        pending->owner->IsDeleteScheduled() || !web_contents()) return false;
    auto* frame = pending->document.AsRenderFrameHostIfValid();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    return frame && frame == web_contents()->GetPrimaryMainFrame() &&
        owner == pending->owner.get() && owner->IsSelectedForNativeWindow() &&
        Window(owner->GetSessionID().id()) == owner && LookupTab(owner, tab_id()) == tab &&
        owner->GetTabStripModel()->GetActiveTab() == tab &&
        tab->GetContents() == web_contents() &&
        frame->GetBrowserContext() == owner->GetProfile();
  }
  void ClearExactCookies(std::shared_ptr<SiteDataRequest> pending,
                         const std::vector<net::CanonicalCookie>& cookies) {
    if (!SiteDataIsCurrent(pending)) { FinishSiteData(pending, true); return; }
    // host_name filters only host cookies; including_domains expands to eTLD+1.
    // Neither preserves the product's exact host/.host scope. Delete selected
    // canonical cookies instead, explicitly retaining unrelated CHIPS keys.
    std::vector<net::CanonicalCookie> matching;
    for (const auto& cookie : cookies) {
      if ((cookie.Domain() == pending->host || cookie.Domain() == "." + pending->host) &&
          (!cookie.IsPartitioned() || pending->keys.Contains(*cookie.PartitionKey())))
        matching.push_back(cookie);
    }
    if (matching.empty()) { FinishSiteData(pending, true); return; }
    auto done = base::BarrierCallback<bool>(matching.size(), base::BindOnce(
        [](std::weak_ptr<TabObservation> weak, std::shared_ptr<SiteDataRequest> pending,
           const std::vector<bool>& results) {
          if (auto self = weak.lock()) self->FinishSiteData(pending,
              std::ranges::all_of(results, [](bool result) { return result; }));
        }, weak_from_this(), pending));
    auto* manager = pending->document.AsRenderFrameHostIfValid()
                        ->GetStoragePartition()->GetCookieManagerForBrowserProcess();
    for (const auto& cookie : matching) {
      manager->DeleteCanonicalCookie(cookie,
          mojo::WrapCallbackWithDefaultInvokeIfNotRun(base::BindOnce(done), false));
    }
  }
  void FinishSiteData(std::shared_ptr<SiteDataRequest> pending, bool success) {
    if (site_data_ != pending) return;
    auto keep_alive = shared_from_this();
    int32_t result = !SiteDataIsCurrent(pending) ? BARC_SITE_CANCELLED :
        (success ? BARC_SITE_COMPLETED : BARC_SITE_FAILED);
    site_data_remover_.Reset();
    site_data_.reset();
    if (result == BARC_SITE_COMPLETED && pending->action == BARC_SITE_COOKIES_AND_RELOAD) {
      auto* owner = pending->owner.get();
      result = chrome::IsCommandEnabled(owner, IDC_RELOAD) && chrome::ExecuteCommand(owner, IDC_RELOAD)
          ? BARC_SITE_COMPLETED : BARC_SITE_FAILED;
    }
    if (!active_ || !pending->callback) return;
    base::AutoReset<int> callback_scope(&navigation_callback_depth, navigation_callback_depth + 1);
    pending->callback(context_.get(), token_, pending->request, result);
  }
  std::shared_ptr<SiteDataRequest> site_data_;
  uint64_t style_request_ = 0;
  content::WeakDocumentPtr translation_document_;
  uint64_t translation_generation_ = 0;
  uint64_t translation_request_ = 0;
  BarcTranslationCallback translation_callback_ = nullptr;
  mojo::AssociatedReceiver<chrome::mojom::NookTranslationClient> translation_receiver_{this};
  base::ScopedObservation<content::BrowsingDataRemover,
                           content::BrowsingDataRemover::Observer> site_data_remover_{this};

  void UnbindOwner() {
    StopFaviconObservation();
    vault_keys_.Unregister();
    ClearVaultFocus();
    CancelVaultPasskey();
    ClearVaultSave();
    vault_selection_ = {}; vault_active_ = {}; vault_inactive_ = {}; vault_tab_ = {};
    window_cancelled_ = {};
    if (strip_)
      strip_->RemoveObserver(this);
    strip_ = nullptr;
  }
  void BindOwner() {
    UnbindOwner();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (!owner)
      return;
    strip_ = owner->GetTabStripModel();
    strip_->AddObserver(this);
    if (vault_callback_ || vault_passkey_callback_ || vault_save_callback_) ObserveVaultOwner();
    ObserveVaultKeys();
    window_cancelled_ = owner->RegisterBrowserCloseCancelled(base::BindRepeating(
        &TabObservation::WindowCloseCancelled, base::Unretained(this)));
  }
  void WindowCloseCancelled(BrowserWindowInterface* owner,
                            BrowserWindowInterface::ClosingStatus status) {
    if (status != BrowserWindowInterface::ClosingStatus::kDeniedByUser &&
        status != BrowserWindowInterface::ClosingStatus::kDeniedByPolicy)
      return;
    auto* tab = tab_.Get();
    auto* controller = UnloadController::From(owner);
    if (!tab || tab->GetBrowserWindowInterface() != owner || !controller ||
        controller->IsWaitingForDownloadCloseConfirmation())
      return;
    Emit(BARC_TAB_CLOSE_CANCELLED);
  }
  void Detach(tabs::TabInterface*, tabs::TabInterface::DetachReason reason) {
    auto keep_alive = shared_from_this();
    CancelPicker();
    CancelScript();
    CancelFiles();
    if (!active_) return;
    peek_request_.reset();
    peek_current_serial_ = 0;
    if (thumbnail_)
      thumbnail_->cancelled.Set();
    if (site_data_) site_data_->cancelled = true;
    if (reason == tabs::TabInterface::DetachReason::kDelete)
      Close();
    else
      UnbindOwner();
  }
  void Inserted(tabs::TabInterface*) {
    auto keep_alive = shared_from_this();
    BindOwner();
    BindFaviconDriver();
    ScheduleLoadProgress();
    Emit(BARC_TAB_STATE);
    RefreshMedia();
  }
  void Discard(tabs::TabInterface*, content::WebContents*,
               content::WebContents* replacement) {
    auto keep_alive = shared_from_this();
    CancelPicker();
    CancelScript();
    CancelFiles();
    if (!active_) return;
    if (thumbnail_)
      thumbnail_->cancelled.Set();
    if (site_data_) site_data_->cancelled = true;
    navigation_ = 0;
    blocked_url_.reset();
    navigation_flags_ = 0;
    committed_ = false;
    translation_receiver_.reset();
    translation_callback_ = nullptr;
    translation_document_ = {};
    media_receiver_.reset();
    media_snapshot_.reset();
    media_document_ = {};
    media_refresh_pending_ = false;
    StopFaviconObservation();
    Observe(replacement);
    BindFaviconDriver();
    ScheduleLoadProgress();
    if (media_callback_) RefreshMedia(true);
    Emit(BARC_TAB_STATE);
    if (media_callback_) {
      if (!active_ || !media_callback_) return;
      if (auto* session = content::MediaSession::GetIfExists(replacement)) BindMedia(session);
      else RefreshMedia();
    }
  }
  void Close() {
    auto keep_alive = shared_from_this();
    if (!active_)
      return;
    // Keep duplicate admission blocked through the terminal callout, including
    // when it unsubscribes before attempting to bind the closing tab again.
    closing_ = true;
    CancelPicker();
    CancelScript();
    CancelFiles();
    if (!active_) return;
    auto callback = callback_;
    void* context = context_.get();
    callback_ = nullptr;
    context_ = nullptr;
    active_ = false;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (callback) {
      base::AutoReset<int> callback_scope(&navigation_callback_depth,
                                          navigation_callback_depth + 1);
      callback(context, token_, BARC_TAB_CLOSED,
               owner ? owner->GetSessionID().id() : 0, tab_id(), "", "", 0,
               owner && UnloadController::From(owner)->owner_close_admitted()
                   ? BARC_TAB_OWNER_ENDED : 0);
    }
    ObservationTable().erase(token_);
    Cancel();
  }
  BarcTabFaviconCallback favicon_callback_ = nullptr;
  bool favicon_pending_ = false;
  base::ScopedObservation<favicon::FaviconDriver, favicon::FaviconDriverObserver>
      favicon_driver_{this};
  BarcLoadProgressCallback load_progress_callback_ = nullptr;
  bool load_progress_pending_ = false;
  BarcMediaCallback media_callback_ = nullptr;
  mojo::Receiver<media_session::mojom::MediaSessionObserver> media_receiver_{this};
  std::optional<MediaSnapshot> media_snapshot_;
  content::WeakDocumentPtr media_document_;
  bool media_refresh_pending_ = false;
  bool peek_enabled_ = false;
  bool peek_on_shift_click_ = false;
  bool option_click_ = false;
  int32_t peek_serial_ = 0;
  int32_t peek_current_serial_ = 0;
  std::optional<PeekRequest> peek_request_;
  const uint64_t token_;
  const tabs::TabHandle tab_;
  BarcTabCallback callback_;
  raw_ptr<void> context_;
  bool active_ = true;
  bool closing_ = false;
  int64_t navigation_ = 0;
  std::optional<GURL> blocked_url_;
  bool committed_ = false;
  uint32_t navigation_flags_ = 0;
  raw_ptr<TabStripModel> strip_ = nullptr;
  base::CallbackListSubscription window_cancelled_;
  base::CallbackListSubscription detach_, insert_, discard_, picker_deactivate_;
  base::WeakPtrFactory<TabObservation> load_progress_tasks_{this};
  base::WeakPtrFactory<TabObservation> favicon_tasks_{this};
};
TabObservation::ThumbnailCapture::ThumbnailCapture() = default;
TabObservation::ThumbnailCapture::~ThumbnailCapture() = default;
TabObservation::SiteDataRequest::SiteDataRequest() = default;
TabObservation::SiteDataRequest::~SiteDataRequest() = default;
}  // namespace

int barc_tab_start_boost_picker(uint64_t observation, uint64_t request,
    BarcPickerCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(observation);
  return found != ObservationTable().end() && found->second->StartPicker(request, callback);
}
int barc_tab_cancel_boost_picker(uint64_t observation, uint64_t request) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) || !request) return 0;
  auto found = ObservationTable().find(observation);
  if (found == ObservationTable().end()) return 0;
  found->second->CancelPicker(request);
  return 1;
}

int barc_tab_evaluate_script(uint64_t observation, uint64_t request,
    int32_t mode, int32_t world, const char* source, BarcScriptCallback callback) {
  // The C contract requires readable NUL-terminated UTF-8. Bound allocation
  // before copying that caller-owned input; no body or script inspection.
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) || !source ||
      UNSAFE_BUFFERS(strnlen(source, 128 * 1024 + 1)) > 128 * 1024 ||
      !base::IsStringUTF8(source))
    return 0;
  auto found = ObservationTable().find(observation);
  return found != ObservationTable().end() &&
      found->second->EvaluateScript(request, mode, world, source, callback);
}
int barc_tab_cancel_script(uint64_t observation, uint64_t request) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) || !request)
    return 0;
  auto found = ObservationTable().find(observation);
  if (found == ObservationTable().end()) return 0;
  found->second->CancelScript(request);
  return 1;
}

int barc_tab_close_selecting(uint64_t observation, int32_t successor) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(observation);
  if (found == ObservationTable().end()) return 0;
  if (navigation_callback_depth) {
    return content::GetUIThreadTaskRunner({})->PostNonNestableTask(
        FROM_HERE, base::BindOnce(
                       [](uint64_t observation, int32_t successor) {
                         barc_tab_close_selecting(observation, successor);
                       },
                       observation, successor));
  }
  return found->second->CloseSelecting(successor);
}
int barc_tab_enable_peek(uint64_t observation, int enabled) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      enabled < 0 || enabled > (BARC_TAB_PEEK_CAPABLE | BARC_TAB_PEEK_ON_SHIFT_CLICK)) return 0;
  auto found = ObservationTable().find(observation);
  return found != ObservationTable().end() && found->second->EnablePeek(enabled);
}

int barc_tab_renderer_state(int32_t window, int32_t tab_id, int32_t* pid,
                            int32_t* document_visible) {
#if !BUILDFLAG(IS_MAC) || BUILDFLAG(ENABLE_VR)
  return 0;
#else
  if (!pid || !document_visible || pid == document_visible)
    return 0;
  auto* owner = Window(window);  // Refuses off the UI thread.
  if (!owner || !bark::BarkWindowHost::ForBrowser(owner) ||
      !owner->GetProfile()->IsRegularProfile()) {
    return 0;
  }
  auto* tab = LookupTab(owner, tab_id);
  auto* contents = tab ? tab->GetContents() : nullptr;
  if (!contents || contents->IsBeingDestroyed() ||
      contents->GetBrowserContext() != owner->GetProfile() ||
      contents->GetOuterWebContents()) {
    return 0;
  }
  auto* frame = contents->GetPrimaryMainFrame();
  if (!frame || !frame->IsActive() || !frame->IsRenderFrameLive())
    return 0;
  auto* host = frame->GetProcess();
  if (!host || !host->IsInitializedAndNotDead() ||
      !host->GetProcess().IsValid()) {
    return 0;
  }
  const auto renderer_pid = host->GetProcess().Pid();
  if (renderer_pid <= 0)
    return 0;

  // Match WebContentsImpl::CalculatePageVisibilityState for a top-level
  // macOS document. Blink exposes kHiddenButPainting, including hidden capture
  // and Picture-in-Picture, as document.hidden. The widget's visibility can
  // differ from the page's visibility during visible capture.
  const bool visible = contents->GetVisibility() == content::Visibility::VISIBLE ||
                       contents->IsBeingVisiblyCaptured();
  *pid = renderer_pid;
  *document_visible = visible ? 1 : 0;
  return 1;
#endif
}

uint64_t barc_tab_observe(int32_t window, int32_t tab_id,
                          BarcTabCallback callback, void* context) {
  auto* tab = LookupTab(Window(window), tab_id);
  if (!tab || !callback)
    return 0;
  for (const auto& entry : ObservationTable())
    if (entry.second->tab_id() == tab_id)
      return 0;
  static uint64_t next_token = 0;
  CHECK_NE(next_token, UINT64_MAX);
  const uint64_t token = ++next_token;
  auto observer = std::make_shared<TabObservation>(token, tab, callback, context);
  ObservationTable().emplace(token, observer);
  observer->Emit(BARC_TAB_INITIAL);
  return observer->active() ? token : 0;
}
void barc_tab_unobserve(uint64_t token) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI))
    return;
  auto found = ObservationTable().find(token);
  if (found == ObservationTable().end())
    return;
  auto observer = found->second;
  if (!observer->closing())
    ObservationTable().erase(found);
  observer->Cancel();
}
int barc_tab_capture_thumbnail(uint64_t token, uint64_t request,
                               BarcTabThumbnailCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI))
    return 0;
  const auto found = ObservationTable().find(token);
  return found != ObservationTable().end() &&
         found->second->CaptureThumbnail(request, callback);
}

int barc_tab_capture_screenshot(uint64_t token, uint64_t request, int32_t max_width,
                                 BarcTabThumbnailCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) || max_width < 1 || max_width > 4096)
    return 0;
  const auto found = ObservationTable().find(token);
  return found != ObservationTable().end() &&
         found->second->CaptureThumbnail(request, callback, max_width);
}
int barc_tab_cancel_capture(uint64_t token, uint64_t request) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  const auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->CancelCapture(request);
}

int barc_tab_download_file(uint64_t token,uint64_t request,const char* url,const char* directory,BarcFileCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) || !url || !directory) return 0;
  auto found=ObservationTable().find(token);
  return found!=ObservationTable().end() && found->second->DownloadFile(request,GURL(url),base::FilePath::FromUTF8Unsafe(directory),callback);
}
int barc_tab_cancel_file(uint64_t token,uint64_t request) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found=ObservationTable().find(token);
  return found!=ObservationTable().end() && found->second->CancelFile(request);
}

int barc_tab_observe_vault_passkeys(uint64_t token, BarcVaultPasskeyCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  if (callback && !barc::UsesPawlPasswordProvider()) return 0;
  auto found = ObservationTable().find(token); if (found == ObservationTable().end()) return 0;
  auto retained = found->second; retained->ObserveVaultPasskeys(callback); return 1;
}
int barc_tab_vault_passkey_is_current(uint64_t token,uint64_t request) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->VaultPasskeyCurrent(request);
}
int barc_tab_complete_vault_passkey(uint64_t token,uint64_t request,int32_t accepted,const char* result) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token); if (found == ObservationTable().end()) return 0;
  std::optional<std::string> copied;
  if (accepted) {
    if (!result) return 0;
    // Trusted C caller promises a readable NUL-terminated result. No secrets in logs.
    const size_t length = UNSAFE_BUFFERS(strnlen(result,262145));
    if (length > 262144) return 0;
    copied.emplace(result,length);
    if (!base::IsStringUTF8(*copied)) return 0;
  }
  auto retained = found->second;
  return retained->CompleteVaultPasskey(request,accepted != 0,std::move(copied));
}
int barc_tab_observe_vault_save(uint64_t token, BarcVaultSaveCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  if (callback && !barc::UsesPawlPasswordProvider()) return 0;
  auto found = ObservationTable().find(token);
  if (found == ObservationTable().end()) return 0;
  auto retained = found->second;
  retained->ObserveVaultSave(callback);
  return 1;
}
int barc_tab_vault_save_is_current(uint64_t token, uint64_t submission) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->VaultSaveCurrent(submission);
}
int barc_tab_cancel_vault_save(uint64_t token, uint64_t submission) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  if (found == ObservationTable().end() || !found->second->vault_submission_ ||
      found->second->vault_submission_->token != submission) return 0;
  auto retained = found->second;
  retained->ClearVaultSave();
  return 1;
}
int barc_tab_observe_vault(uint64_t token, BarcVaultCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  if (callback && !barc::UsesPawlPasswordProvider()) return 0;
  auto found = ObservationTable().find(token);
  if (found == ObservationTable().end() || !found->second->active()) return 0;
  auto retained = found->second;
  retained->ObserveVault(callback);
  return 1;
}
int barc_tab_vault_focus_is_current(uint64_t token, uint64_t focus) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->VaultCurrent(focus);
}
int barc_tab_vault_field_is_current(uint64_t token, uint64_t focus) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->VaultCurrent(focus, false);
}
int barc_tab_cancel_vault_focus(uint64_t token, uint64_t focus) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  if (found == ObservationTable().end()) return 0;
  auto retained = found->second;
  return retained->CancelVaultFocus(focus);
}
int barc_tab_fill_vault(uint64_t token, uint64_t focus, const char* username, const char* secret) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->FillVault(focus, username, secret);
}

int barc_tab_translate(uint64_t observation, uint64_t generation,
    uint64_t request, int32_t operation, const char* pairs, BarcTranslationCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || !pairs || !callback) return 0;
  auto found = ObservationTable().find(observation);
  return found != ObservationTable().end() &&
      found->second->Translate(generation, request, operation, pairs, callback);
}

int barc_tab_set_user_css(uint64_t token, uint64_t request,
                          const char* committed_url, const char* css,
                          BarcStyleCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || !committed_url || !css) return 0;
  const auto found = ObservationTable().find(token);
  return found != ObservationTable().end() &&
      found->second->SetUserCSS(request, GURL(committed_url), css, callback);
}

int barc_tab_clear_site_data(uint64_t token, uint64_t request, int32_t action,
                             BarcSiteDataCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || navigation_callback_depth)
    return 0;
  const auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->ClearSiteData(request, action, callback);
}
int barc_tab_bind_favicon(uint64_t observation, BarcTabFaviconCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped) {
    return 0;
  }
  auto found = ObservationTable().find(observation);
  return found != ObservationTable().end() &&
         found->second->SetFaviconCallback(callback);
}
int barc_tab_observe_load_progress(uint64_t observation,
                                   BarcLoadProgressCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped) {
    return 0;
  }
  auto found = ObservationTable().find(observation);
  return found != ObservationTable().end() &&
         found->second->SetLoadProgressCallback(callback);
}
int barc_tab_observe_media(uint64_t observation, BarcMediaCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped) return 0;
  auto found = ObservationTable().find(observation);
  if (found == ObservationTable().end()) return 0;
  auto retained = found->second;
  return retained->SetMediaCallback(callback);
}
int barc_tab_create_peek(uint64_t observation, int32_t serial,
                         BarcTransferAdmission admission, void* context) {
  auto found = ObservationTable().find(observation);
  if (!admission || navigation_callback_depth || found == ObservationTable().end()) return 0;
  auto observed = found->second;
  if (!observed->PeekRequestIsCurrent(serial)) return 0;
  auto* source = tabs::TabHandle(observed->tab_id()).Get();
  auto* owner = source ? source->GetBrowserWindowInterface() : nullptr;
  if (!owner || barc::PeekForSource(source)) return 0;
  auto source_alive = source->GetWeakPtr();
  auto owner_alive = owner->GetWeakPtr();
  const int32_t owner_id = owner->GetSessionID().id();
  const bool same_client = bark::BarkWindowHost::ForBrowser(owner) != nullptr;
  const int32_t target_id = same_client
      ? owner_id
      : barc_window_new_peer_in_native_window(owner_id, owner_id);
  auto* target = Window(target_id);
  const auto close_empty_peer = [&] {
    if (!same_client) {
      auto* live = Window(target_id);
      if (live && live->GetTabStripModel()->empty()) live->GetWindow()->Close();
    }
  };
  if (!target || !source_alive || !owner_alive ||
      source_alive->GetBrowserWindowInterface() != owner_alive.get() ||
      target->GetProfile() != owner_alive->GetProfile() ||
      !observed->PeekRequestIsCurrent(serial) || barc::PeekForSource(source_alive.get())) {
    close_empty_peer(); return 0;
  }
  auto request = observed->TakePeekRequest(serial);
  if (!request) { close_empty_peer(); return 0; }
  // Stock context-menu new-tab navigation has no invented JavaScript opener.
  content::WebContents::CreateParams create(target->GetProfile());
  auto blank = content::WebContents::Create(create);
  NavigateParams insert(target, std::move(blank));
  insert.disposition = WindowOpenDisposition::NEW_BACKGROUND_TAB;
  insert.window_action = NavigateParams::WindowAction::kNoAction;
  Navigate(&insert);
  target = Window(target_id);
  auto* contents = insert.navigated_or_inserted_contents.get();
  if (!target || !contents || target->GetTabStripModel()->GetIndexOfWebContents(contents) == TabStripModel::kNoTab) {
    close_empty_peer(); return 0;
  }
  auto* peek = tabs::TabInterface::GetFromContents(contents);
  auto peek_alive = peek->GetWeakPtr();
  const int32_t tab_id = peek->GetHandle().raw_value();
  auto current = [&] {
    auto* live = Window(target_id);
    auto* host = bark::BarkWindowHost::ForBrowser(live);
    auto* main = request->main_document.AsRenderFrameHostIfValid();
    return live && source_alive && owner_alive && peek_alive && main &&
        request->document.AsRenderFrameHostIfValid() &&
        source_alive->GetContents()->GetPrimaryMainFrame() == main &&
        source_alive->GetBrowserWindowInterface() == owner_alive.get() &&
        LookupTab(live, tab_id) == peek_alive.get() &&
        (same_client
             ? host && !host->closing() &&
                   !UnloadController::From(live)->is_attempting_to_close_browser()
             : live->GetTabStripModel()->GetActiveTab() == peek_alive.get()) &&
        owner_alive->IsSelectedForNativeWindow() &&
        owner_alive->GetTabStripModel()->GetActiveTab() == source_alive.get() &&
        live->GetProfile() == owner_alive->GetProfile() &&
        observed->PeekSerialIsCurrent(serial) && barc::CanResolveApplicationBrowser() &&
        !UnloadController::From(live)->owner_close_admitted() &&
        !UnloadController::From(owner_alive.get())->owner_close_admitted();
  };
  auto refuse = [&] {
    if (peek_alive) ClearPeekRole(peek_alive.get());
    if (auto* live = LookupTab(Window(target_id), tab_id)) {
      // No target navigation has happened. A callback may have moved it; only
      // this still-owned untouched blank can be closed here.
      if (live->GetContents()->GetController().IsInitialBlankNavigation() &&
          !live->GetContents()->GetController().GetPendingEntry()) {
        ClearPeekRole(live);
        barc_tab_close(target_id, tab_id);
      }
    }
    close_empty_peer(); return 0;
  };
  if (!current()) return refuse();
  contents->WasHidden();
  if (!current()) return refuse();
  contents->SetUserData(&kPeekRoleKey, std::make_unique<PeekRole>(peek, source_alive.get()));
  source_alive->GetContents()->SetUserData(&kPeekSourceKey, std::make_unique<PeekSource>(source_alive.get(), peek));
  int accepted = 0;
  {
    base::AutoReset guard(&navigation_callback_depth, navigation_callback_depth + 1);
    accepted = admission(context, target_id, tab_id);
  }
  if (!accepted || !current() ||
      !barc::IsPeekPair(source_alive.get(), peek_alive.get()) ||
      !peek_alive->GetContents()->GetController().IsInitialBlankNavigation() ||
      peek_alive->GetContents()->GetController().GetPendingEntry())
    return refuse();
  // The existing observer is now bound. Reuse Chromium's captured stock link
  // parameters (initiator/referrer/protocol handling), never a replayed URL.
  request->params.disposition = WindowOpenDisposition::CURRENT_TAB;
  content::NavigationController::LoadURLParams load(request->params);
  peek_alive->GetContents()->GetController().LoadURLWithParams(load);
  barc::BrowserDiscoveryChanged();
  return 1;
}

namespace barc {
base::RepeatingCallback<bool()> VaultPasskeyContext(content::RenderFrameHost* frame) {
  auto* contents = frame ? content::WebContents::FromRenderFrameHost(frame) : nullptr;
  for (const auto& [token,observer] : ObservationTable()) {
    if (observer->web_contents() != contents || !observer->active() || !observer->vault_passkey_callback_) continue;
    auto* tab = tabs::TabInterface::GetFromContents(contents);
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* widget = observer->MountedVaultWidget();
    if (!frame || !widget) return {};
    return base::BindRepeating([](std::weak_ptr<TabObservation> weak,content::WeakDocumentPtr document,
        base::WeakPtr<BrowserWindowInterface> owner,base::WeakPtr<views::Widget> widget) {
      auto self = weak.lock(); return self && self->VaultPasskeyContextCurrent(document,owner,widget);
    },std::weak_ptr<TabObservation>(observer),frame->GetWeakDocumentPtr(),owner->GetWeakPtr(),widget->GetWeakPtr());
  }
  return {};
}
base::OnceClosure StartVaultPasskeyRequest(content::RenderFrameHost* frame,
    const url::Origin& origin,int operation,base::DictValue arguments,
    base::OnceCallback<void(std::optional<std::string>)> reply) {
  auto* contents = frame ? content::WebContents::FromRenderFrameHost(frame) : nullptr;
  std::string json;
  if (UsesPawlPasswordProvider() && frame &&
      frame->GetLastCommittedOrigin() == origin &&
      (operation == 0 || operation == 1) && base::JSONWriter::Write(arguments,&json) && json.size() <= 65536) {
    std::vector<std::shared_ptr<TabObservation>> observers;
    for (const auto& [token,observer] : ObservationTable())
      if (observer->web_contents() == contents && observer->vault_passkey_callback_) observers.push_back(observer);
    if (!observers.empty()) return observers.front()->StartVaultPasskey(frame,operation,std::move(json),std::move(reply));
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
      base::BindOnce(std::move(reply),std::nullopt)); return {};
}
bool OfferVaultPasswordSave(content::WebContents* contents,
                            const password_manager::PasswordForm& credentials) {
  if (!contents || !UsesPawlPasswordProvider()) return false;
  // Snapshot existing observation ownership; no separate save registry.
  std::vector<std::shared_ptr<TabObservation>> observers;
  for (const auto& [token, observer] : ObservationTable())
    if (observer->web_contents() == contents) observers.push_back(observer);
  for (const auto& observer : observers)
    if (observer->OfferVaultSave(credentials)) return true;
  return false;
}

void CancelDocumentDownloadsForProfilePath(const base::FilePath& path) {
  std::vector<std::shared_ptr<TabObservation>> observers;
  for (const auto& [id,observer]:ObservationTable()) observers.push_back(observer);
  for (auto& observer:observers) observer->CancelFilesForProfile(path);
}
void RecordNativeNavigationBlock(content::WebContents* contents,
                                 int64_t navigation, const GURL& url) {
  if (!contents) return;
  for (const auto& [token, observer] : ObservationTable()) {
    if (observer->web_contents() == contents) {
      observer->RecordNativeBlock(navigation, url);
      return;
    }
  }
}
void NotifyPeekCloseCancelled(tabs::TabInterface* tab) {
  if (!tab) return;
  std::vector<std::shared_ptr<TabObservation>> observers;
  for (const auto& [token, observer] : ObservationTable()) {
    if (observer->tab_id() == tab->GetHandle().raw_value()) observers.push_back(observer);
  }
  for (const auto& observer : observers) observer->Emit(BARC_TAB_CLOSE_CANCELLED);
}
bool CanRequestPeek(content::RenderFrameHost* frame) {
  if (!frame || !IsNativeApplicationRegistered()) return false;
  for (const auto& [token, observation] : ObservationTable()) {
    if (observation->CanRequestPeek(frame)) return true;
  }
  return false;
}
bool RequestPeekForShiftClick(content::WebContents* source,
                              const content::OpenURLParams& params) {
  auto* frame = content::RenderFrameHost::FromID(params.source_render_process_id,
                                                 params.source_render_frame_id);
  if (!source || !frame || !params.user_gesture || !params.is_renderer_initiated ||
      params.started_from_context_menu || !IsNativeApplicationRegistered() ||
      content::WebContents::FromRenderFrameHost(frame) != source) return false;
  for (const auto& [token, observation] : ObservationTable()) {
    if (observation->PeeksOnShiftClick() && observation->CanRequestPeek(frame)) {
      auto retained = observation;
      retained->RequestPeek(frame, params);
      return true;
    }
  }
  return false;
}
bool RequestPeekForOptionClick(content::WebContents* source, const GURL& url,
                               const std::optional<url::Origin>& initiator) {
  auto* frame = source ? source->GetPrimaryMainFrame() : nullptr;
  if (!frame || !IsNativeApplicationRegistered()) return false;
  for (const auto& [token, observation] : ObservationTable()) {
    if (observation->CanRequestPeek(frame) && observation->TakeOptionClick()) {
      content::OpenURLParams params(url, content::Referrer(frame->GetLastCommittedURL(),
                                                           network::mojom::ReferrerPolicy::kDefault),
                                    WindowOpenDisposition::NEW_BACKGROUND_TAB,
                                    ui::PAGE_TRANSITION_LINK, /*is_renderer_initiated=*/true);
      params.initiator_origin = initiator;
      params.user_gesture = true;
      auto retained = observation;
      retained->RequestPeek(frame, params);
      return true;
    }
  }
  return false;
}
void RequestPeek(content::RenderFrameHost* frame,
                 const content::OpenURLParams& params) {
  if (!frame || !IsNativeApplicationRegistered()) return;
  // Observations are the existing page ownership, not a second tab lookup map.
  for (const auto& [token, observation] : ObservationTable()) {
    if (observation->CanRequestPeek(frame)) {
      auto retained = observation;
      retained->RequestPeek(frame, params);
      return;
    }
  }
}
}  // namespace barc
