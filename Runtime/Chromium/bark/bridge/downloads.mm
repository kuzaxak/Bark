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
class NativeDownloadManager;
struct NativeDownloadData {
  std::weak_ptr<NativeDownloadManager> source;
  uint64_t manager = 0;
  int32_t event = BARC_DOWNLOAD_ITEM;
  std::string profile, guid, url, target, filename;
  int32_t state = BARC_DOWNLOAD_PROGRESS;
  int32_t error = 0;
  uint32_t flags = 0;
  int64_t received = 0, total = -1;
  double started = 0;
};
class NativeDownloadManager final
    : public content::DownloadManager::Observer,
      public download::DownloadItem::Observer,
      public std::enable_shared_from_this<NativeDownloadManager> {
 public:
  NativeDownloadManager(content::DownloadManager* manager, uint64_t id,
      std::string profile, bool is_private,
      base::RepeatingCallback<void(NativeDownloadData)> publish,
      base::RepeatingCallback<void(uint64_t)> ended)
      : manager_(manager), id_(id), profile_(std::move(profile)),
        private_(is_private), publish_(std::move(publish)), ended_(std::move(ended)) {}
  ~NativeDownloadManager() override { Cancel(); }
  uint64_t id() const { return id_; }
  bool active() const { return manager_ != nullptr; }
  bool owns(content::DownloadManager* manager) const { return manager_ == manager; }
  void Start() {
    manager_->AddObserver(this);
    content::DownloadManager::DownloadVector items;
    manager_->GetAllDownloads(&items);
    for (const auto& item : items) Add(item.get());
  }
  void Cancel() {
    items_.RemoveAllObservations();
    if (manager_) manager_->RemoveObserver(this);
    manager_ = nullptr;
  }
  bool CanAction(const std::string& guid, int32_t action) const {
    auto* item = manager_ ? manager_->GetDownloadByGuid(guid) : nullptr;
    if (!item) return false;
    if (action == BARC_DOWNLOAD_CANCEL) return item->GetState() == download::DownloadItem::IN_PROGRESS;
    if (action == BARC_DOWNLOAD_REMOVE) return item->IsDone();
    return false;
  }
  std::string SafeTarget(const std::string& guid) const {
    auto* item = manager_ ? manager_->GetDownloadByGuid(guid) : nullptr;
    return item && SafeFile(item) ? item->GetTargetFilePath().AsUTF8Unsafe() : std::string();
  }
  bool Action(const std::string& guid, int32_t action) {
    if (!CanAction(guid, action)) return false;
    auto* item = manager_->GetDownloadByGuid(guid);
    if (action == BARC_DOWNLOAD_CANCEL && item->GetState() == download::DownloadItem::IN_PROGRESS) {
      item->Cancel(true);
      return true;
    }
    if (action == BARC_DOWNLOAD_REMOVE && item->IsDone()) {
      item->Remove();
      return true;
    }
    return false;
  }
  void OnDownloadCreated(content::DownloadManager*, download::DownloadItem* item) override { Add(item); }
  void OnManagerInitialized() override {
    content::DownloadManager::DownloadVector items;
    manager_->GetAllDownloads(&items);
    for (const auto& item : items) Add(item.get());
  }
  void ManagerGoingDown(content::DownloadManager*) override {
    auto keep_alive = shared_from_this();
    Cancel();
    auto data = Data(nullptr); data.event = BARC_DOWNLOAD_MANAGER_ENDED;
    publish_.Run(std::move(data));
    ended_.Run(id_);
  }
  void OnDownloadUpdated(download::DownloadItem* item) override { publish_.Run(Data(item)); }
  void OnDownloadRemoved(download::DownloadItem* item) override {
    auto data = Data(item); data.event = BARC_DOWNLOAD_REMOVED;
    publish_.Run(std::move(data));
  }
  void OnDownloadDestroyed(download::DownloadItem* item) override {
    OnDownloadRemoved(item);
    items_.RemoveObservation(item);
  }
 private:
  static bool SafeFile(download::DownloadItem* item) {
    return item->GetState() == download::DownloadItem::COMPLETE &&
        !item->IsDangerous() && !item->IsInsecure() &&
        !item->GetFileExternallyRemoved() && !item->GetTargetFilePath().empty();
  }
  void Add(download::DownloadItem* item) {
    if (!items_.IsObservingSource(item)) items_.AddObservation(item);
    publish_.Run(Data(item));
  }
  NativeDownloadData Data(download::DownloadItem* item) {
    NativeDownloadData data;
    data.source = weak_from_this(); data.manager = id_; data.profile = profile_;
    if (private_) data.flags |= BARC_DOWNLOAD_PRIVATE;
    if (!item) return data;
    data.guid = item->GetGuid(); data.url = item->GetURL().spec();
    data.target = item->GetTargetFilePath().AsUTF8Unsafe();
    data.filename = item->GetFileNameToReportUser().AsUTF8Unsafe();
    switch (item->GetState()) {
      case download::DownloadItem::IN_PROGRESS: data.state = BARC_DOWNLOAD_PROGRESS; break;
      case download::DownloadItem::COMPLETE: data.state = BARC_DOWNLOAD_COMPLETE; break;
      case download::DownloadItem::CANCELLED: data.state = BARC_DOWNLOAD_CANCELLED; break;
      case download::DownloadItem::INTERRUPTED: data.state = BARC_DOWNLOAD_INTERRUPTED; break;
      case download::DownloadItem::MAX_DOWNLOAD_STATE: NOTREACHED();
    }
    if (item->IsDangerous() || item->IsInsecure()) data.flags |= BARC_DOWNLOAD_UNSAFE;
    if (SafeFile(item)) data.flags |= BARC_DOWNLOAD_SAFE_FILE;
    data.error = static_cast<int32_t>(item->GetLastReason());
    data.received = item->GetReceivedBytes(); data.total = item->GetTotalBytes();
    data.started = item->GetStartTime().InSecondsFSinceUnixEpoch();
    return data;
  }
  raw_ptr<content::DownloadManager> manager_;
  const uint64_t id_;
  const std::string profile_;
  const bool private_;
  base::RepeatingCallback<void(NativeDownloadData)> publish_;
  base::RepeatingCallback<void(uint64_t)> ended_;
  base::ScopedMultiSourceObservation<download::DownloadItem, download::DownloadItem::Observer> items_{this};
};
class NativeDownloads final : public BrowserCollectionObserver,
                             public std::enable_shared_from_this<NativeDownloads> {
 public:
  NativeDownloads(uint64_t token, BarcDownloadCallback callback, void* context)
      : token_(token), callback_(callback), context_(context) {}
  ~NativeDownloads() override { Cancel(); }
  uint64_t token() const { return token_; }
  void Start() {
    auto* collection = GlobalBrowserCollection::GetInstance();
    collection_.Observe(collection);
    collection->ForEach([&](BrowserWindowInterface* browser) { AddBrowser(browser); return true; });
  }
  void Cancel() {
    weak_.InvalidateWeakPtrs(); callback_ = nullptr; context_ = nullptr;
    collection_.Reset(); pending_.clear();
    auto managers = std::move(managers_);
    for (auto& [manager, observer] : managers) observer->Cancel();
  }
  void OnBrowserCreated(BrowserWindowInterface* browser) override { AddBrowser(browser); }
  bool CanAction(uint64_t id, const std::string& guid, int32_t action) const {
    auto found = managers_.find(id);
    return found != managers_.end() && found->second->CanAction(guid, action);
  }
  std::string SafeTarget(uint64_t id, const std::string& guid) const {
    auto found = managers_.find(id);
    return found == managers_.end() ? std::string() : found->second->SafeTarget(guid);
  }
  int Action(uint64_t id, const std::string& guid, int32_t action) {
    auto found = managers_.find(id);
    if (found == managers_.end()) return 0;
    auto observer = found->second;
    return observer->Action(guid, action);
  }
 private:
  void AddBrowser(BrowserWindowInterface* browser) {
    if (!callback_) return;
    std::array<char, 37> identity{};
    const int32_t window = browser->GetSessionID().id();
    bool is_private = false;
    if (barc_window_profile_uuid(window, identity.data(), identity.size()) != identity.size()) {
      if (barc_window_private_session_uuid(window, identity.data(), identity.size()) != identity.size()) return;
      is_private = true;
    }
    auto* profile = browser->GetProfile();
    auto* manager = profile->GetDownloadManager();
    if (!manager || manager->GetBrowserContext() != profile ||
        std::ranges::any_of(managers_, [manager](const auto& entry) { return entry.second->owns(manager); })) return;
    CHECK_NE(next_manager_, UINT64_MAX);
    auto observer = std::make_shared<NativeDownloadManager>(manager, ++next_manager_, identity.data(), is_private,
        base::BindRepeating(&NativeDownloads::Queue, weak_.GetWeakPtr()),
        base::BindRepeating(&NativeDownloads::Ended, weak_.GetWeakPtr()));
    managers_.emplace(observer->id(), observer);
    observer->Start();
  }
  void Ended(uint64_t manager) { managers_.erase(manager); }
  void Queue(NativeDownloadData data) {
    if (!callback_) return;
    if (data.event == BARC_DOWNLOAD_MANAGER_ENDED) {
      for (auto it = pending_.begin(); it != pending_.end();) {
        if (it->first.first == data.manager) it = pending_.erase(it); else ++it;
      }
    }
    pending_[{data.manager, data.guid}] = std::move(data);
    if (queued_) return;
    queued_ = true;
    content::GetUIThreadTaskRunner({})->PostNonNestableTask(FROM_HERE,
        base::BindOnce(&NativeDownloads::Deliver, weak_.GetWeakPtr()));
  }
  void Deliver() {
    auto keep_alive = shared_from_this(); queued_ = false;
    auto pending = std::move(pending_); pending_.clear();
    for (auto& [key, data] : pending) {
      if (!callback_) break;
      if (data.event != BARC_DOWNLOAD_MANAGER_ENDED) {
        auto source = data.source.lock();
        if (!source || !source->active()) continue;
      }
      BarcDownloadSnapshot row{sizeof(BarcDownloadSnapshot), data.manager,
          data.profile.c_str(), data.guid.c_str(),
          data.url.c_str(), data.target.c_str(), data.filename.c_str(), data.state,
          data.error, data.flags, data.received, data.total, data.started};
      base::AutoReset<int> callback_scope(&navigation_callback_depth, navigation_callback_depth + 1);
      callback_(context_.get(), token_, data.event, &row);
    }
  }
  const uint64_t token_;
  BarcDownloadCallback callback_;
  raw_ptr<void> context_;
  uint64_t next_manager_ = 0;
  bool queued_ = false;
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver> collection_{this};
  std::map<uint64_t, std::shared_ptr<NativeDownloadManager>> managers_;
  std::map<std::pair<uint64_t, std::string>, NativeDownloadData> pending_;
  base::WeakPtrFactory<NativeDownloads> weak_{this};
};
std::shared_ptr<NativeDownloads>& DownloadOwner() {
  static base::NoDestructor<std::shared_ptr<NativeDownloads>> owner;
  return *owner;
}

