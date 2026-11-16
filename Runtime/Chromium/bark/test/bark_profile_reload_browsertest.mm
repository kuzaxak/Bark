#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback_helpers.h"
#include "base/test/test_future.h"
#include "chrome/browser/affiliations/affiliation_service_factory.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_test_util.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/profile_destruction_waiter.h"
#include "components/affiliations/core/browser/affiliation_service.h"
#include "content/public/test/browser_test.h"

using BarkProfileReloadBrowserTest = InProcessBrowserTest;

// The queued lookups keep the first instance's affiliation database open past
// the moment ProfileManager lets the path be created again.
IN_PROC_BROWSER_TEST_F(BarkProfileReloadBrowserTest,
                       ReloadedProfileOpensItsAffiliationDatabase) {
  ProfileManager* manager = g_browser_process->profile_manager();
  const base::FilePath path = manager->user_data_dir().AppendASCII("Reloaded");
  Profile* first = &profiles::testing::CreateProfileSync(manager, path);
  affiliations::AffiliationService* first_affiliations =
      AffiliationServiceFactory::GetForProfile(first);
  for (int i = 0; i < 50000; ++i) {
    first_affiliations->GetPSLExtensions(base::DoNothing());
  }
  ProfileDestructionWaiter destroyed(first);
  ScopedProfileKeepAlive::TryAcquire(
      first, ProfileKeepAliveOrigin::kProfileCreationFlow)
      .reset();
  destroyed.Wait();

  Profile& second = profiles::testing::CreateProfileSync(manager, path);
  base::test::TestFuture<std::vector<std::string>> psl_extensions;
  AffiliationServiceFactory::GetForProfile(&second)->GetPSLExtensions(
      psl_extensions.GetCallback());
  EXPECT_TRUE(psl_extensions.Wait());
}
