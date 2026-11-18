#if BARK_CATALOG_FRAMEWORK
@testable import NookNativeShell
#endif
import AppKit
import NookWeb
@main struct SavePresenterCheck {
 @MainActor static func main() {
  let manager = AutofillManager(), view = NSView(), other = NSView()
  let page = UUID()
  var first: [Bool] = [], second: [Bool] = []
  manager.offerNativeSave(host:"synthetic.invalid",username:"one",itemID:page,in:view) { first.append($0) }
  let old = manager.saveOffer!.id
  manager.offerNativeSave(host:"synthetic.invalid",username:"two",itemID:page,in:view) { second.append($0) }
  let current = manager.saveOffer!.id
  precondition(first == [false] && current != old)
  manager.answerSaveOffer(true,id:old)
  precondition(second.isEmpty && manager.saveOffer?.id == current)
  manager.dismissSave(in:other)
  precondition(manager.saveOffer?.id == current)
  manager.answerSaveOffer(true,id:current)
  precondition(second == [true] && manager.saveOffer == nil)
  print("PASS actual native save presenter: owned NSView, stale card ID refusal, exact consent, unrelated-view dismissal refusal")
  _ = NSApplication.shared
  let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                        styleMask: .borderless, backing: .buffered, defer: true)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  window.contentView = view
  var creation: [Bool] = []
  manager.confirmNativePasskeyCreation(rpId: "synthetic.invalid", userName: "synthetic", in: view) {
      creation.append($0)
  }
  precondition(creation == [false] && window.attachedSheet == nil && !window.isVisible)
  var pickerRefused = false
  manager.presentNativePicker(host: "synthetic.invalid", items: [], anchor: .zero, in: view,
                              validateSelection: { true }) { result in
      if case .focusUnavailable = result { pickerRefused = true }
  }
  precondition(pickerRefused && !manager.ownsNativePicker(in: view))
  print("PASS actual native passkey presenter refuses an offscreen owner without creating a sheet or picker")
 }
}
