#import <AppKit/AppKit.h>

#include <algorithm>
#include <cstdlib>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "bark/bridge/barc_bridge_functions.h"
#include "bark/bridge/barc_profiles.h"
#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_window_host.h"
#include "base/base_switches.h"
#include "base/command_line.h"
#include "base/functional/callback_helpers.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "base/types/optional_ref.h"
#include "base/values.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/devtools/devtools_window_testing.h"
#include "chrome/browser/extensions/extension_uninstall_dialog.h"
#include "chrome/browser/media/router/media_router_feature.h"
#include "chrome/browser/printing/print_preview_dialog_controller.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/renderer_context_menu/render_view_context_menu_test_util.h"
#include "chrome/browser/ui/autofill/address_bubbles_controller.h"
#include "chrome/browser/ui/autofill/payments/filled_card_information_bubble_controller_impl.h"
#include "chrome/browser/ui/autofill/payments/virtual_card_enroll_bubble_controller_impl.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/extensions/extension_install_ui_desktop.h"
#include "chrome/browser/ui/passwords/manage_passwords_ui_controller.h"
#include "chrome/browser/ui/qrcode_generator/qrcode_generator_bubble_controller.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/toasts/api/toast_id.h"
#include "chrome/browser/ui/toasts/toast_controller.h"
#include "chrome/browser/ui/views/location_bar/location_bar_bubble_delegate_view.h"
#include "chrome/browser/ui/views/passwords/password_bubble_view_base.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/autofill/core/browser/data_model/addresses/autofill_profile.h"
#include "components/autofill/core/browser/data_model/payments/credit_card.h"
#include "components/autofill/core/browser/field_types.h"
#include "components/autofill/core/browser/payments/legal_message_line.h"
#include "components/autofill/core/browser/payments/virtual_card_enrollment_flow.h"
#include "components/autofill/core/browser/payments/virtual_card_enrollment_manager.h"
#include "components/autofill/core/browser/ui/payments/bubble_show_options.h"
#include "components/password_manager/core/common/password_manager_ui.h"
#include "components/permissions/permission_request_manager.h"
#include "components/permissions/test/permission_request_observer.h"
#include "components/remote_cocoa/app_shim/native_widget_ns_window_bridge.h"
#include "components/remote_cocoa/common/native_widget_ns_window_host.mojom.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/eye_dropper.h"
#include "content/public/browser/eye_dropper_listener.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/common/extension_builder.h"
#include "net/dns/mock_host_resolver.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/http_request.h"
#include "net/test/embedded_test_server/http_response.h"
#include "testing/gmock/include/gmock/gmock.h"
#include "third_party/skia/include/core/SkBitmap.h"
#import "ui/base/cocoa/nsmenu_additions.h"
#include "ui/base/test/scoped_fake_nswindow_fullscreen.h"
#include "ui/base/test/ui_controls.h"
#include "ui/events/test/cocoa_test_event_utils.h"
#include "ui/gfx/animation/animation_test_api.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/test/widget_test.h"
#include "ui/views/widget/widget.h"

namespace {

BrowserWindowInterface* FindBrowser(int32_t id) {
  return GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(id));
}

content::WebContents* TabContents(int32_t tab) {
  auto* interface = tabs::TabHandle(tab).Get();
  return interface ? interface->GetContents() : nullptr;
}

std::unique_ptr<net::test_server::HttpResponse> ServeSignIn(
    const net::test_server::HttpRequest& request) {
  if (request.relative_url != "/sign-in" && request.relative_url != "/done") {
    return nullptr;
  }
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_content_type("text/html");
  response->set_content(
      request.relative_url == "/done"
          ? "<title>done</title>"
          : "<title>sign in</title><form action=/done method=post>"
            "<input id=user name=user autocomplete=username>"
            "<input id=pass name=pass type=password "
            "autocomplete=current-password>"
            "<button id=go>Sign in</button></form>");
  return response;
}

}  // namespace

class BarkHostStockUiBrowserTest : public InProcessBrowserTest {
 public:
  BarkHostStockUiBrowserTest() { SetAllowFeaturesSwitches(true); }

  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-native-shell");
    command_line->AppendSwitch("barc-shared-native-window");
    command_line->AppendSwitchASCII("bark-window", "host");
    // The app starts the engine without Cast.
    command_line->AppendSwitchASCII(switches::kDisableFeatures, "MediaRouter");
  }

 protected:
  // A shown host window whose app root holds one loaded page, placed.
  int32_t OpenPlacedPage(const char* path) {
    const int32_t window = barc_window_new_peer(browser()->GetSessionID().id());
    EXPECT_GT(window, 0);
    root_ = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    EXPECT_EQ(1, barc_window_set_root_view(window, (__bridge void*)root_));
    tab_ = barc_tab_create(
        window, embedded_test_server()->GetURL(path).spec().c_str(), 1);
    EXPECT_NE(0, tab_);
    EXPECT_TRUE(content::WaitForLoadStop(TabContents(tab_)));
    EXPECT_EQ(1, barc_window_show(window));
    page_ = (__bridge NSView*)barc_tab_native_view(window, tab_);
    page_.frame = root_.bounds;
    [root_ addSubview:page_];
    auto* contents = TabContents(tab_);
    EXPECT_TRUE(base::test::RunUntil([&] {
      return contents->GetVisibility() == content::Visibility::VISIBLE;
    }));
    window_ = window;
    return window;
  }
  bark::BarkBrowserWindow* Window() {
    return bark::BarkBrowserWindow::FromBrowser(FindBrowser(window_));
  }
  content::WebContents* Contents() { return TabContents(tab_); }
  std::vector<views::BubbleDialogDelegate*> Bubbles() {
    std::vector<views::BubbleDialogDelegate*> bubbles;
    for (views::Widget* widget : views::Widget::GetAllOwnedWidgets(
             Window()->host()->widget()->GetNativeView())) {
      auto* bubble = widget->widget_delegate()
                         ? widget->widget_delegate()->AsBubbleDialogDelegate()
                         : nullptr;
      if (bubble && widget->IsVisible()) {
        bubbles.push_back(bubble);
      }
    }
    return bubbles;
  }
  views::BubbleDialogDelegate* WaitForBubble(size_t count = 1) {
    if (!base::test::RunUntil([&] { return Bubbles().size() >= count; })) {
      return nullptr;
    }
    return Bubbles().back();
  }
  // Hangs inside the page's top-right corner, 8 pt in from its right edge.
  void ExpectAtThePageTopRight(views::BubbleDialogDelegate* bubble) {
    const gfx::Rect page = Window()->GetPageBoundsInScreen();
    const gfx::Rect frame = bubble->GetWidget()->GetWindowBoundsInScreen();
    EXPECT_TRUE(page.Contains(frame)) << page.ToString() << " " << frame.ToString();
    EXPECT_GE(page.right() - frame.right(), 8) << page.ToString() << " " << frame.ToString();
    EXPECT_LE(page.right() - frame.right(), 9) << page.ToString() << " " << frame.ToString();
  }

  NSView* root_ = nil;
  NSView* page_ = nil;
  int32_t window_ = 0;
  int32_t tab_ = 0;
};

IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest,
                       SaveAddressPromptShowsInHostWindow) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  autofill::AutofillProfile profile(autofill::AddressCountryCode("US"));
  profile.SetRawInfo(autofill::NAME_FULL, u"Jane Doe");
  profile.SetRawInfo(autofill::ADDRESS_HOME_LINE1, u"1 Main Street");
  profile.SetRawInfo(autofill::ADDRESS_HOME_CITY, u"Springfield");
  profile.SetRawInfo(autofill::ADDRESS_HOME_STATE, u"IL");
  profile.SetRawInfo(autofill::ADDRESS_HOME_ZIP, u"62701");
  profile.SetRawInfo(autofill::ADDRESS_HOME_COUNTRY, u"US");
  base::test::TestFuture<autofill::AutofillClient::AddressPromptUserDecision>
      decision;
  // The entry the form submission takes once autofill decides to offer saving.
  autofill::AddressBubblesController::SetUpAndShowSaveOrUpdateAddressBubble(
      Contents(), profile, nullptr,
      autofill::AutofillClient::SaveAddressBubbleType::kSave, false,
      base::BindOnce(
          [](base::OnceCallback<void(
                 autofill::AutofillClient::AddressPromptUserDecision)> done,
             autofill::AutofillClient::AddressPromptUserDecision answer,
             base::optional_ref<const autofill::AutofillProfile>) {
            std::move(done).Run(answer);
          },
          decision.GetCallback()));
  auto* bubble = WaitForBubble();
  ASSERT_NE(nullptr, bubble);
  ExpectAtThePageTopRight(bubble);
  views::test::WidgetDestroyedWaiter closed(bubble->GetWidget());
  bubble->AcceptDialog();
  EXPECT_EQ(autofill::AutofillClient::AddressPromptUserDecision::kAccepted,
            decision.Get());
  closed.Wait();
}

IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest,
                       DeclinedAddressPromptClosesInHostWindow) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  autofill::AutofillProfile profile(autofill::AddressCountryCode("US"));
  profile.SetRawInfo(autofill::NAME_FULL, u"Jane Doe");
  profile.SetRawInfo(autofill::ADDRESS_HOME_LINE1, u"1 Main Street");
  profile.SetRawInfo(autofill::ADDRESS_HOME_CITY, u"Springfield");
  profile.SetRawInfo(autofill::ADDRESS_HOME_STATE, u"IL");
  profile.SetRawInfo(autofill::ADDRESS_HOME_ZIP, u"62701");
  profile.SetRawInfo(autofill::ADDRESS_HOME_COUNTRY, u"US");
  base::test::TestFuture<autofill::AutofillClient::AddressPromptUserDecision>
      decision;
  autofill::AddressBubblesController::SetUpAndShowSaveOrUpdateAddressBubble(
      Contents(), profile, nullptr,
      autofill::AutofillClient::SaveAddressBubbleType::kSave, false,
      base::BindOnce(
          [](base::OnceCallback<void(
                 autofill::AutofillClient::AddressPromptUserDecision)> done,
             autofill::AutofillClient::AddressPromptUserDecision answer,
             base::optional_ref<const autofill::AutofillProfile>) {
            std::move(done).Run(answer);
          },
          decision.GetCallback()));
  auto* bubble = WaitForBubble();
  ASSERT_NE(nullptr, bubble);
  views::test::WidgetDestroyedWaiter closed(bubble->GetWidget());
  bubble->CancelDialog();
  EXPECT_EQ(autofill::AutofillClient::AddressPromptUserDecision::kDeclined,
            decision.Get());
  closed.Wait();
}

IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest,
                       VirtualCardAndFilledCardBubblesShow) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  autofill::CreditCard card(autofill::CreditCard::RecordType::kMaskedServerCard,
                            "card");
  card.SetNumber(u"4111111111111111");
  card.SetRawInfo(autofill::CREDIT_CARD_NAME_FULL, u"Jane Doe");
  card.SetExpirationMonth(12);
  card.SetExpirationYear(2040);
  SkBitmap bitmap;
  bitmap.allocN32Pixels(40, 24);
  bitmap.eraseColor(SK_ColorBLUE);
  const gfx::ImageSkia art = gfx::ImageSkia::CreateFrom1xBitmap(bitmap);

  // Payments' server answer opens these; the controllers are what it calls.
  autofill::VirtualCardEnrollmentFields fields;
  fields.credit_card = card;
  fields.card_art_image = &art;
  fields.virtual_card_enrollment_source =
      autofill::VirtualCardEnrollmentSource::kUpstream;
  base::DictValue legal;
  legal.Set("line", base::ListValue().Append(
                        base::DictValue().Set("template", "Legal message")));
  ASSERT_TRUE(autofill::LegalMessageLine::Parse(legal,
                                                &fields.google_legal_message));
  autofill::VirtualCardEnrollBubbleControllerImpl::CreateForWebContents(
      Contents());
  autofill::VirtualCardEnrollBubbleControllerImpl::FromWebContents(Contents())
      ->SetupAndShowBubble(fields, base::DoNothing(), base::DoNothing());
  auto* enroll = WaitForBubble();
  ASSERT_NE(nullptr, enroll);
  ExpectAtThePageTopRight(enroll);
  enroll->GetWidget()->CloseNow();
  ASSERT_TRUE(base::test::RunUntil([&] { return Bubbles().empty(); }));

  autofill::FilledCardInformationBubbleOptions options;
  options.masked_card_name = u"Visa";
  options.masked_card_number_last_four = u"\u2022\u2022\u2022\u2022 1111";
  options.filled_card = card;
  options.cvc = u"123";
  options.card_image = gfx::Image(art);
  ASSERT_TRUE(options.IsValid());
  autofill::FilledCardInformationBubbleControllerImpl::CreateForWebContents(
      Contents());
  autofill::FilledCardInformationBubbleControllerImpl::FromWebContents(
      Contents())
      ->SetupAndShowBubble(options);
  auto* filled = WaitForBubble();
  ASSERT_NE(nullptr, filled);
  ExpectAtThePageTopRight(filled);
}

IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest,
                       QRCodeBubbleShowsInHostWindow) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  // What the page context menu's Create QR Code runs.
  qrcode_generator::QRCodeGeneratorBubbleController::Get(Contents())
      ->ShowBubble(Contents()->GetLastCommittedURL());
  auto* bubble = WaitForBubble();
  ASSERT_NE(nullptr, bubble);
  ExpectAtThePageTopRight(bubble);
}

IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest,
                       SavePasswordBubbleShowsWithoutVault) {
  embedded_test_server()->RegisterRequestHandler(
      base::BindRepeating(&ServeSignIn));
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/sign-in");
  ASSERT_TRUE(content::ExecJs(Contents(),
                              "document.getElementById('user').value = 'jane';"
                              "document.getElementById('pass').value = "
                              "'pw-123456';"));
  auto* passwords = ManagePasswordsUIController::FromWebContents(Contents());
  ASSERT_TRUE(base::test::RunUntil([&] {
    return passwords->GetState() == password_manager::ui::PENDING_PASSWORD_STATE;
  }));
  // A typed password leaves a pending save behind Chrome's key icon; this is
  // the call the icon makes.
  PasswordBubbleViewBase::ShowBubble(Contents(),
                                     LocationBarBubbleDelegateView::USER_GESTURE);
  auto* bubble = WaitForBubble();
  ASSERT_NE(nullptr, bubble);
  ExpectAtThePageTopRight(bubble);
}

IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest, BubbleAnchorsFollowThePage) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  qrcode_generator::QRCodeGeneratorBubbleController::Get(Contents())
      ->ShowBubble(Contents()->GetLastCommittedURL());
  auto* bubble = WaitForBubble();
  ASSERT_NE(nullptr, bubble);
  ExpectAtThePageTopRight(bubble);
  // The app lays the page out again without the window moving: the sidebar or
  // the Library takes 200 pt.
  page_.frame = NSMakeRect(0, 0, 600, 600);
  ASSERT_TRUE(base::test::RunUntil([&] {
    const gfx::Rect page = Window()->GetPageBoundsInScreen();
    return bubble->GetAnchorRect().x() == page.right() - 8;
  }));
  ExpectAtThePageTopRight(bubble);
}

