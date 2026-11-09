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
 }
}
