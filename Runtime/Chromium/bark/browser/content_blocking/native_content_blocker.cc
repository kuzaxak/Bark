// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "bark/browser/content_blocking/native_content_blocker.h"
#include "bark/bridge/barc_bridge_functions.h"

#include <algorithm>
#include <array>
#include <memory>
#include <cmath>
#include <set>
#include <utility>

#include "base/check.h"
#include "base/compiler_specific.h"
#include "crypto/hash.h"
#include "chrome/common/chrome_render_frame.mojom.h"
#include "components/back_forward_cache/back_forward_cache_disable.h"
#include "content/public/browser/back_forward_cache.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "chrome/grit/common_resources.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "content/public/browser/document_service.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/disallow_activation_reason.h"
#include "content/public/browser/web_contents_observer.h"
#include "ui/base/resource/resource_bundle.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "base/task/thread_pool.h"
#include "base/task/single_thread_task_runner.h"
#include "bark/browser/content_blocking/nook_adblock/nook_adblock.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_keyed_service_factory.h"
#include "chrome/browser/profiles/profile_selections.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "net/base/net_errors.h"
#include "content/public/browser/download_manager.h"
#include "components/download/public/common/download_url_parameters.h"
#include "components/download/public/common/download_source.h"
#include "net/base/url_util.h"
#include "net/url_request/url_request_job.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "base/strings/string_number_conversions.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "base/strings/string_split.h"
#include "third_party/blink/public/common/loader/url_loader_throttle.h"
#include "services/network/public/cpp/resource_request.h"

