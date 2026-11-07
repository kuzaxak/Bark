import BarcChromium
import Darwin
import Foundation

struct ChromiumDownloadAPI {
    typealias Observe = @convention(c) (BarcDownloadCallback?, UnsafeMutableRawPointer?) -> UInt64
    typealias Unobserve = @convention(c) (UInt64) -> Void
    typealias Action = @convention(c) (UInt64, UInt64, UnsafePointer<CChar>?, Int32) -> Int32
    typealias Target = @convention(c) (UInt64, UInt64, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int
    let observe: Observe
    let unobserve: Unobserve
    let action: Action
    let target: Target

    init(library: UnsafeMutableRawPointer) throws {
        func load<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(library, name) else { throw ChromiumNavigationError.missingSymbol(name) }
            return unsafeBitCast(address, to: T.self)
        }
        observe = try load("barc_downloads_observe", Observe.self)
        unobserve = try load("barc_downloads_unobserve", Unobserve.self)
        action = try load("barc_download_action", Action.self)
        target = try load("barc_download_copy_safe_target", Target.self)
    }
    init(observe: @escaping Observe, unobserve: @escaping Unobserve,
         action: @escaping Action, target: @escaping Target) {
        self.observe = observe; self.unobserve = unobserve; self.action = action; self.target = target
    }
}

/// Adapts one existing Chromium download subscription into the existing model.
/// It neither chooses destinations nor owns download/history/profile objects.
@MainActor
final class ChromiumDownloads {
    private let api: ChromiumDownloadAPI
    private weak var manager: DownloadManager?
    private var observation: UInt64 = 0
    private var active = false

    init(api: ChromiumDownloadAPI) { self.api = api }

    func start(manager: DownloadManager) -> Bool {
        guard !active else { return self.manager === manager }
        self.manager = manager; active = true
        let token = api.observe({ context, token, event, snapshot in
            MainActor.assumeIsolated {
                guard let context, let snapshot else { return }
                Unmanaged<ChromiumDownloads>.fromOpaque(context).takeUnretainedValue()
                    .receive(token: token, event: event, snapshot: snapshot.pointee)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        guard active, token != 0 else {
            if token != 0 { api.unobserve(token) }
            active = false; self.manager = nil; return false
        }
        guard observation == 0 || observation == token else { stop(); api.unobserve(token); return false }
        observation = token
        return true
    }

    func stop() {
        let token = observation; observation = 0; active = false
        if token != 0 { api.unobserve(token) }
        manager?.stopNativeDownloads(observation: token); manager = nil
    }
    isolated deinit { if observation != 0 { api.unobserve(observation) } }

    private func receive(token: UInt64, event: Int32, snapshot: BarcDownloadSnapshot) {
        guard active, token != 0, observation == 0 || observation == token,
              let manager, let profile = snapshot.profile_uuid.flatMap({ UUID(uuidString: String(cString: $0)) }),
              snapshot.manager != 0 else { return }
        observation = token
        if event == BARC_DOWNLOAD_MANAGER_ENDED.rawValue {
            manager.nativeManagerEnded(snapshot.manager, observation: token); return
        }
        guard let guid = snapshot.guid.map({ String(cString: $0) }), !guid.isEmpty else { return }
        let identity = NativeDownloadIdentity(profileID: profile,
            isPrivate: snapshot.flags & UInt32(BARC_DOWNLOAD_PRIVATE.rawValue) != 0, guid: guid)
        if event == BARC_DOWNLOAD_REMOVED.rawValue {
            manager.removeNativeDownload(identity, manager: snapshot.manager, observation: token); return
        }
        guard event == BARC_DOWNLOAD_ITEM.rawValue,
              let url = snapshot.url.flatMap({ URL(string: String(cString: $0)) }) else { return }
        let state: Download.DownloadState
        switch snapshot.state {
        case Int32(BARC_DOWNLOAD_PROGRESS.rawValue): state = .downloading
        case Int32(BARC_DOWNLOAD_COMPLETE.rawValue): state = .completed
        case Int32(BARC_DOWNLOAD_CANCELLED.rawValue): state = .cancelled
        case Int32(BARC_DOWNLOAD_INTERRUPTED.rawValue): state = .failed
        default: return
        }
        let path = snapshot.target_path.map { String(cString: $0) } ?? ""
        let filename = snapshot.filename.map { String(cString: $0) } ?? "Download"
        let update = NativeDownloadUpdate(identity: identity, manager: snapshot.manager, observation: token, url: url,
            filename: filename.isEmpty ? "Download" : filename,
            target: path.isEmpty ? nil : URL(fileURLWithPath: path), state: state,
            unsafe: snapshot.flags & UInt32(BARC_DOWNLOAD_UNSAFE.rawValue) != 0,
            safeFile: snapshot.flags & UInt32(BARC_DOWNLOAD_SAFE_FILE.rawValue) != 0,
            received: max(0, snapshot.received_bytes), total: snapshot.total_bytes < 0 ? nil : snapshot.total_bytes,
            started: Date(timeIntervalSince1970: snapshot.started_unix), error: snapshot.error)
        let source = snapshot.manager
        manager.applyNativeDownload(update, action: { [weak self] remove in
            guard let self, self.active, self.observation == token else { return false }
            return guid.withCString { self.api.action(token, source, $0,
                Int32(remove ? BARC_DOWNLOAD_REMOVE.rawValue : BARC_DOWNLOAD_CANCEL.rawValue)) == 1 }
        }, safeTarget: { [weak self] in
            guard let self, self.active, self.observation == token else { return nil }
            return guid.withCString { guid in
                let required = self.api.target(token, source, guid, nil, 0)
                guard required > 1, required <= 1024 * 1024 else { return nil }
                var buffer = [CChar](repeating: 0, count: required)
                guard self.api.target(token, source, guid, &buffer, buffer.count) == required,
                      buffer.last == 0 else { return nil }
                guard let path = String(bytes: buffer.dropLast().map({ UInt8(bitPattern: $0) }), encoding: .utf8) else { return nil }
                return URL(fileURLWithPath: path)
            }
        })
        // Observation can be stopped by a synchronous model publication hook.
        // Remove only this delivery's row; a newer stream may already own it.
        if !active || observation != token {
            manager.removeNativeDownload(identity, manager: source, observation: token)
        }
    }
}
