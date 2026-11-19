// Synthetic lifecycle fixture: compile with the shipped DevMCP server lifecycle/parser,
// replacing only Network transport and app tool dispatch. No sockets or global stores.
import Foundation
// Lifecycle-only fixture: snapshot metadata holds a weak native adapter reference.
@MainActor final class ChromiumPageNavigation {}


struct NWEndpoint: Sendable {
    struct Port: Sendable { let rawValue: UInt16; init?(rawValue: UInt16) { guard rawValue != 0 else { return nil }; self.rawValue = rawValue } }
    enum Host: Sendable { case ipv4(IPv4Address) }
    enum IPv4Address: Sendable { case loopback }
    static func hostPort(host: Host, port: Port) -> Self { Self() }
}
final class NWParameters: @unchecked Sendable {
    static var tcp: NWParameters { NWParameters() }
    var requiredLocalEndpoint: NWEndpoint?
    var allowLocalEndpointReuse = false
}
final class NWListener: @unchecked Sendable {
    enum State: Sendable { case ready, cancelled }
    @MainActor static var latest: NWListener?
    var newConnectionHandler: (@Sendable (NWConnection) -> Void)?
    var stateUpdateHandler: (@Sendable (State) -> Void)?
    @MainActor init(using: NWParameters) throws { Self.latest = self }
    func start(queue: DispatchQueue) {}
    func cancel() {}
}
final class NWConnection: @unchecked Sendable {
    enum State: Sendable { case cancelled }
    enum SendCompletion { case contentProcessed(@Sendable (Error?) -> Void) }
    let lock = NSLock()
    private var callback: (@Sendable (Data?, Int?, Bool, Error?) -> Void)?
    var stateUpdateHandler: (@Sendable (State) -> Void)?
    private var cancelled = false
    private var sent = 0
    private var response: Data?
    var lastResponse: Data? { lock.withLock { response } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
    var sends: Int { lock.withLock { sent } }
    func start(queue: DispatchQueue) {}
    func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping @Sendable (Data?, Int?, Bool, Error?) -> Void) {
        lock.withLock { callback = completion }
    }
    func deliver(_ data: Data) { lock.withLock { let result = callback; callback = nil; return result }?(data, nil, false, nil) }
    func cancel() { lock.withLock { cancelled = true }; stateUpdateHandler?(.cancelled) }
    func send(content: Data, completion: SendCompletion) {
        lock.withLock { sent += 1; response = content }
        if case .contentProcessed(let done) = completion { done(nil) }
    }
}
@MainActor final class BrowserManager {
    let tabs = Tabs()
    var nookSettings: Settings? = Settings()
    final class Settings { var developerModeEnabled = true; var browserControlServerEnabled = true }
    final class Tabs { var agentCallsInFlight = 0 }
    func closeIdleAgentTabs() { idleCloses += 1 }
    var idleCloses = 0
}
@MainActor enum TestTools {
    static var started = 0
    static var cancelled = 0
    static func call() async -> [String: Any] {
        started += 1
        do { try await Task.sleep(for: .seconds(60)) } catch { cancelled += 1 }
        return ["done": true]
    }
}

