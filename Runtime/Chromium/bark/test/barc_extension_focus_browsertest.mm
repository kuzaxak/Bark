#import <AppKit/AppKit.h>

#include "bark/bridge/barc_bridge.h"
#include "bark/bridge/barc_bridge_functions.h"
#include "bark/bridge/barc_profiles.h"
#include "bark/browser/ui/bark_window_host.h"

#include <array>
#include <string>
#include <utility>

#include "base/command_line.h"
#include "base/functional/callback_helpers.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "base/values.h"
#include "chrome/browser/extensions/chrome_test_extension_loader.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "components/sessions/core/session_id.h"
#include "content/public/test/browser_test.h"
#include "extensions/browser/background_script_executor.h"
#include "extensions/common/extension.h"
#include "extensions/test/extension_test_message_listener.h"
#include "extensions/test/test_extension_dir.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/base/base_window.h"
#include "ui/base/test/ui_controls.h"
#include "ui/views/widget/widget.h"

namespace {
constexpr char kWork[] = "46bad13a-f9f9-4524-b376-299b82a19268";
constexpr char kPersonal[] = "8aaf2383-a9ac-4989-8763-b8405a02a046";
using OpenResult = base::test::TestFuture<barc_profile_status, int32_t>;
void Opened(barc_profile_status status, int32_t id, void* data) {
  static_cast<OpenResult*>(data)->SetValue(status, id);
}
BrowserWindowInterface* Window(int32_t id) {
  return GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(id));
}
base::Value Worker(Profile* profile,
                   const std::string& id,
                   const std::string& script) {
  return extensions::BackgroundScriptExecutor::ExecuteScript(
      profile, id, script,
      extensions::BackgroundScriptExecutor::ResultCapture::kSendScriptResult);
}
void ScopeListener(ExtensionTestMessageListener& listener,
                   Profile* profile,
                   const std::string& id) {
  listener.set_browser_context(profile);
  listener.set_extension_id(id);
}
}  // namespace

class BarcExtensionFocusBrowserTest : public InProcessBrowserTest {
 public:
  void SetUp() override {
    // Opt into real macOS focus before the base installs its fake-focus scope.
    // This process-wide UI-test opt-in follows interactive_ui_tests; run this
    // real-focus case in its own test child, without batching unrelated cases.
    ui_controls::EnableUIControls();
    ASSERT_TRUE(ui_controls::IsUIControlsEnabled());
    InProcessBrowserTest::SetUp();
  }
  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-native-shell");
    command_line->AppendSwitch("barc-shared-native-window");
  }
};