namespace {
using Blocker = NativeContentBlocker;
using Engine = std::unique_ptr<void, decltype(&nook_adblock_engine_free)>;
struct Publication {
  Publication(uint64_t revision, uint64_t generation,
              scoped_refptr<const base::RefCountedMemory> input,
              Blocker::Completion reply,
              std::shared_ptr<std::atomic<uint64_t>> latest)
      : revision(revision), generation(generation), borrowed(std::move(input)),
        reply(std::move(reply)), latest(std::move(latest)) {}
  const uint64_t revision;
  const uint64_t generation;
  // Only the copy window is protected. Parsing never runs under this lock.
  base::Lock copy_lock;
  scoped_refptr<const base::RefCountedMemory> borrowed GUARDED_BY(copy_lock);
  bool cancelled GUARDED_BY(copy_lock) = false;
  // UI-only. Workers never read a Swift callback or its userdata.
  Blocker::Completion reply;
  bool completed = false;
  const std::shared_ptr<std::atomic<uint64_t>> latest;
};
struct Validation {
  scoped_refptr<const base::RefCountedMemory> bytes;
  Blocker::Result::Status status = Blocker::Result::kSuperseded;
  std::array<uint8_t, crypto::hash::kSha256Size> fingerprint{};
};
struct BoostScript {
  std::string host;
  bool subdomains;
  std::string source;
  bool operator==(const BoostScript&) const = default;
};
struct PageTweaksSettings {
  std::vector<std::string> media_domains;
  base::flat_map<std::string, std::string> sponsor_block;
  std::string youtube_css;
  bool youtube_frames = false;
  bool youtube_no_hover = false;
  bool facebook_reels = false;
  bool facebook_suggested = false;
  bool reddit_hot = false;
  std::vector<BoostScript> scripts;
  bool operator==(const PageTweaksSettings&) const = default;
};
// Passive settings storage of the existing keyed-service factory. Initial
// unresolved registration must not construct Profile services or task runners.
struct FactoryPolicy {
  PageTweaksSettings page_tweaks;
  base::RepeatingClosureList page_tweaks_changed;
  bool registered = false;
  bool stopped = false;
  Blocker::Policy requested = Blocker::kUnresolved;
  std::vector<std::string> domains;
  scoped_refptr<const base::RefCountedMemory> rules;
  uint64_t revision = 0;
  uint64_t generation = 0;
  uint64_t required_generation = 0;
  uint64_t failed_generation = 0;
  uint64_t latest_generation = 0;
  uint64_t next_revision = 0;
  std::array<uint8_t, crypto::hash::kSha256Size> cosmetic_fingerprint{};
  uint64_t cosmetic_source_identity = 0;
  std::shared_ptr<std::atomic<uint64_t>> latest =
      std::make_shared<std::atomic<uint64_t>>(0);
  scoped_refptr<base::SequencedTaskRunner> publisher;
  base::RepeatingClosureList changed;
  std::vector<std::shared_ptr<Publication>> publications;
};
FactoryPolicy& PolicyOwner() {
  static base::NoDestructor<FactoryPolicy> policy;
  return *policy;
}
bool SponsorHost(const GURL& url) {
  if (!url.SchemeIsHTTPOrHTTPS()) return false;
  constexpr auto hosts = std::to_array<std::string_view>({"youtube.com", "www.youtube.com", "m.youtube.com",
      "music.youtube.com", "tv.youtube.com", "youtu.be", "youtube-nocookie.com"});
  const auto host = url.host();
  const auto dot = host.find('.');
  return std::ranges::contains(hosts, host) ||
      (dot != std::string_view::npos && std::ranges::contains(hosts, host.substr(dot + 1)));
}
std::string SponsorVideo(const GURL& url) {
  if (!SponsorHost(url)) return {};
  std::string video;
  if (!net::GetValueForKeyInQuery(url, "v", &video)) {
    const auto parts = base::SplitStringPiece(url.path(), "/", base::KEEP_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
    if (url.host() == "youtu.be" && parts.size() == 1) video = parts[0];
    else if (parts.size() == 2 && (parts[0] == "embed" || parts[0] == "v" || parts[0] == "shorts")) video = parts[1];
  }
  if (video.size() != 11 || !std::ranges::all_of(video, [](unsigned char c) {
        return base::IsAsciiAlphaNumeric(c) || c == '_' || c == '-'; })) return {};
  return video;
}
chrome::mojom::NookPageTweaksPtr PageTweaksForDocument(
    content::RenderFrameHost& frame, const GURL& url) {
  if (!url.SchemeIsHTTPOrHTTPS() || frame.GetParentOrOuterDocument()) return nullptr;
  auto out = chrome::mojom::NookPageTweaks::New();
  const auto& config = PolicyOwner().page_tweaks;
  if (SponsorHost(url)) out->sponsor_block = config.sponsor_block;
  out->social_download = std::ranges::any_of(config.media_domains,
      [&](const auto& domain) { return url.DomainIs(domain); });
  if (url.host() == "youtube.com" || url.host() == "www.youtube.com") {
    out->youtube_css = config.youtube_css;
    out->youtube_frames = config.youtube_frames;
    out->youtube_no_hover = config.youtube_no_hover;
  }
  if (url.DomainIs("facebook.com")) {
    out->facebook_reels = config.facebook_reels;
    out->facebook_suggested = config.facebook_suggested;
  }
  out->reddit_hot = config.reddit_hot && (url.host() == "reddit.com" || url.host() == "www.reddit.com");
  for (const auto& script : config.scripts)
    if (url.host() == script.host || (script.subdomains && url.DomainIs(script.host)))
      out->boost_scripts.push_back(script.source);
  return out;
}
std::optional<PageTweaksSettings> ParsePageTweaks(const uint8_t* json, size_t length) {
  if (!json || !length || length > 16 * 1024 * 1024) return std::nullopt;
  const auto input = UNSAFE_BUFFERS(std::string_view(reinterpret_cast<const char*>(json), length));
  auto value = base::JSONReader::Read(input, base::JSON_PARSE_RFC);
  if (!value || !value->is_dict()) return std::nullopt;
  const auto& root = value->GetDict();
  if ((root.size() < 6 || root.size() > 8) || root.FindInt("version") != 1) return std::nullopt;
  auto* yt = root.FindDict("youtube");
  auto* scripts = root.FindList("scripts");
  if (!yt || yt->size() != 3 || !scripts || scripts->size() > 200 ||
      !yt->FindString("css") || !yt->FindBool("frameThumbnails") || !yt->FindBool("noHoverPreview") ||
      !root.FindBool("facebookReels") || !root.FindBool("facebookSuggested") || !root.FindBool("redditHot"))
    return std::nullopt;
  PageTweaksSettings out;
  if (root.size() != 6 && !root.FindDict("sponsorBlock")) return std::nullopt;
  if (root.size() == 8 && !root.FindList("mediaDownloadSites")) return std::nullopt;
  if (const auto* domains = root.FindList("mediaDownloadSites")) {
    if (domains->size() > 256) return std::nullopt;
    for (const auto& entry : *domains) {
      if (!entry.is_string() || entry.GetString().empty() || entry.GetString().size() > 253) return std::nullopt;
      const auto& domain = entry.GetString(); const GURL site("https://" + domain + "/");
      if (!site.is_valid() || site.host() != domain || site.has_port() || site.has_username() ||
          site.has_password() || site.path() != "/" || site.has_query() || site.has_ref()) return std::nullopt;
      out.media_domains.push_back(domain);
    }
  }
  if (const auto* sponsor = root.FindDict("sponsorBlock")) {
    constexpr auto categories = std::to_array<std::string_view>({"sponsor", "selfpromo", "exclusive_access", "interaction", "intro", "outro", "preview", "filler", "music_offtopic", "poi_highlight"});
    if (sponsor->size() > categories.size()) return std::nullopt;
    for (const auto [key, option] : *sponsor) {
      if (!std::ranges::contains(categories, key) || !option.is_string() ||
          (option.GetString() != "auto" && option.GetString() != "manual")) return std::nullopt;
      out.sponsor_block[key] = option.GetString();
    }
  }

  out.youtube_css = *yt->FindString("css");
  if (out.youtube_css.size() > 65536) return std::nullopt;
  out.youtube_frames = *yt->FindBool("frameThumbnails");
  out.youtube_no_hover = *yt->FindBool("noHoverPreview");
  out.facebook_reels = *root.FindBool("facebookReels");
  out.facebook_suggested = *root.FindBool("facebookSuggested");
  out.reddit_hot = *root.FindBool("redditHot");
  for (const auto& item : *scripts) {
    if (!item.is_dict() || item.GetDict().size() != 3) return std::nullopt;
    const auto& dict = item.GetDict();
    const auto* host = dict.FindString("host");
    const auto* source = dict.FindString("source");
    auto subdomains = dict.FindBool("includeSubdomains");
    if (!host || host->empty() || host->size() > 1024 || !source || source->size() > 65536 || !subdomains)
      return std::nullopt;
    const GURL site("https://" + *host);
    if (!site.is_valid() || site.host().find('.') == std::string::npos ||
        site.host().front() == '.' || site.host().back() == '.' || site.path() != "/" ||
        site.has_username() || site.has_password() || site.has_port() || site.has_query() || site.has_ref())
      return std::nullopt;
    out.scripts.push_back({std::string(site.host()), *subdomains, *source});
  }
  return out;
}
Validation CopyAndValidate(std::shared_ptr<Publication> publication) {
  scoped_refptr<const base::RefCountedMemory> owned;
  {
    base::AutoLock lock(publication->copy_lock);
    if (publication->cancelled) return {};
    auto borrowed = std::move(publication->borrowed);
    if (!borrowed) return {nullptr, Blocker::Result::kInvalidRules};
    if (publication->latest->load() != publication->revision) {
      borrowed.reset();
      return {};
    }
    owned = base::MakeRefCounted<base::RefCountedBytes>(
        static_cast<base::span<const uint8_t>>(*borrowed));
    // Every borrowed wrapper/span is gone before the lock becomes available to
    // UI shutdown. The rest of this task reads only native-owned shared bytes.
    borrowed.reset();
  }
  if (publication->latest->load() != publication->revision) return {};
  Engine validated(nook_adblock_engine_deserialize(owned->data(), owned->size()),
                   &nook_adblock_engine_free);
  if (!validated) return {nullptr, Blocker::Result::kInvalidRules};
  // Hash only on the existing publisher worker. Re-publication of identical
  // bytes can retain eligible history; changed bytes under the same requested
  // token still invalidate the actual injected source identity.
  const auto fingerprint = crypto::hash::Sha256(
      static_cast<base::span<const uint8_t>>(*owned));
  return {std::move(owned), Blocker::Result::kReady, fingerprint};
}
void PublicationFinished(std::shared_ptr<Publication> publication,
                         Validation validation) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& policy = PolicyOwner();
  std::erase(policy.publications, publication);
  if (publication->completed) return;
  publication->completed = true;
  auto reply = std::move(publication->reply);
  auto status = validation.status;
  if (policy.stopped) status = Blocker::Result::kOwnerEnded;
  else if (policy.latest->load() != publication->revision ||
           (policy.requested == Blocker::kEnabled &&
            publication->generation != policy.required_generation))
    status = Blocker::Result::kSuperseded;
  if (status == Blocker::Result::kReady) {
    if (!policy.rules || policy.cosmetic_fingerprint != validation.fingerprint) {
      policy.cosmetic_source_identity = publication->revision;
      policy.cosmetic_fingerprint = validation.fingerprint;
    }
    policy.rules = std::move(validation.bytes);
    policy.revision = publication->revision;
    policy.generation = publication->generation;
    if (policy.failed_generation == publication->generation)
      policy.failed_generation = 0;
    policy.changed.Notify();
    if (policy.stopped) status = Blocker::Result::kOwnerEnded;
    else if (policy.latest->load() != publication->revision)
      status = Blocker::Result::kSuperseded;
  }
  if (status == Blocker::Result::kInvalidRules) {
    policy.failed_generation = publication->generation;
    policy.changed.Notify();
    if (policy.stopped) status = Blocker::Result::kOwnerEnded;
  }
  std::move(reply).Run({publication->revision, status});
}
uint64_t NextNativeContextID() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  static uint64_t next = 0;
  CHECK_NE(++next, 0u);
  return next;
}
class NativeContentBlockerFactory final : public ProfileKeyedServiceFactory {
 public:
  static NativeContentBlockerFactory* GetInstance() {
    static base::NoDestructor<NativeContentBlockerFactory> instance;
    return instance.get();
  }
  Blocker* Get(Profile* profile, bool create) {
    return static_cast<Blocker*>(GetServiceForBrowserContext(profile, create));
  }
 private:
  friend class base::NoDestructor<NativeContentBlockerFactory>;
  NativeContentBlockerFactory()
      : ProfileKeyedServiceFactory(
            "NativeContentBlocker", ProfileSelections::Builder()
                .WithRegular(ProfileSelection::kOwnInstance)
                .WithGuest(ProfileSelection::kOwnInstance).Build()) {}
  std::unique_ptr<KeyedService> BuildServiceInstanceForBrowserContext(
      content::BrowserContext* context) const override {
    return std::make_unique<Blocker>(Profile::FromBrowserContext(context));
  }
};
}  // namespace

namespace {
void AddHiddenSelectors(const base::ListValue* selectors, std::string& css) {
  if (!selectors) return;
  for (const auto& value : *selectors) {
    if (value.is_string())
      css += value.GetString() + "{display:none !important;}\n";
  }
}
// adblock-rust writes each operator and action as {"type": <kebab-case name>, "arg": <value>}.
const std::string* TaggedArgument(const base::Value& value, std::string_view type) {
  if (!value.is_dict()) return nullptr;
  const auto* tag = value.GetDict().FindString("type");
  return tag && *tag == type ? value.GetDict().FindString("arg") : nullptr;
}
void AddSupportedProcedural(const base::ListValue* actions, std::string& css) {
  if (!actions) return;
  for (const auto& encoded : *actions) {
    if (!encoded.is_string()) continue;
    auto action = base::JSONReader::ReadDict(encoded.GetString(),
        base::JSON_PARSE_RFC);
    if (!action) continue;
    auto* operators = action->FindList("selector");
    if (!operators || operators->empty()) continue;
    std::string selector;
    for (const auto& op : *operators) {
      const auto* part = TaggedArgument(op, "css-selector");
      if (!part) { selector.clear(); break; }
      selector += *part;
    }
    if (selector.empty()) continue;
    // A missing action means hide; remove actions are intentionally absent.
    const auto* operation = action->Find("action");
    if (!operation || operation->is_none())
      css += selector + "{display:none !important;}\n";
    else if (const auto* style = TaggedArgument(*operation, "style"))
      css += selector + "{" + *style + "}\n";
  }
}
}

