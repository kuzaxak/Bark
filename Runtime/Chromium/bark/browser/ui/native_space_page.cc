#include "bark/browser/ui/native_space_page.h"

#include <map>

#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "components/sessions/core/session_id.h"

namespace bark {
namespace {

// Weak entries never extend the logical client's lifetime. Mutations remove
// expired entries so disposal does not accumulate historical session IDs.
auto& SuppressedOwners() {
  static base::NoDestructor<std::map<int32_t,
                                    base::WeakPtr<BrowserWindowInterface>>>
      owners;
  return *owners;
}

}  // namespace

bool IsNativeSpacePageSuppressed(const BrowserWindowInterface* owner) {
  if (!owner) {
    return false;
  }
  const auto& owners = SuppressedOwners();
  const auto entry = owners.find(owner->GetSessionID().id());
  return entry != owners.end() && entry->second.get() == owner;
}

bool SetNativeSpacePageSuppressed(BrowserWindowInterface* owner,
                                  bool suppressed) {
  auto& owners = SuppressedOwners();
  std::erase_if(owners, [](const auto& entry) { return !entry.second; });
  const int32_t id = owner->GetSessionID().id();
  return suppressed ? owners.try_emplace(id, owner->GetWeakPtr()).second
                    : owners.erase(id) != 0;
}

}  // namespace bark
