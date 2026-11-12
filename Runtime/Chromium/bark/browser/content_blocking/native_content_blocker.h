// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#ifndef CHROME_BROWSER_CONTENT_BLOCKING_NATIVE_CONTENT_BLOCKER_H_
#define CHROME_BROWSER_CONTENT_BLOCKING_NATIVE_CONTENT_BLOCKER_H_

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "base/callback_list.h"
#include "base/containers/flat_map.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/ref_counted_memory.h"
#include "base/memory/weak_ptr.h"
#include "base/threading/sequence_bound.h"
#include "base/time/time.h"
#include "components/keyed_service/core/keyed_service.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/global_routing_id.h"
#include "chrome/common/chrome_render_frame.mojom-forward.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "url/gurl.h"

class Profile;
namespace blink { class URLLoaderThrottle; }
namespace tabs { class TabInterface; }
namespace content { class RenderFrameHost; class WebContents; }

// A shared immutable source, but one mutable matcher for each actual Profile,
// including its own OTR instance. No UUID/default-profile matching fallback.
class NativeContentBlocker final : public KeyedService {
 public:
  enum Policy { kUnresolved = -1, kDisabled = 0, kEnabled = 1 };
  struct Result {
    uint64_t revision;
    enum Status { kReady = 0, kInvalidRules = 1, kSuperseded = 2,
                  kOwnerEnded = 3 } status;
  };
  using Completion = base::OnceCallback<void(Result)>;
  struct State {
    uint64_t context_id;
    uint64_t publication_revision;
    uint64_t installed_revision;
    uint64_t source_generation;
    uint64_t required_source_generation;
    uint64_t pending_revision;
    bool ready;
    Policy requested_policy;
  };
  // Passive main-thread registration is safe before ChromeMain. Only the first
  // policy can be unresolved; no factory, store or task runner is created there.
  static bool SetPolicy(Policy policy, uint64_t required_source_generation,
                        std::vector<std::string> domains);
  // Register only the factory identity in Chromium's normal startup list.
  // Services, native-owned rule bytes and mutable matchers remain lazy.
  static void EnsureFactoryBuilt();
  static bool IsRegistered();
  static std::unique_ptr<blink::URLLoaderThrottle> CreatePageTweaksThrottle();
  static void BindCosmeticResources(
      content::RenderFrameHost* frame,
      mojo::PendingReceiver<chrome::mojom::NookCosmeticResourcesHost> receiver);
  void GetCosmeticResources(content::GlobalRenderFrameHostId frame,
      const blink::DocumentToken& document, const GURL& url,
      std::vector<std::string> classes, std::vector<std::string> ids,
      bool generic,
      base::OnceCallback<void(chrome::mojom::NookCosmeticResourcesPtr)> callback);
  base::CallbackListSubscription ObserveCosmeticPolicy(
      base::RepeatingCallback<void(uint64_t)> callback);
  static bool RequiresInterception();
  static void PublishRules(scoped_refptr<const base::RefCountedMemory> bytes,
                           uint64_t source_generation, Completion callback);
  static void StopPolicy();

  static NativeContentBlocker* Get(Profile* profile, bool create);
  explicit NativeContentBlocker(Profile* profile);
  ~NativeContentBlocker() override;
  State state() const;
  // Readiness must never determine whether an eligible request is intercepted.
  // A disabled registered context still subscribes to the one policy owner so
  // an enable transition can reset existing factories without a context map.
  bool ShouldProxy() const;
  void Prepare(Completion callback);
  bool SetTabPolicy(tabs::TabInterface& tab, bool oauth,
                    std::string continued_host, base::TimeDelta duration);

  // Captured once from the request's actual RFH/navigation frame-tree node.
  // Async retries retain this document/site; a replacement document cannot lend
  // its tab exemption to the old request. Frame-less workers carry no tab.
  struct Client {
    base::WeakPtr<content::WebContents> contents;
    content::WeakDocumentPtr document;
    GURL site;
    int32_t tab = 0;
  };
  static Client CaptureClient(content::WebContents* contents,
                              content::RenderFrameHost* frame,
                              const GURL& captured_site);
  void Check(const GURL& url, const GURL& initiator, Client client,
             std::string request_type, std::string method,
             base::OnceCallback<void(int)> callback);
  void Shutdown() override;

 private:
  class Matcher;
  class CosmeticResourcesHost;
  struct CosmeticPolicy {
    uint64_t source_generation;
    uint64_t source_identity;
    Policy policy;
    bool operator==(const CosmeticPolicy&) const = default;
  };
  CosmeticPolicy CosmeticPolicyForDocument(content::RenderFrameHost& frame,
                                            const GURL& url) const;
  struct MatchResult { uint64_t revision; bool blocked; };
  struct Request {
    GURL url;
    GURL initiator;
    Client client;
    std::string type;
    std::string method;
    base::OnceCallback<void(int)> callback;
  };
  void OnPolicyChanged();
  void EnsureRules();
  void Installed(uint64_t revision, Result::Status status);
  void SettleWaiting();
  void CheckCaptured(Request request);
  bool IsExempt(const Request& request);
  void ResetFactories();

  const raw_ptr<Profile> profile_;
  const uint64_t context_id_;
  const std::shared_ptr<std::atomic<uint64_t>> latest_install_;
  // No task runner or mutable engine is allocated for disabled-only contexts.
  std::unique_ptr<base::SequenceBound<Matcher>> matcher_;
  base::CallbackListSubscription policy_subscription_;
  base::CallbackListSubscription page_tweaks_subscription_;
  base::RepeatingCallbackList<void(uint64_t)> cosmetic_policy_changed_;
  uint64_t policy_revision_ = 0;
  uint64_t installed_revision_ = 0;
  uint64_t pending_revision_ = 0;
  uint64_t failed_revision_ = 0;
  bool last_should_proxy_ = false;
  bool shutdown_ = false;
  std::vector<Completion> preparations_;
  // Only existing paused request continuations and scalar provenance; no body
  // materialization, alternative network proxy or Swift resource callbacks.
  std::vector<Request> waiting_;
  struct TabPolicy {
    bool oauth = false;
    std::string continued_host;
    base::TimeTicks disabled_until;
  };
  base::flat_map<int32_t, TabPolicy> tab_policies_;
  base::WeakPtrFactory<NativeContentBlocker> weak_factory_{this};
};
#endif
