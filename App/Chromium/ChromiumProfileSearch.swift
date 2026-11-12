// Licensed under GPL-3.0. See LICENSE.
import BarcChromium
import Foundation
import NookWeb

/// Borrowed callback contexts only; no provider/profile cache or registry.
@MainActor
struct ChromiumProfileSearch {
    let bridge: BarcBridge
    private final class Request {
        let completion: @MainActor (Int32, String) -> Void
        init(_ completion: @escaping @MainActor (Int32, String) -> Void) { self.completion = completion }
    }
    func read(profile: UUID, page: PageSession?, seed: @escaping @MainActor () -> String?,
              selection: String?, includeChoices: Bool,
              completion: @escaping @MainActor (Result<ProfileSearchState, Error>) -> Void) {
        let native = page?.navigation as? ChromiumPageNavigation
        if let page, page.isPrivate, native == nil {
            completion(.failure(ProfileSearchError.unavailable)); return
        }
        guard native == nil || native?.profileID == profile else {
            completion(.failure(ProfileSearchError.unavailable)); return
        }
        let command = bridge.profile_search_state
        let owner = native?.nativeWindowID ?? 0
        let kind: Int32 = native?.isPrivateSession == true ? 1 : 0
        func run(_ imported: String?, retry: Bool) {
            let request = Request { status, json in
                if status == BARC_SEARCH_NEEDS_SEED.rawValue && !retry, let initial = seed() {
                    // Native asks only for an uninitialized fallback provider.
                    // Every retry keeps the original exact owner and identity.
                    run(initial, retry: true); return
                }
                guard status == BARC_SEARCH_OK.rawValue,
                      let value = try? JSONDecoder().decode(ProfileSearchState.self, from: Data(json.utf8)) else {
                    completion(.failure(ProfileSearchError.refused)); return
                }
                completion(.success(value))
            }
            let context = Unmanaged.passRetained(request).toOpaque()
            profile.uuidString.lowercased().withCString { uuid in
                func invoke(_ seed: UnsafePointer<CChar>?, _ selection: UnsafePointer<CChar>?) {
                    command(uuid, owner, kind, seed, selection, includeChoices ? 1 : 0, { context, status, json in
                        MainActor.assumeIsolated {
                            guard let context else { return }
                            let request = Unmanaged<Request>.fromOpaque(context).takeRetainedValue()
                            request.completion(status, json.map { String(cString: $0) } ?? "")
                        }
                    }, context)
                }
                func selecting(_ selected: UnsafePointer<CChar>?) {
                    if let imported { imported.withCString { invoke($0, selected) } }
                    else { invoke(nil, selected) }
                }
                if let selection { selection.withCString(selecting) } else { selecting(nil) }
            }
        }
        run(nil, retry: false)
    }
}