// A prompt of a client that is not the window's selected one, such as one that
// arrives just after the person switched profiles, never shows over another
// client's page.
IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest,
                       UnselectedClientBubbleDoesNotShow) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  base::test::TestFuture<barc_profile_status, int32_t> opened;
  barc_profile_open_in_native_window(
      window_, "5b1e9c37-4a2d-48f6-b0e3-9d7c2a6f1e85", BARC_PROFILE_BLANK,
      [](barc_profile_status status, int32_t window, void* data) {
        static_cast<base::test::TestFuture<barc_profile_status, int32_t>*>(data)
            ->SetValue(status, window);
      },
      &opened);
  ASSERT_EQ(BARC_PROFILE_OK, opened.Get<0>());
  const int32_t other = opened.Get<1>();
  ASSERT_EQ(1, barc_window_select(window_));
  content::WebContents* other_page =
      FindBrowser(other)->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(other_page);
  qrcode_generator::QRCodeGeneratorBubbleController::Get(other_page)
      ->ShowBubble(GURL("https://example.com/"));
  content::RunAllTasksUntilIdle();
  EXPECT_TRUE(base::test::RunUntil([&] { return Bubbles().empty(); }));
  // The selected client's own bubble still shows.
  qrcode_generator::QRCodeGeneratorBubbleController::Get(Contents())
      ->ShowBubble(Contents()->GetLastCommittedURL());
  auto* bubble = WaitForBubble();
  ASSERT_NE(nullptr, bubble);
  ExpectAtThePageTopRight(bubble);
}

IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest, TwoBubblesKeepTheirCorners) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  permissions::PermissionRequestObserver shown(Contents());
  content::ExecuteScriptAsync(Contents(),
                              "navigator.geolocation.getCurrentPosition("
                              "  () => {}, () => {});");
  shown.Wait();
  ASSERT_TRUE(shown.request_shown());
  auto* prompt = WaitForBubble();
  ASSERT_NE(nullptr, prompt);
  const gfx::Rect prompt_frame = prompt->GetWidget()->GetWindowBoundsInScreen();
  qrcode_generator::QRCodeGeneratorBubbleController::Get(Contents())
      ->ShowBubble(Contents()->GetLastCommittedURL());
  ASSERT_NE(nullptr, WaitForBubble(2));
  views::BubbleDialogDelegate* qr = nullptr;
  for (auto* bubble : Bubbles()) {
    if (bubble != prompt) {
      qr = bubble;
    }
  }
  ASSERT_NE(nullptr, qr);
  ExpectAtThePageTopRight(qr);
  EXPECT_EQ(prompt_frame, prompt->GetWidget()->GetWindowBoundsInScreen());
  const gfx::Rect page = Window()->GetPageBoundsInScreen();
  EXPECT_LT(prompt->GetAnchorRect().x() - page.x(), page.width() / 2);
}

// A toast is Chromium's pill, centred on the page and inside it near its foot.
void ExpectToastAtThePageFoot(views::Widget* toast, const gfx::Rect& page) {
  ASSERT_NE(nullptr, toast);
  ASSERT_TRUE(toast->IsVisible());
  const gfx::Rect pill = toast->GetWindowBoundsInScreen();
  EXPECT_TRUE(page.Contains(pill)) << page.ToString() << " " << pill.ToString();
  EXPECT_LE(std::abs(pill.CenterPoint().x() - page.CenterPoint().x()), 1)
      << page.ToString() << " " << pill.ToString();
  EXPECT_LE(page.bottom() - pill.bottom(), 40)
      << page.ToString() << " " << pill.ToString();
}

IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest, PageToastShowsOverThePage) {
  // The pill slides in; measure where it stops.
  auto no_slide = gfx::AnimationTestApi::SetRichAnimationRenderMode(
      gfx::Animation::RichAnimationRenderMode::FORCE_DISABLED);
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  auto* toasts = ToastController::From(FindBrowser(window_));
  ASSERT_TRUE(toasts->MaybeShowToast(ToastParams(ToastId::kLinkCopied)));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return toasts->GetToastWidgetForTesting() &&
           toasts->GetToastWidgetForTesting()->IsVisible();
  }));
  views::Widget* toast = toasts->GetToastWidgetForTesting();
  EXPECT_EQ(Window()->host()->widget(), toast->parent());
  ExpectToastAtThePageFoot(toast, Window()->GetPageBoundsInScreen());
}

// Back on a tab, the app places its view again at the frame it had, so no
// frame change follows.
IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest,
                       ToastFollowsAPagePlacedAfterATabSwitch) {
  auto no_slide = gfx::AnimationTestApi::SetRichAnimationRenderMode(
      gfx::Animation::RichAnimationRenderMode::FORCE_DISABLED);
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  const int32_t first = tab_;
  NSView* first_page = page_;
  const int32_t second = barc_tab_create(
      window_, embedded_test_server()->GetURL("/title2.html").spec().c_str(),
      1);
  ASSERT_NE(0, second);
  ASSERT_TRUE(content::WaitForLoadStop(TabContents(second)));
  NSView* second_page = (__bridge NSView*)barc_tab_native_view(window_, second);
  ASSERT_NE(nil, second_page);
  // AppKit reports each placement as the page turning hidden or visible, late
  // or never while the test window is covered by other apps' windows; send
  // what it reports in view directly.
  auto place = [&](int32_t show, NSView* show_view, int32_t hide,
                   NSView* hide_view, NSRect frame) {
    [hide_view removeFromSuperview];
    TabContents(hide)->WasHidden();
    show_view.frame = frame;
    [root_ addSubview:show_view];
    TabContents(show)->WasShown();
  };
  place(second, second_page, first, first_page, NSMakeRect(300, 0, 500, 600));
  ASSERT_EQ(1, barc_tab_select(window_, first));
  place(first, first_page, second, second_page, root_.bounds);
  ASSERT_EQ(1, barc_tab_select(window_, second));
  place(second, second_page, first, first_page, NSMakeRect(300, 0, 500, 600));
  auto* toasts = ToastController::From(FindBrowser(window_));
  ASSERT_TRUE(toasts->MaybeShowToast(ToastParams(ToastId::kLinkCopied)));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return toasts->GetToastWidgetForTesting() &&
           toasts->GetToastWidgetForTesting()->IsVisible();
  }));
  ExpectToastAtThePageFoot(toasts->GetToastWidgetForTesting(),
                           Window()->GetPageBoundsInScreen());
}

IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest,
                       WindowToastAndFullscreenToastShow) {
  ui::test::ScopedFakeNSWindowFullscreen fake_fullscreen;
  auto no_slide = gfx::AnimationTestApi::SetRichAnimationRenderMode(
      gfx::Animation::RichAnimationRenderMode::FORCE_DISABLED);
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  auto* toasts = ToastController::From(FindBrowser(window_));
  auto shown = [&] {
    return toasts->GetToastWidgetForTesting() &&
           toasts->GetToastWidgetForTesting()->IsVisible();
  };
  ASSERT_TRUE(toasts->MaybeShowToast(ToastParams(ToastId::kNonMilestoneUpdate)));
  ASSERT_TRUE(base::test::RunUntil(shown));
  ExpectToastAtThePageFoot(toasts->GetToastWidgetForTesting(),
                           Window()->GetPageBoundsInScreen());
  toasts->GetToastWidgetForTesting()->CloseNow();
  ASSERT_TRUE(base::test::RunUntil([&] { return !shown(); }));

  Window()->host()->widget()->SetFullscreen(true);
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return Window()->host()->widget()->IsFullscreen(); }));
  page_.frame = root_.bounds;
  ASSERT_TRUE(toasts->MaybeShowToast(ToastParams(ToastId::kLinkCopied)));
  ASSERT_TRUE(base::test::RunUntil(shown));
  ExpectToastAtThePageFoot(toasts->GetToastWidgetForTesting(),
                           Window()->GetPageBoundsInScreen());
}