// Tokens own observers, never tabs or profiles. Each callback holds only its
// observer alive, so unsubscribe/close during delivery cannot free its stack.
}  // namespace

namespace barc::internal {
void CancelDownloadObservation() {
  if (auto downloads = std::move(DownloadOwner())) downloads->Cancel();
}
}  // namespace barc::internal

uint64_t barc_downloads_observe(BarcDownloadCallback callback, void* context) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      !callback || DownloadOwner() || discovery_stopped ||
      !GlobalBrowserCollection::GetInstance()) return 0;
  static uint64_t next_token = 0;
  CHECK_NE(next_token, UINT64_MAX);
  auto observer = std::make_shared<NativeDownloads>(++next_token, callback, context);
  DownloadOwner() = observer;
  observer->Start();
  return observer->token();
}
void barc_downloads_unobserve(uint64_t token) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      !DownloadOwner() || DownloadOwner()->token() != token) return;
  auto observer = std::move(DownloadOwner());
  observer->Cancel();
}
int barc_download_action(uint64_t token, uint64_t manager, const char* guid, int32_t action) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      !DownloadOwner() || DownloadOwner()->token() != token || !guid ||
      (action != BARC_DOWNLOAD_CANCEL && action != BARC_DOWNLOAD_REMOVE)) return 0;
  auto observer = DownloadOwner();
  if (!observer->CanAction(manager, guid, action)) return 0;
  if (navigation_callback_depth) {
    content::GetUIThreadTaskRunner({})->PostNonNestableTask(FROM_HERE,
        base::BindOnce([](std::weak_ptr<NativeDownloads> weak, uint64_t manager,
                          std::string guid, int32_t action) {
          if (auto live = weak.lock()) live->Action(manager, guid, action);
        }, std::weak_ptr<NativeDownloads>(observer), manager, std::string(guid), action));
    return 1;
  }
  return observer->Action(manager, guid, action);
}
size_t barc_download_copy_safe_target(uint64_t token, uint64_t manager,
                                       const char* guid, char* buffer, size_t capacity) {
  base::span<char> output;
  if (buffer && capacity) {
    // SAFETY: The C caller supplies capacity writable chars, as documented.
    output = UNSAFE_BUFFERS(base::span<char>(buffer, capacity));
    output[0] = '\0';
  }
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      !DownloadOwner() || DownloadOwner()->token() != token || !guid) return 0;
  const std::string path = DownloadOwner()->SafeTarget(manager, guid);
  if (path.empty()) return 0;
  if (!output.empty()) {
    const size_t count = std::min(output.size() - 1, path.size());
    output.first(count).copy_from(base::span(path).first(count));
    output[count] = '\0';
  }
  return path.size() + 1;
}
