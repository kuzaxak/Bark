// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookSettings
import NookBlocker
import NookTweaks
import NookTabsCore
@testable import NookWeb
private struct NoToken: KagiTokenStore {func load()->String? {nil};func save(_ token:String?) {}}
@main struct Ownership {
 @MainActor static func main() async throws {
  let name="NativeLiveOwnership-\(UUID())",root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let defaults=UserDefaults(suiteName:name)!
  defer {defaults.removePersistentDomain(forName:name);try? FileManager.default.removeItem(at:root)}
  let settings=NookSettingsService(kagiTokenStore:NoToken(),userDefaults:defaults,boostStore:BoostStore(fileURL:root.appendingPathComponent("Boosts.json")))
  let registry=WindowRegistry()
  let tabs=TabsController(settings:settings,windowRegistry:registry,blocker:ContentBlockerManager(settings:settings),
   sponsorBlock:SponsorBlockManager(settings:settings),siteRouting:SiteRoutingManager(settings:settings),profileEngine:.chromium,directory:root.appendingPathComponent("Tabs"))
  let work=tabs.tree.orderedSpaces.first!.id
  let personal=tabs.createSpace(name:"Personal",icon:"",accentHex:"#123456",after:work)!
  let a=tabs.tree.dataStoreID(for:work)!,b=tabs.tree.dataStoreID(for:personal)!
  let pr=UUID(),mail=UUID()
  _=tabs.perform(.main,"createPreviewFixtures",undoable:false) {try $0.createTab(id:pr,url:URL(string:"https://github.com/synthetic/repo")!,title:"GitHub",in:.favorites(spaceID:work),after:nil)}
  _=tabs.perform(.main,"createMailFixture",undoable:false) {try $0.createTab(id:mail,url:GoogleFavorite.mailFeed(account:0),title:"Gmail",in:.favorites(spaceID:work),after:nil)}
  let window=BrowserWindowState();window.spaceID=work;registry.register(window)
  var requests:[UUID]=[]
  tabs.nativeLiveFetch={profile,source in
   precondition(source == .githubPulls);requests.append(profile)
   let title=profile == a ? "Owned A":"Owned B"
   let data=Data("{\"payload\":{\"pullsDashboardSurfaceContentRoute\":{\"results\":[{\"permalink\":\"https://github.com/synthetic/repo/pull/1\",\"title\":\"\(title)\"}]}}}".utf8)
   return ProfileLiveResponse(data:data,status:200)
  }
  let preview=PreviewOwnership()
  let item=tabs.item(pr)!
  let first=await preview.load(item,tabs:tabs)
  precondition(first.first?.title == "Owned A" && requests == [a])
  _=await preview.load(item,tabs:tabs);precondition(requests == [a])
  preview.itemID=pr;preview.windowID=window.id;preview.source=PreviewOwnership.source(for:item,tabs:tabs)
  precondition(preview.isCurrent(in:window,tabs:tabs))
  let live=MailOwnership();live.tabs=tabs
  live.mail[mail] = .init(outcome:.inbox(.init(unread:3,messages:[])),at:Date(),spaceID:work,profileID:a,account:0)
  precondition(live.mailOutcome(mail,account:0) != nil)
  _=tabs.perform(.main,"reassignPreview",undoable:false){try $0.setProfile(work,to:b)}
  precondition(!preview.isCurrent(in:window,tabs:tabs) && live.mailOutcome(mail,account:0) == nil)
  let second=await preview.load(item,tabs:tabs)
  precondition(second.first?.title == "Owned B" && requests == [a,b])
  preview.source=PreviewOwnership.source(for:item,tabs:tabs)
  precondition(preview.isCurrent(in:window,tabs:tabs))
  window.isIncognito=true;precondition(!preview.isCurrent(in:window,tabs:tabs));window.isIncognito=false
  registry.unregister(window.id);precondition(!preview.isCurrent(in:window,tabs:tabs))
  precondition(tabs.sessions.isEmpty && tabs.profile(forSpace:work)?.webKitStorage == nil)
  // Actual shipped folder and Gmail source tasks share a transport with the
  // native two-per-profile admission bound. No fake batch implementation.
  let work2=tabs.createSpace(name:"Work 2",icon:"",accentHex:"#123456",after:personal)!
  _=tabs.perform(.main,"sameProfileBatch",undoable:false){try $0.setProfile(work2,to:b)}
  let folders=[UUID(),UUID(),UUID()]
  let sources:[LiveSource]=[.githubPulls,.githubIssues,.githubNotifications]
  for (i,id) in folders.enumerated(){
   _=tabs.perform(.main,"batchFolder",undoable:false){try $0.createFolder(id:id,title:"Batch",in:.pinned(spaceID:i==2 ? work2:work),after:nil,live:sources[i])}
  }
  let mail2=UUID()
  _=tabs.perform(.main,"mailBatch",undoable:false){try $0.createTab(id:mail2,url:GoogleFavorite.mailFeed(account:1),title:"Gmail 2",in:.favorites(spaceID:work2),after:nil)}
  var pending:[CheckedContinuation<ProfileLiveResponse,Error>]=[]
  var active=0,peak=0,total=0,refusals=0
  tabs.nativeLiveFetch={profile,_ in
   precondition(profile==b)
   if active==2 {refusals+=1;throw ProfileLiveFailure.unavailable}
   active+=1;peak=max(peak,active);total+=1
   defer{active-=1}
   return try await withCheckedThrowingContinuation{pending.append($0)}
  }
  func drain() async {for _ in 0..<8 {await withCheckedContinuation{c in DispatchQueue.main.async{c.resume()}}}}
  tabs.refreshLiveFolders(inSpace:work)
  // A different-space batch and individual joins must not be discarded.
  tabs.refreshLiveFolders(inSpace:work2)
  tabs.refreshLiveFolders(inSpace:work)
  let joined=tabs.refreshLiveFolder(folders[0],force:true)
  let firstMail=live.fetchMail(mail,spaceID:work,account:0,soon:true)
  let secondMail=live.fetchMail(mail2,spaceID:work2,account:1,soon:true)
  _=live.fetchMail(mail,spaceID:work,account:0,soon:true)
  await drain();precondition(total==2 && active==2)
  var released=0
  while released<5 {
   precondition(!pending.isEmpty)
   let reply=pending.removeFirst();released+=1
   // Failure in the first source must not strand later source tasks.
   if released==1 {reply.resume(throwing:ProfileLiveFailure.failed)}
   else {reply.resume(returning:ProfileLiveResponse(data:Data(),status:302))}
   await drain()
  }
  await joined?.value;await firstMail?.value;await secondMail?.value
  precondition(total==5 && peak==2 && refusals==0 && active==0 && tabs.liveRefreshing.isEmpty)
  precondition(live.mailFetches.values.allSatisfy{$0.task==nil})
  // A queued source reassigned before its turn never uses the replacement's
  // cookies; cancel/remove clears its existing source ownership.
  tabs.refreshLiveFolder(folders[0],force:true)
  let queued=tabs.refreshLiveFolder(folders[2],force:true)
  await drain();precondition(total==6 && pending.count==1)
  _=tabs.perform(.main,"queuedReassign",undoable:false){try $0.setProfile(work2,to:a)}
  pending.removeFirst().resume(returning:ProfileLiveResponse(data:Data(),status:302))
  await queued?.value;await drain()
  precondition(total==6 && active==0 && tabs.liveRefreshing.isEmpty)
  live.mailFetches[mail]?.last = .distantPast
  live.mailFetches[mail2]?.last = .distantPast
  let cancelledMail=live.fetchMail(mail,spaceID:work,account:0,soon:true)
  let cancelledQueuedMail=live.fetchMail(mail2,spaceID:work2,account:1,soon:true)
  await drain();precondition(pending.count==1)
  live.keepMail(of:[])
  await drain()
  pending.removeFirst().resume(returning:ProfileLiveResponse(data:Data(),status:302))
  await cancelledMail?.value;await cancelledQueuedMail?.value;await drain()
  precondition(live.mailFetches.isEmpty && active==0 && tabs.liveRefreshing.isEmpty)
  print("Five-source native batches: concurrency2, overlap/space joins, failure/reassignment/cancellation passed")
  print("Live preview ownership: real model/profile reassignment rejects cached PR/mail and stale/private/closed-window presentation")
 }
}