class NativeContentBlocker::Matcher {
 public:
  explicit Matcher(std::shared_ptr<std::atomic<uint64_t>> latest)
      : latest_(std::move(latest)) {}
  Result::Status Install(scoped_refptr<const base::RefCountedMemory> bytes,
                         uint64_t revision) {
    if (latest_->load() != revision) return Result::kSuperseded;
    Engine replacement(nook_adblock_engine_deserialize(bytes->data(), bytes->size()),
                       &nook_adblock_engine_free);
    if (latest_->load() != revision) return Result::kSuperseded;
    if (!replacement) return Result::kInvalidRules;
    const auto resources = ui::ResourceBundle::GetSharedInstance()
        .LoadDataResourceString(IDR_NOOK_COSMETIC_SCRIPTLETS);
    if (!nook_adblock_engine_use_resources(replacement.get(), resources.data(),
                                            resources.size()))
      return Result::kInvalidRules;
    engine_.swap(replacement);
    if (latest_->load() != revision) {
      engine_.swap(replacement);
      return Result::kSuperseded;
    }
    revision_ = revision;
    return Result::kReady;
  }
  MatchResult Check(std::string url, std::string source, std::string type,
                    std::string method) {
    return {revision_, engine_ && nook_adblock_engine_matches_request(
        engine_.get(), url.c_str(), source.c_str(), type.c_str(), method.c_str())};
  }
  chrome::mojom::NookCosmeticResourcesPtr Cosmetics(
      std::string url, std::vector<std::string> classes,
      std::vector<std::string> ids, bool generic) {
    auto out = chrome::mojom::NookCosmeticResources::New();
    out->revision = revision_;
    out->apply = true;
    std::vector<std::string> exceptions;
    if (!engine_) return out;
    std::unique_ptr<char, decltype(&nook_adblock_string_free)> raw(
        nook_adblock_cosmetic_for_url(engine_.get(), url.c_str()),
        &nook_adblock_string_free);
    auto resources = raw ? base::JSONReader::ReadDict(raw.get(),
        base::JSON_PARSE_RFC) : std::optional<base::DictValue>();
    if (resources) {
      out->generichide = resources->FindBool("generichide").value_or(false);
      if (auto* excepted = resources->FindList("exceptions")) {
        for (const auto& value : *excepted)
          if (value.is_string()) exceptions.push_back(value.GetString());
      }
    }
    if (!generic) {
      if (resources) {
        AddHiddenSelectors(resources->FindList("hide_selectors"), out->css);
        AddSupportedProcedural(resources->FindList("procedural_actions"), out->css);
        if (auto* scriptlets = resources->FindString("injected_script"))
          out->scriptlets = *scriptlets;
      }
    } else if (!out->generichide) {
      base::DictValue query;
      base::ListValue class_list, id_list, exception_list;
      for (auto& value : classes) class_list.Append(std::move(value));
      for (auto& value : ids) id_list.Append(std::move(value));
      for (const auto& value : exceptions) exception_list.Append(value);
      query.Set("classes", std::move(class_list));
      query.Set("ids", std::move(id_list));
      query.Set("exceptions", std::move(exception_list));
      auto json = base::WriteJson(query);
      std::unique_ptr<char, decltype(&nook_adblock_string_free)> generic_rules(
          json ? nook_adblock_cosmetic_class_id(engine_.get(), json->c_str())
               : nullptr, &nook_adblock_string_free);
      if (generic_rules) {
        auto selectors = base::JSONReader::ReadList(generic_rules.get(),
            base::JSON_PARSE_RFC);
        if (selectors) {
          size_t bytes = 0;
          std::set<std::string> unique;
          for (const auto& selector : *selectors) {
            if (!selector.is_string() || selector.GetString().size() > 4096 ||
                !unique.insert(selector.GetString()).second) continue;
            if (out->generic_selectors.size() == 256 ||
                bytes + selector.GetString().size() > 65536) break;
            bytes += selector.GetString().size();
            out->generic_selectors.push_back(selector.GetString());
          }
        }
      }
    }
    return out;
  }
 private:
  // Rust Engine is not Sync. No other sequence accesses this mutable instance.
  Engine engine_{nullptr, &nook_adblock_engine_free};
  const std::shared_ptr<std::atomic<uint64_t>> latest_;
  uint64_t revision_ = 0;
};