namespace {

std::unique_ptr<net::test_server::HttpResponse> ServeKeys(
    const net::test_server::HttpRequest& request) {
  if (request.relative_url != "/keys") {
    return nullptr;
  }
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_content_type("text/html");
  response->set_content(
      "<title>keys</title><a id=link href=/title1.html>link</a><script>"
      "window.newTabKeys = 0; window.markers = 0; window.clicks = 0;"
      "addEventListener('click', () => clicks++);"
      "addEventListener('keydown', e => {"
      "  if (e.metaKey && e.key === 't') { e.preventDefault(); newTabKeys++; }"
      "  if (e.key === 'k') markers++;"
      "});</script>");
  return response;
}

// Commands a host window has no UI for, by the brief's list and the sweep.
constexpr int kUnofferedCommands[] = {
    IDC_BOOKMARK_ALL_TABS,
    IDC_BOOKMARK_THIS_TAB,
    IDC_CARET_BROWSING_TOGGLE,
    IDC_CONTENT_CONTEXT_ADD_LINK_TO_READING_LIST,
    IDC_CONTENT_CONTEXT_LENS_REGION_SEARCH,
    IDC_CONTENT_CONTEXT_LISTEN_TO_THIS_PAGE,
    IDC_CONTENT_CONTEXT_OPEN_IN_READING_MODE,
    IDC_FOCUS_BOOKMARKS,
    IDC_FOCUS_TOOLBAR,
    IDC_READING_LIST_MENU_ADD_TAB,
    IDC_ROUTE_MEDIA,
    IDC_SEND_TAB_TO_SELF,
    IDC_SHOW_APP_MENU,
    IDC_SHOW_AVATAR_MENU,
    IDC_SHOW_BOOKMARK_BAR,
    IDC_SHOW_CHROME_LABS,
    IDC_TAB_SEARCH,
};

bool Unoffered(int command) {
  return std::ranges::find(kUnofferedCommands, command) !=
         std::end(kUnofferedCommands);
}

void CollectMenuCommands(NSMenu* menu, std::set<int>* commands) {
  for (NSMenuItem* item in menu.itemArray) {
    if (item.submenu) {
      CollectMenuCommands(item.submenu, commands);
    } else if (item.action == @selector(commandDispatch:) ||
               item.action == @selector(commandDispatchUsingKeyModifiers:)) {
      commands->insert(static_cast<int>(item.tag));
    }
  }
}

NSMenuItem* MenuItemWithTag(NSMenu* menu, int tag) {
  for (NSMenuItem* item in menu.itemArray) {
    if (item.submenu) {
      if (NSMenuItem* found = MenuItemWithTag(item.submenu, tag)) {
        return found;
      }
    } else if (item.tag == tag) {
      return item;
    }
  }
  return nil;
}

}  // namespace

// The app's startup: Chromium is ready, the app opens its first host window
// and completes startup with it, which puts the engine in native application
// mode as in Bark.
class BarkHostCommandBrowserTest : public BarkHostStockUiBrowserTest {
 public:
  void SetUp() override {
    barc_set_runtime_ready_callback(
        [](void*) {
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
          const int32_t window = barc_window_new_peer(initial);
          CHECK_GT(window, 0);
          static NSView* root =
              [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
          CHECK_EQ(1, barc_window_set_root_view(window, (__bridge void*)root));
          barc_runtime_complete_startup(window);
        },
        nullptr);
    BarkHostStockUiBrowserTest::SetUp();
  }
  void SetUpOnMainThread() override {
    BarkHostStockUiBrowserTest::SetUpOnMainThread();
    host_resolver()->AddRule("*", "127.0.0.1");
  }

 protected:
  NSWindow* NativeWindow() {
    return Window()->GetNativeWindow().GetNativeNSWindow();
  }
  remote_cocoa::mojom::NativeWidgetNSWindowHost* Host() {
    return remote_cocoa::NativeWidgetNSWindowBridge::GetFromNSWindow(
               NativeWindow())
        ->host();
  }
  remote_cocoa::mojom::ValidateUserInterfaceItemResultPtr Validate(
      int command) {
    remote_cocoa::mojom::ValidateUserInterfaceItemResultPtr result;
    Host()->ValidateUserInterfaceItem(command, &result);
    return result;
  }
  bool WillExecute(int command, bool before_first_responder) {
    bool will_execute = false;
    Host()->WillExecuteCommand(command, WindowOpenDisposition::CURRENT_TAB,
                               before_first_responder, &will_execute);
    return will_execute;
  }
  // AppKit's event loop makes an event current before dispatching it.
  NSEvent* MakeCurrent(NSEvent* event) {
    [NSApp postEvent:event atStart:YES];
    return [NSApp nextEventMatchingMask:NSEventMaskFromType(event.type)
                              untilDate:nil
                                 inMode:NSDefaultRunLoopMode
                                dequeue:YES];
  }
  void FocusPage() {
    Contents()->Focus();
    NSView* page_view =
        Contents()->GetRenderWidgetHostView()->GetNativeView().GetNativeNSView();
    [NativeWindow() makeFirstResponder:page_view];
    ASSERT_EQ(page_view, NativeWindow().firstResponder);
    // A key sent before the renderer has the focus does not reach the page.
    ASSERT_TRUE(base::test::RunUntil([&] {
      return content::EvalJs(Contents(), "document.hasFocus()").ExtractBool();
    }));
  }
  // A key equivalent as AppKit routes it: the key window first, then the main
  // menu's matching item, validated and sent to the window.
  void PressKeyEquivalent(ui::KeyboardCode key, NSUInteger flags) {
    NSEvent* event = MakeCurrent(cocoa_test_event_utils::SynthesizeKeyEvent(
        NativeWindow(), true, key, flags));
    if (![NativeWindow() performKeyEquivalent:event]) {
      NSMenuItem* item =
          [[NSApp mainMenu] cr_menuItemForKeyEquivalentEvent:event];
      if (item && [NativeWindow() validateUserInterfaceItem:item]) {
        [NSApp sendAction:item.action to:NativeWindow() from:item];
      }
    }
  }
  // Types "k" into the page and waits until the page has handled it, so every
  // key sent before it has reached the page too.
  void WaitForPageKeys() {
    const int markers = content::EvalJs(Contents(), "markers").ExtractInt();
    [NativeWindow() sendEvent:cocoa_test_event_utils::SynthesizeKeyEvent(
                                  NativeWindow(), true, ui::VKEY_K, 0)];
    [NativeWindow() sendEvent:cocoa_test_event_utils::SynthesizeKeyEvent(
                                  NativeWindow(), false, ui::VKEY_K, 0)];
    ASSERT_TRUE(base::test::RunUntil([&] {
      return content::EvalJs(Contents(), "markers").ExtractInt() > markers;
    }));
  }
  size_t Tabs() {
    return FindBrowser(window_)->GetTabStripModel()->count();
  }
};

IN_PROC_BROWSER_TEST_F(BarkHostCommandBrowserTest, EnabledMenuItemsExecute) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  std::set<int> commands;
  CollectMenuCommands([NSApp mainMenu], &commands);
  ASSERT_TRUE(commands.contains(IDC_SAVE_PAGE));
  std::vector<int> refused;
  for (int command : commands) {
    if (Validate(command)->enable && !WillExecute(command, false)) {
      refused.push_back(command);
    }
  }
  EXPECT_THAT(refused, testing::IsEmpty());
}

