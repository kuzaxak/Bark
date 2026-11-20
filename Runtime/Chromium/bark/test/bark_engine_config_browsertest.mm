#include <atomic>
#include <memory>

#include "base/metrics/field_trial.h"
#include "base/test/bind.h"
#include "chrome/browser/after_startup_task_utils.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/prerender_test_util.h"
#include "net/base/network_anonymization_key.h"
#include "net/dns/mock_host_resolver.h"
#include "net/http/http_cache.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/http_request.h"
#include "net/test/embedded_test_server/http_response.h"
#include "testing/gmock/include/gmock/gmock.h"

using BarkEngineConfigBrowserTest = InProcessBrowserTest;

// Unbranded builds apply testing/variations/fieldtrial_testing_config.json
// unless the build turns it off. Its PrewarmZeroSuggestTrigger study makes a
// finished load prerender the search engine's warm-up page once startup is
// complete, at most once per tab.
IN_PROC_BROWSER_TEST_F(BarkEngineConfigBrowserTest,
                       TestingFieldTrialConfigIsNotApplied) {
  EXPECT_FALSE(base::FieldTrialList::TrialExists("PrewarmZeroSuggestTrigger"));
}

IN_PROC_BROWSER_TEST_F(BarkEngineConfigBrowserTest,
                       FinishedLoadStartsNoPrerender) {
  ASSERT_TRUE(embedded_test_server()->Start());
  AfterStartupTaskUtils::SetBrowserStartupIsCompleteForTesting();
  std::unique_ptr<content::WebContents> contents = content::WebContents::Create(
      content::WebContents::CreateParams(browser()->GetProfile()));
  content::test::PrerenderHostRegistryObserver prerenders(*contents);
  browser()->GetTabStripModel()->AppendWebContents(std::move(contents),
                                                  /*foreground=*/true);
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), embedded_test_server()->GetURL("/title1.html")));
  EXPECT_THAT(prerenders.GetTriggeredUrls(), testing::IsEmpty());
}

class BarkNetworkPartitionBrowserTest : public InProcessBrowserTest {
 protected:
  void SetUpOnMainThread() override {
    InProcessBrowserTest::SetUpOnMainThread();
    host_resolver()->AddRule("*", "127.0.0.1");
  }
};

// The net features default off; Chrome's main delegate turns both partitions on
// unless a switch or a field trial overrides them.
IN_PROC_BROWSER_TEST_F(BarkNetworkPartitionBrowserTest,
                       CacheAndConnectionsArePartitionedBySite) {
  EXPECT_TRUE(net::HttpCache::IsSplitCacheEnabled());
  EXPECT_TRUE(net::NetworkAnonymizationKey::IsPartitioningEnabled());

  std::atomic<int> loads = 0;
  embedded_test_server()->RegisterRequestHandler(base::BindLambdaForTesting(
      [&](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/cached") {
          return nullptr;
        }
        ++loads;
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->AddCustomHeader("Cache-Control", "max-age=600");
        response->AddCustomHeader("Access-Control-Allow-Origin", "*");
        response->set_content("cached");
        return response;
      }));
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL resource = embedded_test_server()->GetURL("c.test", "/cached");
  for (const char* site : {"a.test", "b.test", "a.test"}) {
    ASSERT_TRUE(ui_test_utils::NavigateToURL(
        browser(), embedded_test_server()->GetURL(site, "/title1.html")));
    EXPECT_EQ("cached",
              content::EvalJs(
                  browser()->GetTabStripModel()->GetActiveWebContents(),
                  content::JsReplace("fetch($1).then(r => r.text())", resource)));
  }
  EXPECT_EQ(2, loads.load());
}