bool NativeContentBlocker::SetPolicy(Policy requested,
                                      uint64_t required_source_generation,
                                      std::vector<std::string> domains) {
  auto& policy = PolicyOwner();
  if (policy.stopped || requested < kUnresolved || requested > kEnabled ||
      (requested == kUnresolved && (policy.registered || !domains.empty())) ||
      (requested == kEnabled ? required_source_generation == 0
                             : required_source_generation != 0) ||
      (requested == kEnabled &&
       required_source_generation < policy.latest_generation))
    return false;
  if (!policy.registered &&
      content::BrowserThread::IsThreadInitialized(content::BrowserThread::UI))
    return false;  // First-request registration belongs before ChromeMain.
  if (policy.registered && policy.requested == requested &&
      policy.required_generation == required_source_generation &&
      policy.domains == domains) return true;
  policy.registered = true;
  policy.requested = requested;
  policy.required_generation = required_source_generation;
  if (requested == kEnabled)
    policy.latest_generation = std::max(policy.latest_generation,
                                        required_source_generation);
  policy.domains = std::move(domains);
  policy.changed.Notify();
  return true;
}
extern "C" int barc_page_tweaks_publish(const uint8_t* json, size_t length) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      !PolicyOwner().registered || PolicyOwner().stopped) return 0;
  auto parsed = ParsePageTweaks(json, length);
  const bool revoked = !json && !length;
  PageTweaksSettings wanted = parsed ? std::move(*parsed) : PageTweaksSettings{};
  auto& policy = PolicyOwner();
  if (policy.page_tweaks != wanted) {
    policy.page_tweaks = std::move(wanted);
    policy.page_tweaks_changed.Notify();
  }
  return parsed.has_value() || revoked;
}
namespace {
class RedditHotThrottle final : public blink::URLLoaderThrottle {
 public:
  void WillStartRequest(network::ResourceRequest* request, bool*) override {
    const auto& policy = PolicyOwner();
    const auto& url = request->url;
    if (!policy.registered || policy.stopped || !policy.page_tweaks.reddit_hot ||
        !url.SchemeIsHTTPOrHTTPS() || request->request_body ||
        (request->method != "GET" && request->method != "HEAD") ||
        (url.host() != "reddit.com" && url.host() != "www.reddit.com")) return;
    const auto parts = base::SplitStringPiece(url.path(), "/",
        base::KEEP_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
    if (!(parts.empty() || (parts.size() == 2 && parts[0] == "r") ||
          (parts.size() == 4 && parts[0] == "user" && parts[2] == "m"))) return;
    std::string path = "/";
    for (const auto part : parts) { path.append(part); path += "/"; }
    path += "hot/";
    GURL::Replacements change;
    change.SetPathStr(path);
    // ThrottlingURLLoader supplies one internal 307, preserving history,
    // referrer/security processing and query/fragment; no extra page load.
    request->url = url.ReplaceComponents(change);
  }
};
}
std::unique_ptr<blink::URLLoaderThrottle> NativeContentBlocker::CreatePageTweaksThrottle() {
  const auto& policy = PolicyOwner();
  if (!policy.registered || policy.stopped || !policy.page_tweaks.reddit_hot) return nullptr;
  return std::make_unique<RedditHotThrottle>();
}

bool NativeContentBlocker::IsRegistered() { return PolicyOwner().registered; }
bool NativeContentBlocker::RequiresInterception() {
  const auto& policy = PolicyOwner();
  return policy.registered && (policy.stopped || policy.requested != kDisabled);
}
void NativeContentBlocker::PublishRules(
    scoped_refptr<const base::RefCountedMemory> bytes,
    uint64_t source_generation, Completion callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& policy = PolicyOwner();
  CHECK(policy.registered && !policy.stopped && source_generation && callback);
  const uint64_t revision = ++policy.next_revision;
  CHECK_NE(revision, 0u);
  const bool producer_failed = !bytes;
  auto publication = std::make_shared<Publication>(revision, source_generation,
      std::move(bytes), std::move(callback), policy.latest);
  policy.publications.push_back(publication);
  const bool stale = source_generation < policy.latest_generation ||
      (policy.requested == kEnabled &&
       source_generation != policy.required_generation);
  if (stale || producer_failed) {
    // Failure markers and stale work contain no input that a worker needs.
    // A stale source must not supersede the desired publication's serial.
    {
      base::AutoLock lock(publication->copy_lock);
      publication->borrowed.reset();
    }
    if (!stale) {
      policy.latest->store(revision);
      policy.latest_generation = source_generation;
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(
        FROM_HERE, base::BindOnce(&PublicationFinished, publication,
            Validation{nullptr, stale ? Result::kSuperseded : Result::kInvalidRules}));
    return;
  }
  policy.latest->store(revision);
  policy.latest_generation = source_generation;
  if (!policy.publisher) {
    policy.publisher = base::ThreadPool::CreateSequencedTaskRunner(
        {base::TaskPriority::USER_VISIBLE,
         base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN});
  }
  policy.publisher->PostTaskAndReplyWithResult(FROM_HERE,
      base::BindOnce(&CopyAndValidate, publication),
      base::BindOnce(&PublicationFinished, publication));
}
void NativeContentBlocker::StopPolicy() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& policy = PolicyOwner();
  if (!policy.registered || policy.stopped) return;
  policy.stopped = true;
  policy.latest->fetch_add(1);
  auto publications = std::move(policy.publications);
  policy.rules.reset();
  policy.page_tweaks = {};
  policy.page_tweaks_changed.Notify();
  // Queued tasks need not run: cancellation drops their input here. A running
  // copy holds this lock only through memcpy and borrowed-wrapper destruction.
  // Validation never holds it and never observes Swift memory or callbacks.
  for (const auto& publication : publications) {
    base::AutoLock lock(publication->copy_lock);
    publication->cancelled = true;
    publication->borrowed.reset();
  }
  policy.changed.Notify();
  for (const auto& publication : publications) {
    if (publication->completed) continue;
    publication->completed = true;
    auto reply = std::move(publication->reply);
    std::move(reply).Run({publication->revision, Result::kOwnerEnded});
  }
}
void NativeContentBlocker::EnsureFactoryBuilt() {
  NativeContentBlockerFactory::GetInstance();
}
NativeContentBlocker* NativeContentBlocker::Get(Profile* profile, bool create) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return NativeContentBlockerFactory::GetInstance()->Get(profile, create);
}
NativeContentBlocker::NativeContentBlocker(Profile* profile)
    : profile_(profile), context_id_(NextNativeContextID()),
      latest_install_(std::make_shared<std::atomic<uint64_t>>(0)) {
  last_should_proxy_ = ShouldProxy();
  page_tweaks_subscription_ = PolicyOwner().page_tweaks_changed.Add(base::BindRepeating(
      [](base::WeakPtr<NativeContentBlocker> self) {
        if (self) self->cosmetic_policy_changed_.Notify(self->policy_revision_);
      }, weak_factory_.GetWeakPtr()));
  policy_subscription_ = PolicyOwner().changed.Add(base::BindRepeating(
      &NativeContentBlocker::OnPolicyChanged, weak_factory_.GetWeakPtr()));
}
NativeContentBlocker::~NativeContentBlocker() = default;
bool NativeContentBlocker::ShouldProxy() const {
  return RequiresInterception();
}
NativeContentBlocker::State NativeContentBlocker::state() const {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const auto& policy = PolicyOwner();
  const bool ready = !shutdown_ && !policy.stopped && policy.registered &&
      (policy.requested == kDisabled ||
       (policy.requested == kEnabled && policy.revision &&
        policy.generation == policy.required_generation &&
        installed_revision_ == policy.revision));
  return {context_id_, policy.revision, installed_revision_, policy.generation,
          policy.required_generation, pending_revision_, ready, policy.requested};
}
void NativeContentBlocker::Prepare(Completion callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (shutdown_ || PolicyOwner().stopped) {
    std::move(callback).Run({0, Result::kOwnerEnded});
    return;
  }
  preparations_.push_back(std::move(callback));
  SettleWaiting();
}
void NativeContentBlocker::OnPolicyChanged() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (PolicyOwner().stopped) { Shutdown(); return; }
  ++policy_revision_;
  auto alive = weak_factory_.GetWeakPtr();
  cosmetic_policy_changed_.Notify(policy_revision_);
  if (!alive) return;
  const bool proxy = ShouldProxy();
  const bool reset = !last_should_proxy_ && proxy;
  last_should_proxy_ = proxy;
  if (reset) ResetFactories();
  if (alive) SettleWaiting();
}
void NativeContentBlocker::ResetFactories() {
  profile_->ForEachLoadedStoragePartition([](content::StoragePartition* partition) {
    partition->ResetURLLoaderFactories();
  });
}
void NativeContentBlocker::EnsureRules() {
  const auto& policy = PolicyOwner();
  if (shutdown_ || policy.stopped || policy.requested != kEnabled ||
      !policy.rules || policy.generation != policy.required_generation ||
      installed_revision_ == policy.revision ||
      pending_revision_ == policy.revision || failed_revision_ == policy.revision)
    return;
  if (!matcher_) {
    matcher_ = std::make_unique<base::SequenceBound<Matcher>>(
        base::ThreadPool::CreateSequencedTaskRunner(
            {base::TaskPriority::USER_VISIBLE,
             base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN}), latest_install_);
  }
  pending_revision_ = policy.revision;
  latest_install_->store(policy.revision);
  matcher_->AsyncCall(&Matcher::Install).WithArgs(policy.rules, policy.revision)
      .Then(base::BindOnce(&NativeContentBlocker::Installed,
                           weak_factory_.GetWeakPtr(), policy.revision));
}
void NativeContentBlocker::Installed(uint64_t revision, Result::Status status) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (pending_revision_ == revision) pending_revision_ = 0;
  if (revision == PolicyOwner().revision) {
    if (status == Result::kReady) installed_revision_ = revision;
    else if (status == Result::kInvalidRules) failed_revision_ = revision;
  }
  SettleWaiting();
}
void NativeContentBlocker::SettleWaiting() {
  if (shutdown_) return;
  EnsureRules();
  const auto current = state();
  const bool failed = current.requested_policy == kEnabled &&
      (PolicyOwner().failed_generation == current.required_source_generation ||
       (current.source_generation == current.required_source_generation &&
        current.publication_revision &&
        failed_revision_ == current.publication_revision));
  if (!current.ready && !failed) return;
  auto preparations = std::move(preparations_);
  auto waiting = std::move(waiting_);
  auto alive = weak_factory_.GetWeakPtr();
  for (auto& callback : preparations) {
    if (!alive) {
      std::move(callback).Run({0, Result::kOwnerEnded});
    } else {
      const auto latest = alive->state();
      const bool latest_failed = latest.requested_policy == kEnabled &&
          (PolicyOwner().failed_generation == latest.required_source_generation ||
           (latest.source_generation == latest.required_source_generation &&
            latest.publication_revision &&
            alive->failed_revision_ == latest.publication_revision));
      if (!latest.ready && !latest_failed) {
        alive->preparations_.push_back(std::move(callback));
      } else {
        std::move(callback).Run({latest.publication_revision,
            latest.ready ? Result::kReady : Result::kInvalidRules});
      }
    }
  }
  for (auto& request : waiting) {
    if (!alive) std::move(request.callback).Run(net::ERR_ABORTED);
    else alive->CheckCaptured(std::move(request));
  }
}
bool NativeContentBlocker::SetTabPolicy(tabs::TabInterface& tab, bool oauth,
                                       std::string continued_host,
                                       base::TimeDelta duration) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* owner = tab.GetBrowserWindowInterface();
  if (shutdown_ || !owner || owner->IsDeleteScheduled() || owner->GetProfile() != profile_)
    return false;
  ++policy_revision_;
  const int32_t handle = tab.GetHandle().raw_value();
  const auto previous = tab_policies_.find(handle);
  const bool material = previous == tab_policies_.end()
      ? oauth || !continued_host.empty() || duration.is_positive()
      : previous->second.oauth != oauth ||
        previous->second.continued_host != continued_host ||
        (duration.is_positive()
            ? previous->second.disabled_until <= base::TimeTicks::Now()
            : !previous->second.disabled_until.is_null());
  if (oauth || !continued_host.empty() || duration.is_positive()) {
    tab_policies_[handle] = {oauth, std::move(continued_host),
        duration.is_positive() ? base::TimeTicks::Now() + duration : base::TimeTicks()};
  } else {
    tab_policies_.erase(handle);
  }
  for (auto it = tab_policies_.begin(); it != tab_policies_.end();) {
    if (!tabs::TabHandle(it->first).Get()) it = tab_policies_.erase(it);
    else ++it;
  }
  if (material) cosmetic_policy_changed_.Notify(policy_revision_);
  return true;
}
NativeContentBlocker::Client NativeContentBlocker::CaptureClient(
    content::WebContents* contents, content::RenderFrameHost* frame,
    const GURL& captured_site) {
  Client client;
  client.site = captured_site;
  if (contents && frame && frame->IsActive() &&
      content::WebContents::FromRenderFrameHost(frame) == contents) {
    client.contents = contents->GetWeakPtr();
    client.document = frame->GetWeakDocumentPtr();
    if (auto* tab = tabs::TabInterface::MaybeGetFromContents(contents))
      client.tab = tab->GetHandle().raw_value();
  }
  return client;
}
bool NativeContentBlocker::IsExempt(const Request& request) {
  GURL site = request.client.site;
  bool changed = false;
  bool exempt = false;
  auto* frame = request.client.document.AsRenderFrameHostIfValid();
  auto* tab = tabs::TabHandle(request.client.tab).Get();
  if (request.client.contents && frame && frame->IsActive() && tab &&
      frame->GetBrowserContext() == profile_ &&
      content::WebContents::FromRenderFrameHost(frame) == request.client.contents.get() &&
      tab->GetContents() == request.client.contents.get()) {
    auto it = tab_policies_.find(request.client.tab);
    if (it != tab_policies_.end()) {
      auto& policy = it->second;
      if (request.type == "main_frame" && !policy.continued_host.empty() &&
          policy.continued_host != request.url.host()) {
        policy.continued_host.clear();
        ++policy_revision_;
        changed = true;
      }
      exempt = policy.oauth || policy.disabled_until > base::TimeTicks::Now() ||
          (!policy.continued_host.empty() && policy.continued_host ==
              (request.type == "main_frame" ? request.url : site).host());
    }
  }
  if (request.type == "main_frame") site = request.url;
  for (const auto& domain : PolicyOwner().domains)
    exempt |= site.DomainIs(domain);
  // Cache eviction can retire frame observers. Finish reading policy before
  // publishing and let the caller revalidate this service's weak lifetime.
  if (changed) cosmetic_policy_changed_.Notify(policy_revision_);
  return exempt;
}
void NativeContentBlocker::Check(
    const GURL& url, const GURL& initiator, Client client,
    std::string type, std::string method,
    base::OnceCallback<void(int)> callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  CheckCaptured({url, initiator, std::move(client), std::move(type),
                 std::move(method), std::move(callback)});
}
void NativeContentBlocker::CheckCaptured(Request request) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const auto& policy = PolicyOwner();
  if (shutdown_ || policy.stopped) {
    std::move(request.callback).Run(net::ERR_ABORTED); return;
  }
  if (!policy.registered || policy.requested == kDisabled ||
      !(request.url.SchemeIsHTTPOrHTTPS() ||
        (request.type == "websocket" && request.url.SchemeIsWSOrWSS()))) {
    std::move(request.callback).Run(net::OK); return;
  }
  if (!state().ready) {
    if (policy.requested == kEnabled &&
        (policy.failed_generation == policy.required_generation ||
         (policy.generation == policy.required_generation &&
          policy.revision && failed_revision_ == policy.revision))) {
      std::move(request.callback).Run(net::ERR_FAILED); return;
    }
    waiting_.push_back(std::move(request));
    EnsureRules();
    return;
  }
  const auto alive = weak_factory_.GetWeakPtr();
  const bool exempt = IsExempt(request);
  if (!alive) { std::move(request.callback).Run(net::ERR_ABORTED); return; }
  if (exempt) {
    std::move(request.callback).Run(net::OK); return;
  }
  const uint64_t revision = policy_revision_;
  auto url = request.url.spec();
  auto source = request.initiator.spec();
  auto type = request.type;
  auto method = request.method;
  matcher_->AsyncCall(&Matcher::Check)
      .WithArgs(std::move(url), std::move(source), std::move(type), std::move(method))
      .Then(base::BindOnce(
          [](base::WeakPtr<NativeContentBlocker> owner, uint64_t revision,
             Request request, MatchResult result) {
            if (!owner) {
              std::move(request.callback).Run(net::ERR_ABORTED); return;
            }
            if (revision != owner->policy_revision_ || !owner->state().ready ||
                result.revision != PolicyOwner().revision) {
              owner->CheckCaptured(std::move(request)); return;
            }
            std::move(request.callback).Run(result.blocked ? net::ERR_BLOCKED_BY_CLIENT
                                                          : net::OK);
          }, weak_factory_.GetWeakPtr(), revision, std::move(request)));
}
class NativeContentBlocker::CosmeticResourcesHost final
    : public content::DocumentService<chrome::mojom::NookCosmeticResourcesHost>,
      public content::WebContentsObserver {
 public:
  CosmeticResourcesHost(content::RenderFrameHost& frame,
                        NativeContentBlocker& service,
                        mojo::PendingReceiver<chrome::mojom::NookCosmeticResourcesHost> receiver)
      : content::DocumentService<chrome::mojom::NookCosmeticResourcesHost>(
            frame, std::move(receiver)),
        frame_(frame.GetGlobalId()), service_(service.weak_factory_.GetWeakPtr()) {
    subscription_ = service.ObserveCosmeticPolicy(base::BindRepeating(
        &CosmeticResourcesHost::Invalidate, base::Unretained(this)));
  }
  void GetResources(const blink::DocumentToken& document,
                     GetResourcesCallback callback) override {
    auto* frame = content::RenderFrameHost::FromID(frame_);
    if (initial_requested_ || !frame ||
        !frame->GetCurrentOrPendingCommitDocumentURL(document)) {
      std::move(callback).Run(nullptr); return;
    }
    initial_requested_ = true;
    Get(document, {}, {}, false, std::move(callback));
  }
  void SaveSocialMedia(const blink::DocumentToken& document, const std::string& candidate,
                       int32_t policy, SaveSocialMediaCallback callback) override {
    auto* frame = content::RenderFrameHost::FromID(frame_);
    const GURL url(candidate);
    if (!service_ || service_->shutdown_ || PolicyOwner().stopped ||
        !frame || !frame->IsActive() || frame->GetParentOrOuterDocument() ||
        frame->GetDocumentToken() != document || document_ != document ||
        candidate.size() > 8192 || !url.is_valid() || !url.SchemeIs("https") ||
        url.has_username() || url.has_password() || policy < 0 || policy > static_cast<int32_t>(net::ReferrerPolicy::MAX)) {
      std::move(callback).Run(false); return;
    }
    const GURL source = frame->GetLastCommittedURL();
    const bool enabled = source.SchemeIsHTTPOrHTTPS() && std::ranges::any_of(PolicyOwner().page_tweaks.media_domains,
        [&](const auto& domain) { return source.DomainIs(domain); });
    if (!enabled || !frame->ConsumeTransientUserActivation()) {
      std::move(callback).Run(false); return;
    }
    const bool credentials = (url.DomainIs(source.host()) || source.DomainIs(url.host())) &&
        net::registry_controlled_domains::SameDomainOrHost(source, url,
            net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
    constexpr auto annotation = net::DefineNetworkTrafficAnnotation("nook_social_media_download", R"(
      semantics { sender: "Nook media download" description: "Saves image/video selected by a trusted click on an opted-in site's media control."
        trigger: "User clicks the isolated media download control." data: "Media URL and referrer; original profile cookies only for its own site."
        destination: WEBSITE }
      policy { cookies_allowed: YES cookies_store: "user" setting: "Configured media download sites, empty by default."
        policy_exception_justification: "Explicit user media save." })");
    auto params = frame->CreateDownloadUrlParameters(url, annotation);
    params->set_content_initiated(false);
    params->set_has_user_gesture(true);
    params->set_require_safety_checks(true);
    params->set_download_source(download::DownloadSource::NATIVE_SOCIAL_MEDIA);
    const auto referrer_policy = static_cast<net::ReferrerPolicy>(policy);
    params->set_referrer(net::URLRequestJob::ComputeReferrerForPolicy(referrer_policy, source, url));
    params->set_referrer_policy(referrer_policy);
    params->set_credentials_mode(credentials ? network::mojom::CredentialsMode::kInclude
                                            : network::mojom::CredentialsMode::kOmit);
    params->set_cross_origin_redirects(credentials ? network::mojom::RedirectMode::kError
                                                  : network::mojom::RedirectMode::kFollow);
    // The actual frame supplies the partition/initiator. Existing DownloadManager
    // owns targets, security checks, progress, cancellation and final publication.
    frame->GetBrowserContext()->GetDownloadManager()->DownloadUrl(std::move(params));
    std::move(callback).Run(true);
  }
  void GetSponsorSegments(const blink::DocumentToken& document, const std::string& video,
                          GetSponsorSegmentsCallback callback) override {
    if (!SponsorCurrent(document, video)) { std::move(callback).Run(nullptr); return; }
    if (sponsor_cache_ && sponsor_cache_->video == video &&
        base::TimeTicks::Now() - sponsor_cached_at_ < base::Hours(1)) {
      std::move(callback).Run(sponsor_cache_.Clone()); return;
    }
    if (sponsor_loader_ && sponsor_video_ == video && sponsor_callback_) { std::move(callback).Run(nullptr); return; }
    CancelSponsor();
    sponsor_video_ = video;
    Observe(content::WebContents::FromRenderFrameHost(&render_frame_host()));
    sponsor_callback_ = mojo::WrapCallbackWithDefaultInvokeIfNotRun(std::move(callback), nullptr);
    const auto digest = crypto::hash::Sha256(video);
    const std::string hash = base::HexEncodeLower(digest);
    base::ListValue categories;
    for (const auto& [category, option] : PolicyOwner().page_tweaks.sponsor_block) categories.Append(category);
    const std::string query = base::WriteJson(categories).value_or("[]");
    const GURL url("https://sponsor.ajay.app/api/skipSegments/" + hash.substr(0, 4));
    sponsor_loader_ = SponsorLoader(net::AppendQueryParameter(url, "categories", query));
    sponsor_loader_->DownloadToString(
        render_frame_host().GetStoragePartition()->GetURLLoaderFactoryForBrowserProcess().get(),
        base::BindOnce(&CosmeticResourcesHost::SponsorComplete,
            weak_factory_.GetWeakPtr(), document, video, hash), 1024 * 1024);
  }
  void ReportSponsorSegment(const blink::DocumentToken& document, const std::string& video,
                            const std::string& uuid) override {
    if (!SponsorCurrent(document, video) || service_->profile_->IsOffTheRecord() || !render_frame_host().IsActive() ||
        sponsor_loader_ || !sponsor_cache_ || sponsor_cache_->video != video ||
        !sponsor_uuids_.contains(uuid) || sponsor_reported_.size() >= 256 ||
        sponsor_reported_.contains(video + "\n" + uuid)) return;
    sponsor_reported_.insert(video + "\n" + uuid);
    sponsor_loader_ = SponsorLoader(net::AppendQueryParameter(
        GURL("https://sponsor.ajay.app/api/viewedVideoSponsorTime"), "UUID", uuid), "POST");
    sponsor_loader_->DownloadHeadersOnly(
        render_frame_host().GetStoragePartition()->GetURLLoaderFactoryForBrowserProcess().get(),
        base::BindOnce([](base::WeakPtr<CosmeticResourcesHost> self,
                         scoped_refptr<net::HttpResponseHeaders>) {
          if (self) self->sponsor_loader_.reset();
        }, weak_factory_.GetWeakPtr()));
  }
  void GetGenericSelectors(const blink::DocumentToken& document,
      const std::vector<std::string>& classes,
      const std::vector<std::string>& ids,
      GetGenericSelectorsCallback callback) override {
    if (generic_in_flight_ || classes.size() > 128 || ids.size() > 128 ||
        (classes.empty() && ids.empty()) || classes.size() + ids.size() > 128) {
      std::move(callback).Run(nullptr); return;
    }
    size_t bytes = 0;
    for (const auto& name : classes) {
      if (name.size() > 512) { std::move(callback).Run(nullptr); return; }
      bytes += name.size();
      if (bytes > 16384) { std::move(callback).Run(nullptr); return; }
    }
    for (const auto& name : ids) {
      if (name.size() > 512) { std::move(callback).Run(nullptr); return; }
      bytes += name.size();
      if (bytes > 16384) { std::move(callback).Run(nullptr); return; }
    }
    auto* frame = content::RenderFrameHost::FromID(frame_);
    if (!frame || !service_ ||
        !frame->GetCurrentOrPendingCommitDocumentURL(document)) {
      std::move(callback).Run(nullptr); return;
    }
    if (!generic_budget_document_ || *generic_budget_document_ != document) {
      generic_budget_document_ = document;
      generic_tokens_ = generic_bytes_ = 0;
    }
    const size_t count = classes.size() + ids.size();
    if (bytes > 16384 ||
        generic_tokens_ + count > 4096 || generic_bytes_ + bytes > 131072) {
      std::move(callback).Run(nullptr); return;
    }
    generic_tokens_ += count;
    generic_bytes_ += bytes;
    generic_in_flight_ = true;
    Get(document, classes, ids, true, base::BindOnce(
        [](base::WeakPtr<CosmeticResourcesHost> self,
           GetGenericSelectorsCallback callback,
           chrome::mojom::NookCosmeticResourcesPtr result) {
          if (self) self->generic_in_flight_ = false;
          std::move(callback).Run(std::move(result));
        }, weak_factory_.GetWeakPtr(), std::move(callback)));
  }
 private:
  bool SponsorCurrent(const blink::DocumentToken& document, const std::string& video) const {
    auto* frame = content::RenderFrameHost::FromID(frame_);
    const auto url = frame ? frame->GetCurrentOrPendingCommitDocumentURL(document) : std::nullopt;
    return service_ && !service_->shutdown_ && !PolicyOwner().stopped &&
        frame && !frame->GetParentOrOuterDocument() && document_ == document &&
        !PolicyOwner().page_tweaks.sponsor_block.empty() && url && SponsorVideo(*url) == video;
  }
  static std::unique_ptr<network::SimpleURLLoader> SponsorLoader(const GURL& url,
                                                               std::string method = "GET") {
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = url; request->method = std::move(method);
    request->credentials_mode = network::mojom::CredentialsMode::kOmit;
    request->redirect_mode = network::mojom::RedirectMode::kError;
    constexpr auto annotation = net::DefineNetworkTrafficAnnotation("nook_sponsorblock", R"(
      semantics { sender: "Nook SponsorBlock" description: "Optional community video segment lookup and non-private skip report."
        trigger: "An enabled YouTube page changes video or skips a returned segment."
        data: "Four-character SHA256 prefix and categories; eligible segment UUID for reports. No cookies."
        destination: OTHER destination_other: "sponsor.ajay.app" }
      policy { cookies_allowed: NO setting: "SponsorBlock preference, off by default." policy_exception_justification: "Optional user customization." })");
    auto loader = network::SimpleURLLoader::Create(std::move(request), annotation);
    loader->SetTimeoutDuration(base::Seconds(15));
    return loader;
  }
  void CancelSponsor() {
    sponsor_loader_.reset(); sponsor_cache_.reset(); sponsor_uuids_.clear();
    sponsor_video_.clear();
    if (sponsor_callback_) std::move(sponsor_callback_).Run(nullptr);
  }
  void SponsorComplete(blink::DocumentToken document, std::string video, std::string hash,
                       std::optional<std::string> body) {
    sponsor_loader_.reset();
    auto callback = std::move(sponsor_callback_);
    if (!callback) return;
    if (!SponsorCurrent(document, video) || sponsor_video_ != video) {
      std::move(callback).Run(nullptr); return;
    }
    if (!body) { std::move(callback).Run(nullptr); return; }
    auto reply = chrome::mojom::NookSponsorReply::New();
    reply->video = video; reply->options = PolicyOwner().page_tweaks.sponsor_block;
    auto parsed = body ? base::JSONReader::Read(*body, base::JSON_PARSE_RFC) : std::nullopt;
    if (parsed && parsed->is_list() && parsed->GetList().size() <= 512) {
      for (const auto& entry : parsed->GetList()) {
        const auto* value = entry.GetIfDict();
        if (!value) continue;
        const auto* id = value->FindString("videoID"); const auto* full = value->FindString("hash");
        if ((!id || *id != video) && (!full || *full != hash)) continue;
        const auto* segments = value->FindList("segments");
        if (!segments || segments->size() > 256) break;
        for (const auto& segment : *segments) {
          const auto* item = segment.GetIfDict(); if (!item) continue;
          const auto* uuid = item->FindString("UUID"); const auto* range = item->FindList("segment");
          const auto* category = item->FindString("category"); const auto* action = item->FindString("actionType");
          if (!uuid || uuid->size() != 64 || !std::ranges::all_of(*uuid, [](char c) { return base::IsHexDigit(c); }) ||
              !range || range->size() != 2 || (!(*range)[0].is_double() && !(*range)[0].is_int()) ||
              (!(*range)[1].is_double() && !(*range)[1].is_int()) || !category || !reply->options.contains(*category) ||
              !action || (*action != "skip" && *action != "mute")) continue;
          const double start = (*range)[0].GetDouble(), end = (*range)[1].GetDouble();
          if (!(std::isfinite(start) && std::isfinite(end) && start >= 0 && start < end && end < 86400)) continue;
          reply->segments.push_back(chrome::mojom::NookSponsorSegment::New(*uuid, start, end, *category, *action));
          sponsor_uuids_.insert(*uuid);
        }
        break;
      }
    }
    std::ranges::sort(reply->segments, {}, [](const auto& segment) { return segment->start; });
    sponsor_cached_at_ = base::TimeTicks::Now(); sponsor_cache_ = reply.Clone();
    std::move(callback).Run(std::move(reply));
  }
  using Reply = base::OnceCallback<void(chrome::mojom::NookCosmeticResourcesPtr)>;
  void Get(const blink::DocumentToken& document,
      std::vector<std::string> classes, std::vector<std::string> ids,
      bool generic, Reply callback) {
    auto* frame = content::RenderFrameHost::FromID(frame_);
    const auto url = frame ? frame->GetCurrentOrPendingCommitDocumentURL(document)
                           : std::nullopt;
    if (!url || !NativeContentBlocker::IsRegistered()) {
      std::move(callback).Run(nullptr); return;
    }
    callback = mojo::WrapCallbackWithDefaultInvokeIfNotRun(
        std::move(callback), nullptr);
    if (!service_) { std::move(callback).Run(nullptr); return; }
    auto alive = weak_factory_.GetWeakPtr();
    service_->GetCosmeticResources(frame_, document, *url, std::move(classes),
        std::move(ids), generic, base::BindOnce(
            [](base::WeakPtr<CosmeticResourcesHost> self,
               blink::DocumentToken document, bool generic, Reply callback,
               chrome::mojom::NookCosmeticResourcesPtr result) {
              if (self && self->service_ && result) {
                auto* frame = content::RenderFrameHost::FromID(self->frame_);
                const auto url = frame
                    ? frame->GetCurrentOrPendingCommitDocumentURL(document) : std::nullopt;
                if (url) {
                  if (!self->document_ || *self->document_ != document)
                    self->invalidated_ = false;
                  self->document_ = document;
                  self->served_policy_ = self->service_->CosmeticPolicyForDocument(*frame, *url);
                  if (!generic) {
                    result->page_tweaks = PageTweaksForDocument(*frame, *url);
                    self->served_tweaks_ = result->page_tweaks.Clone();
                  }
                }
              }
              std::move(callback).Run(std::move(result));
            }, alive, document, generic, std::move(callback)));
  }
  void Invalidate(uint64_t generation) {
    auto* frame = content::RenderFrameHost::FromID(frame_);
    const auto url = frame && document_
        ? frame->GetCurrentOrPendingCommitDocumentURL(*document_) : std::nullopt;
    if (!url || !served_policy_ || !service_) return;
    const bool cosmetics_changed =
        service_->CosmeticPolicyForDocument(*frame, *url) != *served_policy_;
    const auto current_tweaks = service_->shutdown_ ? nullptr : PageTweaksForDocument(*frame, *url);
    const bool tweaks_changed = current_tweaks != served_tweaks_;
    if (tweaks_changed) CancelSponsor();
    if (!cosmetics_changed && !tweaks_changed) return;
    // Disable only this exact stale document. This both evicts cached copies
    // and prevents a live, reload-vetoing document being cached afterward.
    // Equivalent tab-policy refreshes and unchanged sources leave it eligible.
    const auto lifecycle = frame->GetLifecycleState();
    if (lifecycle == content::RenderFrameHost::LifecycleState::kPrerendering) {
      // This public primitive cancels a prepared obsolete page. It must not be
      // called during pending commit; the short-lived lifecycle observation
      // below rechecks that case once activation can safely be disallowed.
      constexpr uint64_t reason = content::kMinEmbedderDisallowActivationReason +
          static_cast<uint64_t>(
              back_forward_cache::DisabledReasonId::kNativeCosmeticPolicyChanged);
      frame->IsInactiveAndDisallowActivation(reason);
      return;
    }
    if (lifecycle == content::RenderFrameHost::LifecycleState::kPendingCommit)
      Observe(content::WebContents::FromRenderFrameHost(frame));
    const bool disable_cache = !invalidated_;
    invalidated_ = true;
    if (lifecycle != content::RenderFrameHost::LifecycleState::kInBackForwardCache) {
      mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> remote;
      frame->GetRemoteAssociatedInterfaces()->GetInterface(&remote);
      if (cosmetics_changed) remote->ClearNookCosmetics(*document_, generation);
      if (tweaks_changed) remote->ClearNookPageTweaks(*document_);
    }
    // Eviction may destroy this receiver; do not touch members afterward.
    if (disable_cache) content::BackForwardCache::DisableForRenderFrameHost(frame,
        back_forward_cache::DisabledReason(
            back_forward_cache::DisabledReasonId::kNativeCosmeticPolicyChanged));
  }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (!navigation->HasCommitted() || !navigation->IsSameDocument() ||
        !navigation->GetRenderFrameHost() || navigation->GetRenderFrameHost()->GetGlobalId() != frame_ ||
        sponsor_video_.empty() || !document_) return;
    if (!SponsorCurrent(*document_, sponsor_video_)) CancelSponsor();
  }
  void RenderFrameHostStateChanged(content::RenderFrameHost* frame,
      content::RenderFrameHost::LifecycleState,
      content::RenderFrameHost::LifecycleState next) override {
    if (frame->GetGlobalId() != frame_ ||
        next == content::RenderFrameHost::LifecycleState::kPendingCommit) return;
    if (sponsor_video_.empty()) Observe(nullptr);
    if (service_) Invalidate(service_->policy_revision_);
  }
  const content::GlobalRenderFrameHostId frame_;
  std::optional<blink::DocumentToken> document_;
  std::optional<CosmeticPolicy> served_policy_;
  chrome::mojom::NookPageTweaksPtr served_tweaks_;
  bool initial_requested_ = false;
  bool invalidated_ = false;
  bool generic_in_flight_ = false;
  std::optional<blink::DocumentToken> generic_budget_document_;
  size_t generic_tokens_ = 0;
  size_t generic_bytes_ = 0;
  base::WeakPtr<NativeContentBlocker> service_;
  base::CallbackListSubscription subscription_;
  std::unique_ptr<network::SimpleURLLoader> sponsor_loader_;
  GetSponsorSegmentsCallback sponsor_callback_;
  std::string sponsor_video_;
  chrome::mojom::NookSponsorReplyPtr sponsor_cache_;
  base::TimeTicks sponsor_cached_at_;
  std::set<std::string> sponsor_uuids_, sponsor_reported_;
  base::WeakPtrFactory<CosmeticResourcesHost> weak_factory_{this};
};
void NativeContentBlocker::BindCosmeticResources(
    content::RenderFrameHost* frame,
    mojo::PendingReceiver<chrome::mojom::NookCosmeticResourcesHost> receiver) {
  if (!frame || !IsRegistered() || PolicyOwner().stopped) return;
  const auto frame_id = frame->GetGlobalId();
  auto* service = Get(Profile::FromBrowserContext(frame->GetBrowserContext()), true);
  if (!service) return;
  auto alive = service->weak_factory_.GetWeakPtr();
  frame = content::RenderFrameHost::FromID(frame_id);
  if (!alive || !frame || frame->GetBrowserContext() != alive->profile_) return;
  // The pending incoming DocumentAssociatedData already exists before commit
  // IPC; DocumentService binds to it and closes the pipe on cancellation/death.
  new CosmeticResourcesHost(*frame, *alive, std::move(receiver));
}
base::CallbackListSubscription NativeContentBlocker::ObserveCosmeticPolicy(
    base::RepeatingCallback<void(uint64_t)> callback) {
  return cosmetic_policy_changed_.Add(std::move(callback));
}
NativeContentBlocker::CosmeticPolicy NativeContentBlocker::CosmeticPolicyForDocument(
    content::RenderFrameHost& frame, const GURL& url) const {
  auto* contents = content::WebContents::FromRenderFrameHost(&frame);
  auto* tab = contents ? tabs::TabInterface::MaybeGetFromContents(contents) : nullptr;
  const GURL site = frame.GetParent()
      ? frame.GetOutermostMainFrame()->GetLastCommittedURL() : url;
  bool exempt = false;
  if (tab) {
    auto it = tab_policies_.find(tab->GetHandle().raw_value());
    if (it != tab_policies_.end()) {
      const auto& policy = it->second;
      exempt = policy.oauth || policy.disabled_until > base::TimeTicks::Now() ||
          (!policy.continued_host.empty() && policy.continued_host == site.host());
    }
  }
  for (const auto& domain : PolicyOwner().domains)
    exempt |= site.DomainIs(domain);
  const Policy requested = shutdown_ || PolicyOwner().stopped
      ? kDisabled : PolicyOwner().requested;
  const Policy effective = requested == kEnabled && exempt ? kDisabled : requested;
  // Exempt documents have no injected protection to become stale when an
  // unrelated source changes; preserve their eligible live history as well.
  return {effective == kEnabled ? PolicyOwner().required_generation : 0,
      effective == kEnabled ? PolicyOwner().cosmetic_source_identity : 0, effective};
}
void NativeContentBlocker::GetCosmeticResources(
    content::GlobalRenderFrameHostId frame_id,
    const blink::DocumentToken& document, const GURL& url,
    std::vector<std::string> classes, std::vector<std::string> ids, bool generic,
    base::OnceCallback<void(chrome::mojom::NookCosmeticResourcesPtr)> callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* frame = content::RenderFrameHost::FromID(frame_id);
  if (shutdown_ || PolicyOwner().stopped || !frame ||
      frame->GetBrowserContext() != profile_ ||
      !url.SchemeIsHTTPOrHTTPS() ||
      frame->GetCurrentOrPendingCommitDocumentURL(document) != url) {
    std::move(callback).Run(nullptr); return;
  }
  const auto current = state();
  if (current.requested_policy == kDisabled) {
    auto empty = chrome::mojom::NookCosmeticResources::New();
    empty->revision = current.publication_revision;
    empty->policy_generation = policy_revision_;
    empty->generichide = true;
    std::move(callback).Run(std::move(empty)); return;
  }
  if (!current.ready) {
    // Native readiness already owns cancellation/disable/failure. Browser UI
    // never waits synchronously; only the renderer's sync Mojo call is held.
    Prepare(base::BindOnce(
        [](base::WeakPtr<NativeContentBlocker> owner,
           content::GlobalRenderFrameHostId frame,
           blink::DocumentToken document,
           std::vector<std::string> classes, std::vector<std::string> ids,
           bool generic, decltype(callback) callback, Result result) {
          auto* current_frame = content::RenderFrameHost::FromID(frame);
          const auto url = current_frame
              ? current_frame->GetCurrentOrPendingCommitDocumentURL(document)
              : std::nullopt;
          if (!owner || !url || result.status != Result::kReady) {
            std::move(callback).Run(nullptr); return;
          }
          owner->GetCosmeticResources(frame, document, *url, std::move(classes),
              std::move(ids), generic, std::move(callback));
        }, weak_factory_.GetWeakPtr(), frame_id, document,
        std::move(classes), std::move(ids), generic, std::move(callback)));
    return;
  }
  if (CosmeticPolicyForDocument(*frame, url).policy == kDisabled) {
    auto empty = chrome::mojom::NookCosmeticResources::New();
    empty->revision = current.publication_revision;
    empty->policy_generation = policy_revision_;
    empty->generichide = true;
    std::move(callback).Run(std::move(empty)); return;
  }
  const uint64_t generation = policy_revision_;
  matcher_->AsyncCall(&Matcher::Cosmetics)
      .WithArgs(url.spec(), classes, ids, generic)
      .Then(base::BindOnce(
          [](base::WeakPtr<NativeContentBlocker> owner,
             content::GlobalRenderFrameHostId frame_id,
             blink::DocumentToken document, GURL url,
             std::vector<std::string> classes, std::vector<std::string> ids,
             bool generic, uint64_t generation, decltype(callback) callback,
             chrome::mojom::NookCosmeticResourcesPtr result) {
            auto* frame = content::RenderFrameHost::FromID(frame_id);
            if (!owner || !frame || frame->GetBrowserContext() != owner->profile_) {
              std::move(callback).Run(nullptr); return;
            }
            const auto current_url = frame->GetCurrentOrPendingCommitDocumentURL(document);
            if (!current_url) { std::move(callback).Run(nullptr); return; }
            if (*current_url != url) {
              owner->GetCosmeticResources(frame_id, document, *current_url,
                  std::move(classes), std::move(ids), generic, std::move(callback));
              return;
            }
            if (generation != owner->policy_revision_ || !owner->state().ready ||
                result->revision != owner->state().publication_revision) {
              owner->GetCosmeticResources(frame_id, document, url,
                  std::move(classes), std::move(ids), generic, std::move(callback));
              return;
            }
            result->policy_generation = generation;
            result->source_identity = PolicyOwner().cosmetic_source_identity;
            std::move(callback).Run(std::move(result));
          }, weak_factory_.GetWeakPtr(), frame_id, document, url,
          std::move(classes), std::move(ids), generic, generation,
          std::move(callback)));
}

void NativeContentBlocker::Shutdown() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (shutdown_) return;
  shutdown_ = true;
  ++policy_revision_;
  auto alive = weak_factory_.GetWeakPtr();
  cosmetic_policy_changed_.Notify(policy_revision_);
  if (!alive) return;
  latest_install_->fetch_add(1);
  policy_subscription_ = {};
  page_tweaks_subscription_ = {};
  weak_factory_.InvalidateWeakPtrs();
  matcher_.reset();
  tab_policies_.clear();
  auto preparations = std::move(preparations_);
  auto waiting = std::move(waiting_);
  for (auto& callback : preparations)
    std::move(callback).Run({0, Result::kOwnerEnded});
  for (auto& request : waiting)
    std::move(request.callback).Run(net::ERR_ABORTED);
}