IN_PROC_BROWSER_TEST_F(BarkHostCommandBrowserTest,
                       UnofferedCommandsAreHiddenAndRefused) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  for (int command : kUnofferedCommands) {
    SCOPED_TRACE(command);
    auto result = Validate(command);
    EXPECT_FALSE(result->enable);
    EXPECT_TRUE(result->set_hidden_state);
    EXPECT_TRUE(result->new_hidden_state);
    EXPECT_FALSE(WillExecute(command, false));
  }
  NSMenuItem* bookmark = MenuItemWithTag([NSApp mainMenu], IDC_BOOKMARK_THIS_TAB);
  ASSERT_TRUE(bookmark);
  EXPECT_FALSE([NativeWindow() validateUserInterfaceItem:bookmark]);
  EXPECT_TRUE(bookmark.hidden);
  NSMenuItem* save = MenuItemWithTag([NSApp mainMenu], IDC_SAVE_PAGE);
  ASSERT_TRUE(save);
  EXPECT_TRUE([NativeWindow() validateUserInterfaceItem:save]);
  EXPECT_FALSE(save.hidden);
}

IN_PROC_BROWSER_TEST_F(BarkHostCommandBrowserTest,
                       ContextMenuOmitsUnofferedItems) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&ServeKeys));
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/keys");
  const GURL page = Contents()->GetLastCommittedURL();
  const GURL link = embedded_test_server()->GetURL("/title1.html");
  struct Case {
    const char* name;
    content::ContextMenuParams params;
    std::vector<int> kept;
  };
  std::vector<Case> cases;
  {
    Case c{"page", {}, {IDC_SAVE_PAGE, IDC_CONTENT_CONTEXT_INSPECTELEMENT}};
    c.params.page_url = page;
    cases.push_back(std::move(c));
  }
  {
    Case c{"link",
           {},
           {IDC_CONTENT_CONTEXT_COPYLINKLOCATION, IDC_CONTENT_CONTEXT_SAVELINKAS,
            IDC_CONTENT_CONTEXT_INSPECTELEMENT}};
    c.params.page_url = page;
    c.params.link_url = link;
    c.params.unfiltered_link_url = link;
    c.params.link_text = u"link";
    cases.push_back(std::move(c));
  }
  {
    Case c{"image",
           {},
           {IDC_CONTENT_CONTEXT_SAVEIMAGEAS, IDC_CONTENT_CONTEXT_INSPECTELEMENT}};
    c.params.page_url = page;
    c.params.media_type = blink::mojom::ContextMenuDataMediaType::kImage;
    c.params.src_url = embedded_test_server()->GetURL("/image.png");
    c.params.has_image_contents = true;
    cases.push_back(std::move(c));
  }
  {
    Case c{"selection", {}, {IDC_CONTENT_CONTEXT_INSPECTELEMENT}};
    c.params.page_url = page;
    c.params.selection_text = u"keys";
    cases.push_back(std::move(c));
  }
  for (auto& c : cases) {
    SCOPED_TRACE(c.name);
    TestRenderViewContextMenu menu(*Contents()->GetPrimaryMainFrame(),
                                   c.params);
    menu.Init();
    const ui::SimpleMenuModel& model = menu.menu_model();
    std::set<int> ids;
    for (size_t i = 0; i < model.GetItemCount(); ++i) {
      const bool separator =
          model.GetTypeAt(i) == ui::MenuModel::TYPE_SEPARATOR;
      if (separator) {
        EXPECT_NE(0u, i);
        EXPECT_NE(model.GetItemCount() - 1, i);
        EXPECT_FALSE(i > 0 &&
                     model.GetTypeAt(i - 1) == ui::MenuModel::TYPE_SEPARATOR)
            << i;
        continue;
      }
      ids.insert(model.GetCommandIdAt(i));
      EXPECT_FALSE(Unoffered(model.GetCommandIdAt(i)))
          << model.GetCommandIdAt(i);
    }
    for (int kept : c.kept) {
      EXPECT_TRUE(ids.contains(kept)) << kept;
    }
  }
}

IN_PROC_BROWSER_TEST_F(BarkHostCommandBrowserTest,
                       ReservedAppKeyNeverReachesThePage) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&ServeKeys));
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/keys");
  FocusPage();
  const size_t tabs = Tabs();
  PressKeyEquivalent(ui::VKEY_T, NSEventModifierFlagCommand);
  WaitForPageKeys();
  EXPECT_EQ(0, content::EvalJs(Contents(), "newTabKeys").ExtractInt());
  EXPECT_EQ(tabs, Tabs());
}

IN_PROC_BROWSER_TEST_F(BarkHostCommandBrowserTest,
                       AppOwnedKeyDoesNotRunChromiumsCommand) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&ServeKeys));
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/keys");
  FocusPage();
  const size_t tabs = Tabs();
  PressKeyEquivalent(ui::VKEY_T, NSEventModifierFlagCommand);
  PressKeyEquivalent(ui::VKEY_W, NSEventModifierFlagCommand);
  PressKeyEquivalent(ui::VKEY_T,
                     NSEventModifierFlagCommand | NSEventModifierFlagShift);
  WaitForPageKeys();
  EXPECT_EQ(tabs, Tabs());
  EXPECT_FALSE(Contents()->IsBeingDestroyed());
}

// Another window has the keys while the page goes to another site, which
// gives it a new view; the page has the keys again when its window does. Typed
// keys are checked with real key windows in the focus tests.
IN_PROC_BROWSER_TEST_F(BarkHostCommandBrowserTest,
                       PageKeepsTheKeysWhenItsViewIsReplacedMeanwhile) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&ServeKeys));
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/keys");
  FocusPage();
  NSWindow* other =
      [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100)
                                  styleMask:NSWindowStyleMaskTitled
                                    backing:NSBackingStoreBuffered
                                      defer:NO];
  other.releasedWhenClosed = NO;
  [other makeKeyAndOrderFront:nil];
  ASSERT_TRUE(base::test::RunUntil([&] { return !NativeWindow().isKeyWindow; }));
  NSView* before =
      Contents()->GetRenderWidgetHostView()->GetNativeView().GetNativeNSView();
  ASSERT_TRUE(content::NavigateToURL(
      Contents(), embedded_test_server()->GetURL("b.test", "/keys")));
  NSView* after =
      Contents()->GetRenderWidgetHostView()->GetNativeView().GetNativeNSView();
  ASSERT_NE(before, after);
  Window()->Activate();
  ASSERT_TRUE(base::test::RunUntil([&] { return NativeWindow().isKeyWindow; }));
  // Closed once it is no longer key, so AppKit picks no other key window.
  [other close];
  EXPECT_TRUE(base::test::RunUntil(
      [&] { return NativeWindow().firstResponder == after; }));
  EXPECT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(Contents(), "document.hasFocus()").ExtractBool();
  }));
}