actor NativeFileFixture {
    var active=0, peak=0, calls=0
    var first:[CheckedContinuation<Void,Never>]=[]
    private var held:[CheckedContinuation<Void,Never>]=[]
    private var hold:Bool
    nonisolated let ready=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingOldest(1))
    init(hold:Bool=false){self.hold=hold}
    func release(){hold=false;let all=held;held=[];all.forEach{$0.resume()}}
    func fetch(_ url:URL,_ dir:URL) async throws -> DevMCPDownload.NativeFile {
        calls+=1;active+=1;peak=max(peak,active)
        defer{active-=1}
        if calls<=6 {await withCheckedContinuation{c in first.append(c);if first.count==6 {let all=first;first=[];all.forEach{$0.resume()}}}}
        if hold {await withCheckedContinuation{c in held.append(c);if held.count==6{ready.continuation.yield(())}}}
        try Task.checkCancellation()
        if url.lastPathComponent=="http.bin" {return .init(temporary:nil,status:"http",httpStatus:403,contentType:"text/plain",bytes:0)}
        if url.lastPathComponent=="large.bin" {return .init(temporary:nil,status:"tooLarge",httpStatus:200,contentType:"text/plain",bytes:104_923_136)}
        let temporary=dir.appendingPathComponent(".devmcp-"+UUID().uuidString)
        try Data("new".utf8).write(to:temporary)
        return .init(temporary:DevMCPTemporaryFile(url:temporary,directoryDescriptor:open(dir.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC)),status:"ok",httpStatus:200,contentType:"application/octet-stream",bytes:3)
    }
}
@main struct DevMCPCheck {
    @MainActor static func drain() async { for _ in 0..<40 { await Task.yield() } }
    @MainActor static func main() async throws {
        for developer in [false, true] { for control in [false, true] {
            precondition(DevMCPConfiguration.isEnabled(developerMode: developer, browserControl: control) == (developer && control))
        } }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("devmcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("App")
        let configuration = try DevMCPConfiguration.native(appRoot: app, port: 49123)
        precondition(!FileManager.default.fileExists(atPath: configuration.tokenFile.path))
        let token = try configuration.loadOrCreateToken()
        let reloaded = try configuration.loadOrCreateToken()
        precondition(reloaded == token)
        precondition(configuration.tokenFile.path.hasPrefix(app.path + "/"))
        precondition(configuration.resolve("../escape") == nil)
        precondition(configuration.resolve("inside/file") != nil)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuration.filesRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: configuration.filesRoot.appendingPathComponent("out"), withDestinationURL: outside)
        precondition(configuration.resolve("out/file") == nil)
        let substitutedApp = root.appendingPathComponent("SubstitutedApp")
        try FileManager.default.createSymbolicLink(at: substitutedApp, withDestinationURL: outside)
        do { _ = try DevMCPConfiguration.native(appRoot: substitutedApp); preconditionFailure("accepted substituted App root") } catch {}
        let lateApp = root.appendingPathComponent("LateApp")
        try FileManager.default.createDirectory(at: lateApp, withIntermediateDirectories: true)
        let lateConfiguration = try DevMCPConfiguration.native(appRoot: lateApp)
        try FileManager.default.removeItem(at: lateApp)
        try FileManager.default.createSymbolicLink(at: lateApp, withDestinationURL: outside)
        do { _ = try lateConfiguration.loadOrCreateToken(); preconditionFailure("followed replaced App root") } catch {}
        precondition(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("DevMCP").path))
        let aliasRoot = URL(fileURLWithPath: "/private/tmp/devmcp-canonical-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: aliasRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: aliasRoot) }
        let shortened = aliasRoot.resolvingSymlinksInPath()
        precondition(shortened.path.hasPrefix("/tmp/"))
        precondition(DevMCPFiles.nativeDirectory(shortened)?.path == aliasRoot.path)
        let aliasDir = shortened.appendingPathComponent("batch")
        try FileManager.default.createDirectory(at: aliasDir, withIntermediateDirectories: true)
        let aliasJob = try DevMCPDownload(urls: [URL(string:"https://synthetic.invalid/a.bin")!],
            dir: aliasDir, filesRoot: shortened, owner: NSObject(), canPublish: { true }) { url, directory in
                let canonical = DevMCPFiles.nativeDirectory(directory)!
                let temporary = canonical.appendingPathComponent(".devmcp-alias")
                try Data("alias".utf8).write(to: temporary)
                return .init(temporary: DevMCPTemporaryFile(url: temporary,
                    directoryDescriptor: open(canonical.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)),
                    status: "ok", httpStatus: 200, contentType: "text/plain", bytes: 5)
            }
        await aliasJob.run()
        precondition(aliasJob.progress.counts == ["ok": 1])
        let writingDirectory = root.appendingPathComponent("writing")
        try FileManager.default.createDirectory(at: writingDirectory, withIntermediateDirectories: true)
        let writingJob = DevMCPDownload(urls: [], dir: writingDirectory, cookies: [], userAgent: nil, referer: nil)
        let startedWrite = DispatchSemaphore(value: 0), releaseWrite = DispatchSemaphore(value: 0)
        let destination = writingDirectory.appendingPathComponent("download.bin")
        let writeTask = Task.detached {
            do {
                _ = try writingJob.store(Data("owned".utf8), at: destination) { data, temporary in
                    try data.write(to: temporary)
                    startedWrite.signal()
                    releaseWrite.wait()
                }
                return false
            } catch is CancellationError { return true } catch { return false }
        }
        // The writer stays blocked while MainActor cancellation must return immediately.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { startedWrite.wait(); continuation.resume() }
        }
        writingJob.cancel()
        try Data("another job".utf8).write(to: destination)
        releaseWrite.signal()
        let cancelledWrite = await writeTask.value
        precondition(cancelledWrite)
        let otherBytes = try String(contentsOf: destination, encoding: .utf8)
        precondition(otherBytes == "another job")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: writingDirectory.path)
        precondition(remaining == ["download.bin"], "cancelled write must remove only its owned temporary")
        let successfulJob = DevMCPDownload(urls: [], dir: writingDirectory, cookies: [], userAgent: nil, referer: nil)
        var existingWriterCalled = false
        let existing = try successfulJob.store(Data("replacement".utf8), at: destination) { _, _ in
            existingWriterCalled = true
            preconditionFailure("existing target should skip large write")
        }
        precondition(!existing && !existingWriterCalled)
        let raced = writingDirectory.appendingPathComponent("raced.bin")
        let won = try successfulJob.store(Data("ours".utf8), at: raced) { bytes, temporary in
            try bytes.write(to: temporary)
            try Data("rival".utf8).write(to: raced)
        }
        precondition(!won)
        let rival = try String(contentsOf: raced, encoding: .utf8)
        precondition(rival == "rival")
        let preserved = try String(contentsOf: destination, encoding: .utf8)
        precondition(preserved == "another job")
        let completeDestination = writingDirectory.appendingPathComponent("complete.bin")
        let committed = try successfulJob.store(Data("complete".utf8), at: completeDestination)
        precondition(committed)
        enum WriteFailure: Error { case expected }
        do {
            _ = try successfulJob.store(Data(), at: writingDirectory.appendingPathComponent("error.bin")) { _, _ in throw WriteFailure.expected }
            preconditionFailure("write error ignored")
        } catch WriteFailure.expected {}
        let finalNames = try FileManager.default.contentsOfDirectory(atPath: writingDirectory.path)
        precondition(Set(finalNames) == ["download.bin", "complete.bin", "raced.bin"])
        let nativeRoot=root.resolvingSymlinksInPath().appendingPathComponent("native-files")
        let nativeDir=nativeRoot.appendingPathComponent("batch")
        try FileManager.default.createDirectory(at:nativeDir,withIntermediateDirectories:true)
        let urls=["exists","plain","http","large","a","b","c","d"].map {URL(string:($0=="plain" ? "http":"https")+"://synthetic.invalid/"+$0+".bin")!}
        let existingTarget=nativeDir.appendingPathComponent(DevMCPFiles.fileName(for:urls[0],contentType:nil))
        try Data("rival".utf8).write(to:existingTarget)
        let browserManagerMarker=NSObject()
        let transport=NativeFileFixture()
        let nativeJob=try DevMCPDownload(urls:urls,dir:nativeDir,filesRoot:nativeRoot,owner:browserManagerMarker,canPublish:{true},nativeFetch:{try await transport.fetch($0,$1)})
        await nativeJob.run()
        let peak=await transport.peak,calls=await transport.calls
        precondition(peak==6 && calls==6)
        let nativeCounts=nativeJob.progress.counts
        precondition(nativeCounts==["exists":1,"error":1,"http":1,"tooLarge":1,"ok":4] && nativeJob.progress.finished)
        let existingBytes=try String(contentsOf:existingTarget,encoding:.utf8)
        precondition(existingBytes=="rival")
        let manifest=try String(contentsOf:nativeDir.appendingPathComponent("manifest.jsonl"),encoding:.utf8)
        precondition(manifest.split(separator:"\n").count==8)
        let names=try FileManager.default.contentsOfDirectory(atPath:nativeDir.path)
        precondition(!names.contains{$0.hasPrefix(".devmcp-")})
        // Source changes between response and publication cannot commit bytes.
        let staleDir=nativeRoot.appendingPathComponent("stale")
        try FileManager.default.createDirectory(at:staleDir,withIntermediateDirectories:true)
        var sourceCurrent=true
        let staleJob=try DevMCPDownload(urls:[urls[4]],dir:staleDir,filesRoot:nativeRoot,owner:browserManagerMarker,canPublish:{sourceCurrent}) {_,dir in
            let temporary=dir.appendingPathComponent(".devmcp-stale")
            try Data("old-profile".utf8).write(to:temporary)
            await MainActor.run{sourceCurrent=false}
            return .init(temporary:DevMCPTemporaryFile(url:temporary,directoryDescriptor:open(dir.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC)),status:"ok",httpStatus:200,contentType:"text/plain",bytes:11)
        }
        await staleJob.run()
        precondition(staleJob.progress.finished && staleJob.progress.counts.isEmpty)
        await drain()
        let staleNames=try FileManager.default.contentsOfDirectory(atPath:staleDir.path)
        precondition(staleNames.isEmpty)
        // A directory switched to a symlink is rejected before publication.
        let replaced=nativeRoot.appendingPathComponent("replaced")
        try FileManager.default.createSymbolicLink(at:replaced,withDestinationURL:outside)
        do {
            let rejectedJob=try DevMCPDownload(urls:[urls[4]],dir:replaced,filesRoot:nativeRoot,owner:browserManagerMarker,canPublish:{true}) {_,_ in preconditionFailure("followed substituted directory")}
            await rejectedJob.run();preconditionFailure("substituted directory admitted")
        } catch is POSIXError {}
        // Two jobs for the same actual owner await existing batch tasks, not
        // native per-file refusal or a second scheduling registry.
        let orderedDir=nativeRoot.appendingPathComponent("ordered")
        try FileManager.default.createDirectory(at:orderedDir,withIntermediateDirectories:true)
        let orderedTransport=NativeFileFixture()
        let firstJob=try DevMCPDownload(urls:Array(urls[2...7]),dir:orderedDir,filesRoot:nativeRoot,owner:browserManagerMarker,canPublish:{true},nativeFetch:{try await orderedTransport.fetch($0,$1)})
        let secondJob=try DevMCPDownload(urls:Array(urls[2...7]),dir:orderedDir,filesRoot:nativeRoot,owner:browserManagerMarker,canPublish:{true},nativeFetch:{try await orderedTransport.fetch($0,$1)})
        let firstBatch=firstJob.start(),secondBatch=secondJob.start(after:[firstBatch])
        await firstBatch.value;await secondBatch.value
        let orderedPeak=await orderedTransport.peak
        precondition(orderedPeak==6 && firstJob.progress.counts["ok"]==4 && secondJob.progress.counts["exists"]==4)
        let normalDir=nativeRoot.appendingPathComponent("normal-predecessor")
        try FileManager.default.createDirectory(at:normalDir,withIntermediateDirectories:true)
        let heldTransport=NativeFileFixture(hold:true)
        let predecessor=try DevMCPDownload(urls:Array(urls[2...7]),dir:normalDir,filesRoot:nativeRoot,owner:browserManagerMarker,canPublish:{true},nativeFetch:{try await heldTransport.fetch($0,$1)})
        let normal=predecessor.start()
        for await _ in heldTransport.ready.stream {break}
        let cancelledFollower=try DevMCPDownload(urls:[urls[4]],dir:normalDir,filesRoot:nativeRoot,owner:browserManagerMarker,canPublish:{true}) {_,_ in preconditionFailure("cancelled follower started after normal predecessor")}
        let follower=cancelledFollower.start(after:[normal]);cancelledFollower.cancel()
        await heldTransport.release();await normal.value;await follower.value
        precondition(predecessor.progress.counts["ok"]==4 && cancelledFollower.progress.counts.isEmpty)
        let cancelDir=nativeRoot.appendingPathComponent("cancel-stream")
        try FileManager.default.createDirectory(at:cancelDir,withIntermediateDirectories:true)
        let started=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingOldest(6))
        let cancellable=try DevMCPDownload(urls:Array(urls[2...7]),dir:cancelDir,filesRoot:nativeRoot,owner:browserManagerMarker,canPublish:{true}) {_,_ in
            started.continuation.yield(())
            try await Task.sleep(for:.seconds(60))
            preconditionFailure("cancelled native request resumed")
        }
        let running=cancellable.start()
        var entered=0
        for await _ in started.stream {entered+=1;if entered==6{break}}
        await cancellable.waitForCompletion(seconds:0.001)
        precondition(!cancellable.progress.finished)
        let queued=try DevMCPDownload(urls:[urls[4]],dir:cancelDir,filesRoot:nativeRoot,owner:browserManagerMarker,canPublish:{true}) {_,_ in preconditionFailure("cancelled queued job dispatched")}
        let queuedTask=queued.start(after:[running]);queued.cancel()
        precondition(!cancellable.progress.finished)
        cancellable.cancel();await running.value;await queuedTask.value
        started.continuation.finish()
        precondition(cancellable.progress.finished && cancellable.progress.counts.isEmpty && queued.progress.counts.isEmpty)
        // Replace the directory after receiving an owned descriptor. Cleanup
        // must remove the original entry, never the replacement's same name.
        let swap=nativeRoot.appendingPathComponent("swap"),moved=nativeRoot.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at:swap,withIntermediateDirectories:true)
        var checks=0
        let swapped=try DevMCPDownload(urls:[urls[4]],dir:swap,filesRoot:nativeRoot,owner:browserManagerMarker,canPublish:{
            checks+=1
            if checks==1 {
                try! FileManager.default.moveItem(at:swap,to:moved)
                try! FileManager.default.createDirectory(at:swap,withIntermediateDirectories:true)
                try! Data("replacement".utf8).write(to:swap.appendingPathComponent(".devmcp-original"))
            }
            return true
        }) {_,dir in
            let temporary=dir.appendingPathComponent(".devmcp-original")
            try Data("owned".utf8).write(to:temporary)
            return .init(temporary:DevMCPTemporaryFile(url:temporary,directoryDescriptor:open(dir.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC)),status:"ok",httpStatus:200,contentType:"text/plain",bytes:5)
        }
        await swapped.run();await drain()
        let rivalBytes=try String(contentsOf:swap.appendingPathComponent(".devmcp-original"),encoding:.utf8)
        precondition(rivalBytes=="replacement" && swapped.progress.counts.isEmpty)
        let movedFiles=try FileManager.default.contentsOfDirectory(atPath:moved.path)
        precondition(movedFiles.isEmpty)
        print("Native download job:6-stream bound,HTTP refusal,manifest/naming,no overwrite,tooLarge,source/directory rejection and temp cleanup passed")
        let server = DevMCPServer()
        let browser = BrowserManager()
        let unconfigured = DevMCPServer()
        unconfigured.configure(browserManager: browser, enabled: true)
        precondition(NWListener.latest == nil, "the server must not bind or use a legacy path without Bark configuration")
        unconfigured.shutdown()
        let legacy = root.appendingPathComponent("Downloads/Nook MCP", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let legacyFile = legacy.appendingPathComponent("existing.json")
        try Data("existing output".utf8).write(to: legacyFile)
        precondition(configuration.resolve(legacyFile.path) == nil)
        precondition(configuration.resolve("../../../Downloads/Nook MCP/existing.json") == nil)
        precondition(server.setConfiguration(configuration))
        server.configure(browserManager: browser, enabled: false)
        precondition(NWListener.latest == nil)
        for developer in [false, true] { for control in [false, true] {
            browser.nookSettings!.developerModeEnabled = developer
            browser.nookSettings!.browserControlServerEnabled = control
            server.applyEnabledSetting(true)
            if !(developer && control) { precondition(NWListener.latest == nil) }
        } }
        let first = NWListener.latest!
        let handshake = NWConnection()
        first.newConnectionHandler!(handshake)
        await drain()
        let initialize = #"{"id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
        handshake.deliver(Data("POST /mcp HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(initialize.utf8.count)\r\n\r\n\(initialize)".utf8))
        await drain()
        let response = handshake.lastResponse.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let jsonStart = response.range(of: "\r\n\r\n")!.upperBound
        let envelope = try JSONSerialization.jsonObject(with: Data(response[jsonStart...].utf8)) as! [String: Any]
        let result = envelope["result"] as! [String: Any]
        precondition((result["serverInfo"] as? [String: String]) == ["name": "bark-dev", "version": "1"])
        precondition(result["protocolVersion"] as? String == "2025-06-18")
        let instructions = result["instructions"] as? String ?? ""
        precondition(instructions.contains("Browser Control is enabled") && !instructions.contains("Debug build"))
        let unchanged = try Data(contentsOf: legacyFile)
        precondition(unchanged == Data("existing output".utf8))
        let otherConfiguration = try DevMCPConfiguration.native(appRoot: outside)
        precondition(!server.setConfiguration(otherConfiguration))
        let connection = NWConnection()
        first.newConnectionHandler!(connection)
        await drain()
        let body = #"{"id":1,"method":"tools/call","params":{"name":"reload"}}"#
        let request = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.deliver(Data(request.utf8))
        await drain()
        precondition(TestTools.started == 1)
        server.stop()
        await drain()
        precondition(connection.wasCancelled && connection.sends == 0)
        precondition(TestTools.cancelled == 1 && browser.tabs.agentCallsInFlight == 0)
        server.applyEnabledSetting(true)
        let late = NWConnection()
        first.newConnectionHandler!(late)
        await drain()
        precondition(late.wasCancelled)
        let fresh = NWConnection()
        NWListener.latest!.newConnectionHandler!(fresh)
        await drain()
        fresh.deliver(Data("POST /mcp HTTP/1.1\r\nAuthorization: Bearer wrong\r\nContent-Length: 0\r\n\r\n".utf8))
        await drain()
        precondition(fresh.sends == 1 && TestTools.started == 1)
        server.shutdown()
        let listenerBeforeShutdown = NWListener.latest
        server.applyEnabledSetting(true)
        precondition(NWListener.latest === listenerBeforeShutdown, "shutdown must revoke settings-only restart")
        server.configure(browserManager: browser, enabled: true)
        precondition(NWListener.latest !== listenerBeforeShutdown)
        let gated = NWConnection()
        NWListener.latest!.newConnectionHandler!(gated)
        await drain()
        browser.nookSettings!.developerModeEnabled = false
        gated.deliver(Data(request.utf8))
        await drain()
        precondition(gated.sends == 1 && TestTools.started == 1, "permission removal precedes settings observation")
        server.shutdown()
        let jobDirectory = root.appendingPathComponent("cancelled-job")
        let job = DevMCPDownload(urls: [URL(string: "https://invalid.example/no-request")!], dir: jobDirectory,
                                 cookies: [], userAgent: nil, referer: nil)
        job.cancel()
        await job.run()
        precondition(job.progress.finished && !FileManager.default.fileExists(atPath: jobDirectory.path))
        // Existing insecure/symlink tokens fail closed; never fall back to a global token.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configuration.tokenFile.path)
        do { _ = try configuration.loadOrCreateToken(); preconditionFailure("accepted public token") } catch {}
        try FileManager.default.removeItem(at: configuration.tokenFile)
        try FileManager.default.createSymbolicLink(at: configuration.tokenFile, withDestinationURL: outside.appendingPathComponent("token"))
        do { _ = try configuration.loadOrCreateToken(); preconditionFailure("accepted symlink") } catch {}
        print("PASS: permissions, synthetic isolation/App symlink rejection, nonblocking cancelled writes/exclusive publication, stop/restart and stale admission")
    }
}
