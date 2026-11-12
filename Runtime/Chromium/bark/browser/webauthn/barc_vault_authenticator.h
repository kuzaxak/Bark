#ifndef CHROME_BROWSER_WEBAUTHN_BARC_VAULT_AUTHENTICATOR_H_
#define CHROME_BROWSER_WEBAUTHN_BARC_VAULT_AUTHENTICATOR_H_

#include <memory>
#include <optional>
#include <string>

#include "base/functional/callback.h"
#include "base/values.h"

namespace content { class RenderFrameHost; class WebContents; }
namespace device { class FidoDiscoveryBase; }
namespace url { class Origin; }
namespace barc {
inline constexpr char kPawlAuthenticatorId[] = "NookPawlVault";
// Only the validated Chrome request delegate constructs this discovery. Stock
// discoveries remain unchanged. No conditional/resident metadata is fabricated.
std::unique_ptr<device::FidoDiscoveryBase> CreateVaultPasskeyDiscovery(
    content::RenderFrameHost* frame, const url::Origin& origin,
    const std::string& relying_party);
// Read-only exact-frame readiness; never creates a service or retargets a context.
bool IsVaultPasskeyAvailable(content::RenderFrameHost* frame);
// Implemented by the existing exact-page observation, not a ceremony registry.
base::RepeatingCallback<bool()> VaultPasskeyContext(content::RenderFrameHost* frame);
// Only register(0) and explicit modal assertion(1). reply runs on UI, asynchronously,
// at most once; nullopt means refusal. The returned closure cancels exact work.
base::OnceClosure StartVaultPasskeyRequest(
    content::RenderFrameHost* frame, const url::Origin& origin,
    int operation, base::DictValue arguments,
    base::OnceCallback<void(std::optional<std::string>)> reply);
}  // namespace barc
#endif