IN_PROC_BROWSER_TEST_F(BarkHostCommandBrowserTest, MenuCloseTabOnPinnedTab) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  const int32_t second = barc_tab_create(
      window_, embedded_test_server()->GetURL("/title2.html").spec().c_str(),
      1);
  ASSERT_NE(0, second);
  // A page's commit clears its toasts; let the new tab's commit come first.
  ASSERT_TRUE(content::WaitForLoadStop(TabContents(second)));
  TabStripModel* tabs = FindBrowser(window_)->GetTabStripModel();
  ASSERT_EQ(2, tabs->count());
  tabs->SetTabPinned(tabs->active_index(), true);
  NSMenuItem* close = MenuItemWithTag([NSApp mainMenu], IDC_CLOSE_TAB);
  ASSERT_TRUE(close);
  ASSERT_TRUE([NativeWindow() validateUserInterfaceItem:close]);
  // A menu click: Chromium asks before closing a pinned tab.
  [NSApp sendAction:close.action to:NativeWindow() from:close];
  auto* toasts = ToastController::From(FindBrowser(window_));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return toasts->GetCurrentToastId() == ToastId::kClosePinnedTab;
  }));
  EXPECT_EQ(2, tabs->count());
  [NSApp sendAction:close.action to:NativeWindow() from:close];
  EXPECT_TRUE(base::test::RunUntil([&] { return tabs->count() == 1; }));
}

namespace {

class UninstallDone : public extensions::ExtensionUninstallDialog::Delegate {
 public:
  void OnExtensionUninstallDialogClosed(bool started,
                                        const std::u16string&) override {
    ++calls;
    result.SetValue(started);
  }
  int calls = 0;
  base::test::TestFuture<bool> result;
};

}  // namespace

class BarkHostExtensionDialogBrowserTest : public BarkHostStockUiBrowserTest {
 protected:
  // Visible window-modal dialogs on the host window.
  std::vector<views::Widget*> ModalDialogs() {
    std::vector<views::Widget*> dialogs;
    for (views::Widget* widget : views::Widget::GetAllOwnedWidgets(
             Window()->host()->widget()->GetNativeView())) {
      if (widget->IsVisible() && widget->widget_delegate() &&
          widget->widget_delegate()->GetModalType() ==
              ui::mojom::ModalType::kWindow) {
        dialogs.push_back(widget);
      }
    }
    return dialogs;
  }
  views::Widget* WaitForModalDialog() {
    if (!base::test::RunUntil([&] { return !ModalDialogs().empty(); })) {
      return nullptr;
    }
    return ModalDialogs().front();
  }
  scoped_refptr<const extensions::Extension> AddExtension(const char* name) {
    auto extension = extensions::ExtensionBuilder(name).Build();
    extensions::ExtensionRegistrar::Get(Profile())->AddExtension(
        extension.get());
    return extension;
  }
  ::Profile* Profile() { return FindBrowser(window_)->GetProfile(); }
  bool Installed(const extensions::Extension& extension) {
    return extensions::ExtensionRegistry::Get(Profile())
        ->enabled_extensions()
        .Contains(extension.id());
  }
};

IN_PROC_BROWSER_TEST_F(BarkHostExtensionDialogBrowserTest,
                       ExtensionUninstallDialogShowsInHostWindow) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  auto extension = AddExtension("Host uninstall");
  UninstallDone done;
  // What Manage Extensions > Remove runs.
  auto dialog = extensions::ExtensionUninstallDialog::CreateForBrowser(
      Profile(), FindBrowser(window_), &done);
  dialog->ConfirmUninstall(extension, extensions::UNINSTALL_REASON_FOR_TESTING,
                           extensions::UNINSTALL_SOURCE_FOR_TESTING);
  views::Widget* prompt = WaitForModalDialog();
  ASSERT_TRUE(prompt);
  EXPECT_FALSE(done.result.IsReady());
  prompt->widget_delegate()->AsDialogDelegate()->AcceptDialog();
  EXPECT_TRUE(done.result.Get());
  EXPECT_EQ(1, done.calls);
  EXPECT_FALSE(Installed(*extension));
  EXPECT_TRUE(base::test::RunUntil([&] { return ModalDialogs().empty(); }));
}

IN_PROC_BROWSER_TEST_F(BarkHostExtensionDialogBrowserTest,
                       RefusedUninstallCancelsWithoutCrash) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  // A second profile's client in the same window.
  base::test::TestFuture<barc_profile_status, int32_t> opened;
  barc_profile_open_in_native_window(
      window_, "3c9e7a51-2b6d-4f80-9e1a-7d5c3b2a1f04", BARC_PROFILE_BLANK,
      [](barc_profile_status status, int32_t window, void* data) {
        static_cast<base::test::TestFuture<barc_profile_status, int32_t>*>(data)
            ->SetValue(status, window);
      },
      &opened);
  ASSERT_EQ(BARC_PROFILE_OK, opened.Get<0>());
  const int32_t other = opened.Get<1>();
  ASSERT_EQ(Window()->host(),
            bark::BarkBrowserWindow::FromBrowser(FindBrowser(other))->host());
  ASSERT_EQ(1, barc_window_select(window_));
  auto extension = AddExtension("Refused uninstall");
  UninstallDone done;
  auto dialog = extensions::ExtensionUninstallDialog::CreateForBrowser(
      Profile(), FindBrowser(window_), &done);
  // The owner loses the window just before its prompt would show.
  auto select_other =
      base::BindLambdaForTesting([&] { barc_window_select(other); });
  extensions::ExtensionUninstallDialog::SetOnShownCallbackForTesting(
      &select_other);
  base::ScopedClosureRunner reset(base::BindOnce([] {
    extensions::ExtensionUninstallDialog::SetOnShownCallbackForTesting(nullptr);
  }));
  dialog->ConfirmUninstall(extension, extensions::UNINSTALL_REASON_FOR_TESTING,
                           extensions::UNINSTALL_SOURCE_FOR_TESTING);
  EXPECT_FALSE(done.result.Get());
  EXPECT_EQ(1, done.calls);
  EXPECT_TRUE(ModalDialogs().empty());
  EXPECT_TRUE(Installed(*extension));
}

IN_PROC_BROWSER_TEST_F(BarkHostExtensionDialogBrowserTest,
                       PostInstallDialogShowsAndClosesInHostWindow) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  // The host window is then the profile's only tabbed window, the one the
  // install UI picks.
  CloseBrowserSynchronously(browser());
  auto extension = extensions::ExtensionBuilder("Host install").Build();
  ExtensionInstallUIDesktop install_ui(Profile());
  install_ui.OnInstallSuccess(extension, nullptr);
  extensions::ExtensionRegistrar::Get(Profile())->AddExtension(extension.get());
  views::Widget* added = WaitForModalDialog();
  ASSERT_TRUE(added);
  added->Close();
  EXPECT_TRUE(base::test::RunUntil([&] { return ModalDialogs().empty(); }));
  content::RunAllTasksUntilIdle();
  EXPECT_TRUE(Installed(*extension));
}

IN_PROC_BROWSER_TEST_F(BarkHostCommandBrowserTest, CastHasNoEntryPoint) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  EXPECT_FALSE(media_router::MediaRouterEnabled(FindBrowser(window_)->GetProfile()));
  content::ContextMenuParams params;
  params.page_url = Contents()->GetLastCommittedURL();
  TestRenderViewContextMenu menu(*Contents()->GetPrimaryMainFrame(), params);
  menu.Init();
  EXPECT_FALSE(menu.menu_model().GetIndexOfCommandId(IDC_ROUTE_MEDIA));
  auto result = Validate(IDC_ROUTE_MEDIA);
  EXPECT_FALSE(result->enable);
  EXPECT_TRUE(result->new_hidden_state);
  const auto widgets = views::test::WidgetTest::GetAllWidgets();
  // A page can ask for a cast session without any menu.
  EXPECT_NE("started",
            content::EvalJs(Contents(),
                            "new PresentationRequest('https://example.com/cast')"
                            "  .start().then(() => 'started', e => e.name)"));
  content::RunAllTasksUntilIdle();
  for (const auto& widget : views::test::WidgetTest::GetAllWidgets()) {
    EXPECT_TRUE(widgets.contains(widget));
  }
}

IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest,
                       DockRequestLeavesDevToolsUndocked) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  DevToolsWindow* devtools =
      DevToolsWindowTesting::OpenDevToolsWindowSync(Contents(), false);
  ASSERT_TRUE(devtools);
  // What Cmd+Shift+D in DevTools and its dock-side menu send.
  EXPECT_TRUE(content::ExecJs(
      DevToolsWindowTesting::Get(devtools)->main_web_contents(),
      "new Promise(done => InspectorFrontendHost.setIsDocked(true, done))"));
  EXPECT_FALSE(devtools->IsDocked());
  DevToolsWindowTesting::CloseDevToolsWindowSync(devtools);
}

namespace {

class NoColor : public content::EyeDropperListener {
 public:
  void ColorSelected(SkColor color) override {}
  void ColorSelectionCanceled() override {}
};

}  // namespace

IN_PROC_BROWSER_TEST_F(BarkHostStockUiBrowserTest, EyeDropperOpens) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  NoColor listener;
  // What `new EyeDropper().open()` asks the page's window for.
  std::unique_ptr<content::EyeDropper> dropper =
      Window()->OpenEyeDropper(Contents()->GetPrimaryMainFrame(), &listener);
  EXPECT_TRUE(dropper);
}

class BarkHostNarrowWindowBrowserTest : public BarkHostStockUiBrowserTest {
 protected:
  // Makes the window `width` wide and puts the page, `page_width` wide, at its
  // trailing edge, as the sidebar layout does.
  void Narrow(int width, CGFloat page_width) {
    views::Widget* host = Window()->host()->widget();
    gfx::Rect bounds = host->GetWindowBoundsInScreen();
    bounds.set_width(width);
    host->SetBounds(bounds);
    ASSERT_TRUE(base::test::RunUntil(
        [&] { return NSWidth(root_.bounds) == width; }));
    page_.frame = NSMakeRect(NSWidth(root_.bounds) - page_width - 10, 10,
                             page_width, NSHeight(root_.bounds) - 20);
    ASSERT_TRUE(base::test::RunUntil([&] {
      return Window()->GetPageBoundsInScreen().width() == page_width;
    }));
  }
  gfx::Rect ClientArea() {
    return Window()->host()->widget()->GetClientAreaBoundsInScreen();
  }
  // The visible tab-modal dialog on the host window.
  views::Widget* WaitForTabModal() {
    views::Widget* dialog = nullptr;
    EXPECT_TRUE(base::test::RunUntil([&] {
      for (views::Widget* widget : views::Widget::GetAllOwnedWidgets(
               Window()->host()->widget()->GetNativeView())) {
        // A dismissed dialog stays visible while it closes.
        if (widget->IsVisible() && !widget->IsClosed() &&
            widget->widget_delegate() &&
            widget->widget_delegate()->GetModalType() ==
                ui::mojom::ModalType::kChild) {
          dialog = widget;
          return true;
        }
      }
      return false;
    }));
    return dialog;
  }
  views::Widget* Alert() {
    content::ExecuteScriptAsync(
        Contents(), "alert('A message long enough to need the whole dialog')");
    return WaitForTabModal();
  }
  void Dismiss(views::Widget* dialog) {
    views::test::WidgetDestroyedWaiter closed(dialog);
    dialog->widget_delegate()->AsDialogDelegate()->AcceptDialog();
    closed.Wait();
  }
};

IN_PROC_BROWSER_TEST_F(BarkHostNarrowWindowBrowserTest,
                       TabModalDialogStaysInsideANarrowWindow) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  for (CGFloat page_width : {135.0, 60.0}) {
    SCOPED_TRACE(page_width);
    Narrow(560, page_width);
    views::Widget* alert = Alert();
    ASSERT_TRUE(alert);
    gfx::Rect inside = ClientArea();
    inside.Inset(8);
    EXPECT_TRUE(inside.Contains(alert->GetWindowBoundsInScreen()))
        << inside.ToString() << " " << alert->GetWindowBoundsInScreen().ToString();
    Dismiss(alert);
  }
  Narrow(1200, 900);
  views::Widget* alert = Alert();
  ASSERT_TRUE(alert);
  const gfx::Rect page = Window()->GetPageBoundsInScreen();
  const gfx::Rect frame = alert->GetWindowBoundsInScreen();
  EXPECT_LE(std::abs(frame.CenterPoint().x() - page.CenterPoint().x()), 1)
      << page.ToString() << " " << frame.ToString();
  EXPECT_EQ(page.y(), frame.y());
  Dismiss(alert);
}

IN_PROC_BROWSER_TEST_F(BarkHostNarrowWindowBrowserTest,
                       PermissionPromptStaysInsideANarrowWindow) {
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/title1.html");
  Narrow(560, 135);
  permissions::PermissionRequestObserver shown(Contents());
  content::ExecuteScriptAsync(Contents(),
                              "navigator.geolocation.getCurrentPosition("
                              "  () => {}, () => {});");
  shown.Wait();
  auto* prompt = WaitForBubble();
  ASSERT_NE(nullptr, prompt);
  EXPECT_TRUE(ClientArea().Contains(prompt->GetWidget()->GetWindowBoundsInScreen()))
      << ClientArea().ToString() << " "
      << prompt->GetWidget()->GetWindowBoundsInScreen().ToString();
}

namespace {

constexpr char kKeysScript[] =
    "<script>window.markers = 0;"
    "addEventListener('keydown', e => { if (e.key === 'k') markers++; });"
    "</script>";

std::unique_ptr<net::test_server::HttpResponse> ServeAuth(
    const net::test_server::HttpRequest& request) {
  if (request.relative_url != "/auth") {
    return nullptr;
  }
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_code(net::HTTP_UNAUTHORIZED);
  response->AddCustomHeader("WWW-Authenticate", "Basic realm=\"bark\"");
  response->set_content_type("text/html");
  response->set_content(std::string("<title>denied</title>") + kKeysScript);
  return response;
}

}  // namespace

// Real key-window changes, as in interactive UI tests; each case runs in its
// own test process.
class BarkHostFocusBrowserTest : public BarkHostNarrowWindowBrowserTest {
 public:
  void SetUp() override {
    ui_controls::EnableUIControls();
    ASSERT_TRUE(ui_controls::IsUIControlsEnabled());
    BarkHostNarrowWindowBrowserTest::SetUp();
  }
  void SetUpOnMainThread() override {
    BarkHostNarrowWindowBrowserTest::SetUpOnMainThread();
    host_resolver()->AddRule("*", "127.0.0.1");
  }

 protected:
  NSWindow* NativeWindow() {
    return Window()->GetNativeWindow().GetNativeNSWindow();
  }
  void MakeKey() {
    [NSApp activateIgnoringOtherApps:YES];
    Window()->Activate();
    ASSERT_TRUE(base::test::RunUntil([&] { return NativeWindow().isKeyWindow; }));
  }
  void FocusPage() {
    Contents()->Focus();
    ASSERT_TRUE(base::test::RunUntil([&] {
      return content::EvalJs(Contents(), "document.hasFocus()").ExtractBool();
    }));
  }
  // Types "k" into the key window and reports whether the page heard it.
  bool PageHearsAKey() {
    const int markers = content::EvalJs(Contents(), "markers").ExtractInt();
    EXPECT_TRUE(ui_controls::SendKeyPress(Window()->GetNativeWindow(),
                                          ui::VKEY_K, false, false, false,
                                          false));
    return base::test::RunUntil([&] {
      return content::EvalJs(Contents(), "markers").ExtractInt() > markers;
    });
  }
};