// Unpacked loading qualifies event routing only, not store/permission UI flows.
IN_PROC_BROWSER_TEST_F(BarcExtensionFocusBrowserTest,
                       ProfileSwitchRoutesRealFocusEventsWithoutNativeSwitch) {
  OpenResult first;
  barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Opened, &first);
  ASSERT_EQ(BARC_PROFILE_OK, first.Get<0>());
  const int32_t work_id = first.Get<1>();
  OpenResult second;
  barc_profile_open_in_native_window(work_id, kPersonal, BARC_PROFILE_BLANK,
                                     Opened, &second);
  ASSERT_EQ(BARC_PROFILE_OK, second.Get<0>());
  const int32_t personal_id = second.Get<1>();
  auto* work = Window(work_id);
  auto* personal = Window(personal_id);
  ASSERT_NE(nullptr, work);
  ASSERT_NE(nullptr, personal);
  ASSERT_NE(work->GetProfile(), personal->GetProfile());
  std::array<char, 37> uuid{};
  ASSERT_EQ(uuid.size(),
            barc_window_profile_uuid(work_id, uuid.data(), uuid.size()));
  ASSERT_STREQ(kWork, uuid.data());
  ASSERT_EQ(uuid.size(),
            barc_window_profile_uuid(personal_id, uuid.data(), uuid.size()));
  ASSERT_STREQ(kPersonal, uuid.data());
  auto* host = bark::BarkWindowHost::ForBrowser(work);
  ASSERT_NE(nullptr, host);
  ASSERT_EQ(host, bark::BarkWindowHost::ForBrowser(personal));
  ASSERT_EQ(work->GetWindow()->GetNativeWindow(),
            personal->GetWindow()->GetNativeWindow());
  extensions::TestExtensionDir extension_dir;
  extension_dir.WriteManifest(
      R"({"manifest_version":3,"name":"Barc focus probe",
    "version":"1.0","permissions":["storage"],
    "background":{"service_worker":"worker.js"}})");
  extension_dir.WriteFile(FILE_PATH_LITERAL("worker.js"), R"(
    let observations = Promise.resolve();
    chrome.windows.onFocusChanged.addListener(id => {
      observations = observations.then(async () => {
        const {events = []} = await chrome.storage.session.get('events');
        events.push(id);
        await chrome.storage.session.set({events});
        chrome.test.sendMessage('focus:' + id);
      });
    });
    chrome.test.sendMessage('ready');
  )");
  ExtensionTestMessageListener work_ready("ready");
  work_ready.set_browser_context(work->GetProfile());
  ExtensionTestMessageListener personal_ready("ready");
  personal_ready.set_browser_context(personal->GetProfile());
  extensions::ChromeTestExtensionLoader work_loader(work->GetProfile());
  extensions::ChromeTestExtensionLoader personal_loader(personal->GetProfile());
  auto work_extension = work_loader.LoadExtension(extension_dir.UnpackedPath());
  ASSERT_TRUE(work_extension);
  auto personal_extension =
      personal_loader.LoadExtension(extension_dir.UnpackedPath());
  ASSERT_TRUE(personal_extension);
  ASSERT_EQ(work_extension->id(), personal_extension->id());
  work_ready.set_extension_id(work_extension->id());
  personal_ready.set_extension_id(personal_extension->id());
  ASSERT_TRUE(work_ready.WaitUntilSatisfied());
  ASSERT_TRUE(personal_ready.WaitUntilSatisfied());
  const std::string extension_id = work_extension->id();
  // A profile's windows.onFocusChanged router hears activations only once an
  // extension listens, so the probes load before the window is activated.
  {
    ExtensionTestMessageListener work_focus("focus:" + std::to_string(work_id));
    ScopeListener(work_focus, work->GetProfile(), extension_id);
    ASSERT_EQ(1, barc_window_select(work_id));
    NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    ASSERT_EQ(1, barc_window_set_root_view(work_id, (__bridge void*)root));
    ASSERT_EQ(1, barc_window_show(work_id));
    host->widget()->Activate();
    ASSERT_TRUE(base::test::RunUntil([&] {
      return host->widget()->IsActive() && work->IsSelectedForNativeWindow() &&
             NSApp.keyWindow ==
                 work->GetWindow()->GetNativeWindow().GetNativeNSWindow();
    }));
    ASSERT_TRUE(work_focus.WaitUntilSatisfied());
  }
  NSWindow* const physical_window = NSApp.keyWindow;
  for (Profile* profile : {work->GetProfile(), personal->GetProfile()}) {
    EXPECT_EQ(base::Value(true), Worker(profile, extension_id, R"(
      observations = observations.then(async () => {
        await chrome.storage.session.set({events: []});
        chrome.test.sendScriptResult(true);
      });
    )"));
  }
  ASSERT_EQ(physical_window, NSApp.keyWindow);
  __block int native_key_changes = 0;
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  id became_key = [center addObserverForName:NSWindowDidBecomeKeyNotification
                                      object:physical_window
                                       queue:nil
                                  usingBlock:^(NSNotification*) {
                                    ++native_key_changes;
                                  }];
  id resigned_key = [center addObserverForName:NSWindowDidResignKeyNotification
                                        object:physical_window
                                         queue:nil
                                    usingBlock:^(NSNotification*) {
                                      ++native_key_changes;
                                    }];
  base::ScopedClosureRunner remove_observers(
      base::BindLambdaForTesting([center, became_key, resigned_key] {
        [center removeObserver:became_key];
        [center removeObserver:resigned_key];
      }));

  {
    ExtensionTestMessageListener work_blur("focus:-1");
    ExtensionTestMessageListener personal_focus("focus:" +
                                                std::to_string(personal_id));
    ScopeListener(work_blur, work->GetProfile(), extension_id);
    ScopeListener(personal_focus, personal->GetProfile(), extension_id);
    ASSERT_EQ(1, barc_window_select(personal_id));
    ASSERT_TRUE(work_blur.WaitUntilSatisfied());
    ASSERT_TRUE(personal_focus.WaitUntilSatisfied());
    ASSERT_EQ(physical_window, NSApp.keyWindow);
  }
  {
    ExtensionTestMessageListener personal_blur("focus:-1");
    ExtensionTestMessageListener work_focus("focus:" + std::to_string(work_id));
    ScopeListener(personal_blur, personal->GetProfile(), extension_id);
    ScopeListener(work_focus, work->GetProfile(), extension_id);
    ASSERT_EQ(1, barc_window_select(work_id));
    ASSERT_TRUE(personal_blur.WaitUntilSatisfied());
    ASSERT_TRUE(work_focus.WaitUntilSatisfied());
    ASSERT_EQ(physical_window, NSApp.keyWindow);
  }
  const std::string read = R"(
    observations = observations.then(async () => {
      const {events} = await chrome.storage.session.get('events');
      chrome.test.sendScriptResult(events);
    });
  )";
  base::ListValue work_expected;
  work_expected.Append(-1);
  work_expected.Append(work_id);
  base::ListValue personal_expected;
  personal_expected.Append(personal_id);
  personal_expected.Append(-1);
  EXPECT_EQ(base::Value(std::move(work_expected)),
            Worker(work->GetProfile(), extension_id, read));
  EXPECT_EQ(base::Value(std::move(personal_expected)),
            Worker(personal->GetProfile(), extension_id, read));
  EXPECT_EQ(physical_window, NSApp.keyWindow);
  EXPECT_EQ(0, native_key_changes);
}