IN_PROC_BROWSER_TEST_F(BarkHostFocusBrowserTest,
                       KeysReturnToThePageAfterHttpAuth) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&ServeAuth));
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&ServeKeys));
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/keys");
  MakeKey();
  FocusPage();
  ASSERT_TRUE(PageHearsAKey());
  content::ExecuteScriptAsync(Contents(), "location.href = '/auth'");
  views::Widget* sign_in = WaitForTabModal();
  ASSERT_TRUE(sign_in);
  ASSERT_TRUE(base::test::RunUntil([&] { return sign_in->IsActive(); }));
  // Cancel, as the person presses Esc in the dialog.
  views::test::WidgetDestroyedWaiter closed(sign_in);
  ASSERT_TRUE(ui_controls::SendKeyPress(sign_in->GetNativeWindow(),
                                        ui::VKEY_ESCAPE, false, false, false,
                                        false));
  closed.Wait();
  ASSERT_TRUE(content::WaitForLoadStop(Contents()));
  ASSERT_EQ(u"denied", Contents()->GetTitle());
  // The page has the keys again once its document has the focus.
  ASSERT_TRUE(base::test::RunUntil([&] {
    return NativeWindow().isKeyWindow &&
           content::EvalJs(Contents(), "document.hasFocus()").ExtractBool();
  }));
  EXPECT_TRUE(PageHearsAKey());
}

IN_PROC_BROWSER_TEST_F(BarkHostFocusBrowserTest,
                       KeysReturnToASidebarFieldThatHadThem) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&ServeAuth));
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&ServeKeys));
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/keys");
  // The app's address field, beside the page in the window's root view.
  NSTextField* field =
      [[NSTextField alloc] initWithFrame:NSMakeRect(10, 10, 200, 24)];
  [root_ addSubview:field];
  MakeKey();
  ASSERT_TRUE([NativeWindow() makeFirstResponder:field]);
  content::ExecuteScriptAsync(Contents(), "location.href = '/auth'");
  views::Widget* sign_in = WaitForTabModal();
  ASSERT_TRUE(sign_in);
  ASSERT_TRUE(base::test::RunUntil([&] { return sign_in->IsActive(); }));
  views::test::WidgetDestroyedWaiter closed(sign_in);
  ASSERT_TRUE(ui_controls::SendKeyPress(sign_in->GetNativeWindow(),
                                        ui::VKEY_ESCAPE, false, false, false,
                                        false));
  closed.Wait();
  ASSERT_TRUE(content::WaitForLoadStop(Contents()));
  ASSERT_TRUE(base::test::RunUntil([&] { return NativeWindow().isKeyWindow; }));
  ASSERT_TRUE(ui_controls::SendKeyPress(Window()->GetNativeWindow(), ui::VKEY_K,
                                        false, false, false, false));
  EXPECT_TRUE(base::test::RunUntil(
      [&] { return [field.stringValue isEqualToString:@"k"]; }));
  EXPECT_EQ(0, content::EvalJs(Contents(), "markers").ExtractInt());
}

IN_PROC_BROWSER_TEST_F(BarkHostFocusBrowserTest,
                       KeysReturnToThePageAfterPrintPreview) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&ServeKeys));
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/keys");
  MakeKey();
  FocusPage();
  ASSERT_TRUE(PageHearsAKey());
  chrome::ExecuteCommand(FindBrowser(window_), IDC_PRINT);
  views::Widget* preview = WaitForTabModal();
  ASSERT_TRUE(preview);
  content::WebContents* preview_page = nullptr;
  ASSERT_TRUE(base::test::RunUntil([&] {
    preview_page = printing::PrintPreviewDialogController::GetInstance()
                       ->GetPrintPreviewForContents(Contents());
    return preview_page && !preview_page->IsLoading();
  }));
  ASSERT_TRUE(base::test::RunUntil([&] { return preview->IsActive(); }));
  views::test::WidgetDestroyedWaiter closed(preview);
  // Esc, as print preview's own page handles it.
  ASSERT_TRUE(ui_controls::SendKeyPress(preview->GetNativeWindow(),
                                        ui::VKEY_ESCAPE, false, false, false,
                                        false));
  closed.Wait();
  ASSERT_TRUE(base::test::RunUntil([&] { return NativeWindow().isKeyWindow; }));
  EXPECT_TRUE(PageHearsAKey());
}

IN_PROC_BROWSER_TEST_F(BarkHostFocusBrowserTest,
                       KeysStayWithThePageWhenAnotherWindowHadThem) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&ServeKeys));
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/keys");
  MakeKey();
  FocusPage();
  ASSERT_TRUE(PageHearsAKey());
  NSWindow* other =
      [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100)
                                  styleMask:NSWindowStyleMaskTitled
                                    backing:NSBackingStoreBuffered
                                      defer:NO];
  other.releasedWhenClosed = NO;
  [other makeKeyAndOrderFront:nil];
  ASSERT_TRUE(base::test::RunUntil([&] { return !NativeWindow().isKeyWindow; }));
  [other close];
  MakeKey();
  EXPECT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(Contents(), "document.hasFocus()").ExtractBool();
  }));
  EXPECT_TRUE(PageHearsAKey());
}

IN_PROC_BROWSER_TEST_F(BarkHostFocusBrowserTest, ClickReachesThePlacedPage) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&ServeKeys));
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/keys");
  MakeKey();
  // The middle of the page, clear of its link.
  const gfx::Point point = Window()->GetPageBoundsInScreen().CenterPoint();
  base::test::TestFuture<void> moved;
  ASSERT_TRUE(ui_controls::SendMouseMoveNotifyWhenDone(
      point.x(), point.y(), moved.GetCallback(), Window()->GetNativeWindow()));
  ASSERT_TRUE(moved.Wait());
  base::test::TestFuture<void> clicked;
  ASSERT_TRUE(ui_controls::SendMouseEventsNotifyWhenDone(
      ui_controls::LEFT, ui_controls::DOWN | ui_controls::UP,
      clicked.GetCallback(), ui_controls::kNoAccelerator,
      Window()->GetNativeWindow()));
  ASSERT_TRUE(clicked.Wait());
  EXPECT_TRUE(base::test::RunUntil(
      [&] { return content::EvalJs(Contents(), "clicks").ExtractInt() == 1; }));
}

IN_PROC_BROWSER_TEST_F(BarkHostFocusBrowserTest,
                       KeysFollowThePageWhenItsViewIsReplaced) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(&ServeKeys));
  ASSERT_TRUE(embedded_test_server()->Start());
  OpenPlacedPage("/keys");
  MakeKey();
  FocusPage();
  ASSERT_TRUE(PageHearsAKey());
  NSWindow* other =
      [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100)
                                  styleMask:NSWindowStyleMaskTitled
                                    backing:NSBackingStoreBuffered
                                      defer:NO];
  other.releasedWhenClosed = NO;
  [other makeKeyAndOrderFront:nil];
  ASSERT_TRUE(base::test::RunUntil([&] { return !NativeWindow().isKeyWindow; }));
  NSView* before =
      Contents()->GetRenderWidgetHostView()->GetNativeView().GetNativeNSView();
  ASSERT_TRUE(content::NavigateToURL(
      Contents(), embedded_test_server()->GetURL("b.test", "/keys")));
  ASSERT_NE(before, Contents()
                        ->GetRenderWidgetHostView()
                        ->GetNativeView()
                        .GetNativeNSView());
  MakeKey();
  [other close];
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(Contents(), "document.hasFocus()").ExtractBool();
  }));
  EXPECT_TRUE(PageHearsAKey());
}
