// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+Translate.swift
//  Nook
//
//  Whole-page translation with the Translation framework on the Mac, or with the AI model chosen
//  in Settings (AIPageTranslation.swift). Chromium owns document sampling and text replacement.
//

import Foundation
import Translation

extension PageSession {
    /// Hosts that got "Not Now" this session.
    private static var declinedTranslationHosts: Set<String> = []
    private static let minimumTextForOffer = 200
    private static let translationBatchSize = AIPageTranslation.batchSize

    /// An ordinary web page that is not a PDF.
    public var canTranslate: Bool {
        guard navigation?.supportsTranslation == true, navigation?.state.isLoading == false,
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The one entry point for menus and the palette: translate, or show the original.
    public func toggleTranslation() {
        if isTranslated { showOriginal() }
        else {
            let generation = translationGeneration, page = navigation
            Task {
                guard generation == translationGeneration, navigation === page else { return }
                await translatePage()
            }
        }
    }

    public func showOriginal() {
        resetTranslation()
        let generation = translationGeneration, page = navigation
        Task {
            guard generation == translationGeneration, navigation === page else { return }
            _ = await callTranslateScript("restore()")
        }
    }

    public func declineTranslationOffer() {
        if let host = url.host?.lowercased() { Self.declinedTranslationHosts.insert(host) }
        translationOffer = nil
    }

    public func dismissTranslationNotice() {
        translationNotice = nil
    }

    /// Ends any translation in flight. The page's text stays as it is.
    func resetTranslation() {
        translationGeneration &+= 1
        navigation?.onTranslationNodes = nil
        translationFeed?.finish()
        translationFeed = nil
        translationBacklog = []
        installedTranslation?.cancel()
        installedTranslation = nil
        aiTranslationWork?.cancel()
        aiTranslationWork = nil
        aiTranslator = nil
        translationRequest = nil
        translationOffer = nil
        translationNotice = nil
        translationSource = nil
        isTranslated = false
    }

    // MARK: - Offer

    /// After a main-frame load: reads a 2 KB sample and offers translation when the page is
    /// in another language the system can translate.
    func offerTranslationIfNeeded() {
        guard canTranslate, !isTranslated,
              let host = url.host?.lowercased(), !Self.declinedTranslationHosts.contains(host)
        else { return }
        let generation = translationGeneration
        Task {
            guard let source = await detectSourceLanguage(minimumLength: Self.minimumTextForOffer),
                  generation == translationGeneration,
                  PageLanguage.needsTranslation(source, into: PageLanguage.reader)
            else { return }
            let status = await LanguageAvailability().status(from: source, to: PageLanguage.reader)
            guard status != .unsupported, generation == translationGeneration, !isTranslated else { return }
            translationSource = source
            translationOffer = source
        }
    }

    // MARK: - Translate

    private func translatePage() async {
        guard canTranslate, !isTranslated else { return }
        let generation = translationGeneration
        let target = PageLanguage.reader
        var source = translationSource
        if source == nil { source = await detectSourceLanguage(minimumLength: 1) }
        guard let source, generation == translationGeneration,
              PageLanguage.needsTranslation(source, into: target)
        else { return }
        let status = await LanguageAvailability().status(from: source, to: target)
        guard generation == translationGeneration, !isTranslated else { return }
        translationOffer = nil
        let onDeviceSupported = status == .installed || status == .supported
        let engine = TranslationEngineChoice.choose(controller?.pageTranslation?(), isPrivate: isPrivate)
        if case .ai(let model) = engine {
            aiTranslator = AIPageTranslator(
                model: model,
                context: AITranslationContext(target: target, source: source, title: title, host: url.host ?? ""),
                cache: profile.flatMap { controller?.translationCaches.cache(forProfile: $0.id, isPrivate: isPrivate || $0.isEphemeral) },
                onNotice: { [weak self] notice in
                    guard let self, generation == self.translationGeneration else { return }
                    self.showTranslationNotice(notice)
                }
            )
        } else if !onDeviceSupported {
            return
        }
        isTranslated = true
        if case .onDeviceInstead(let reason) = engine {
            translationNotice = .aiFailed(reason: reason, onDevice: true)
        }
        if !onDeviceSupported {
            installedTranslation = Task { await runTranslation(onDevice: nil) }
        } else if status == .installed, #available(macOS 26, iOS 26, *) {
            let session = TranslationSession(installedSource: source, target: target)
            installedTranslation = Task { await runTranslation(with: session) }
        } else {
            // The host view's .translationTask hands back a session that can show the download
            // sheet; Sequoia has no other way to make one.
            translationRequest = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func showTranslationNotice(_ notice: PageTranslationNotice) {
        if case .aiLimitReached = notice, translationNotice != nil { return }
        translationNotice = notice
    }

    /// Translates the page's text, then whatever the page adds, until the translation is reset or
    /// the caller's task ends. Safe to call again for the same page: only untranslated text is sent.
    public func runTranslation(with translator: TranslationSession) async {
        await runTranslation(onDevice: translator)
    }

    /// `translator` is nil when the AI engine translates a language pair Apple cannot.
    func runTranslation(onDevice translator: TranslationSession?) async {
        let generation = translationGeneration
        guard isTranslated else { return }
        let (stream, feed) = AsyncStream.makeStream(of: [[String: Any]].self, bufferingPolicy: .bufferingOldest(4))
        translationFeed?.finish()
        // start() streams the bounded initial document before replying. Stage
        // those batches before the translator starts consuming the stream.
        translationFeed = nil
        let first = await callTranslateScript("start()") as? [[String: Any]]
        guard !Task.isCancelled, generation == translationGeneration, isTranslated else {
            feed.finish()
            return
        }
        guard let first, appendNativeTranslationBacklog(first) else {
            feed.finish()
            showOriginal()
            return
        }
        let initial = translationBacklog
        translationBacklog = []
        translationFeed = feed
        feed.yield(initial)

        for await nodes in stream {
            guard generation == translationGeneration, !Task.isCancelled else { return }
            if let aiTranslator {
                await translate(nodes.compactMap(TranslationNode.init), with: aiTranslator, onDevice: translator, generation: generation)
                continue
            }
            guard let translator else { return }
            let requests = nodes.compactMap { node -> TranslationSession.Request? in
                guard let id = node["id"] as? String, let text = node["text"] as? String else { return nil }
                return TranslationSession.Request(sourceText: text, clientIdentifier: id)
            }
            for start in stride(from: 0, to: requests.count, by: Self.translationBatchSize) {
                let batch = Array(requests[start..<min(start + Self.translationBatchSize, requests.count)])
                do {
                    let responses = try await translator.translations(from: batch)
                    guard generation == translationGeneration, !Task.isCancelled else { return }
                    let pairs = responses.compactMap { response in
                        response.clientIdentifier.map { [$0, response.targetText] }
                    }
                    _ = await callTranslateScript("apply(pairs)", arguments: ["pairs": pairs])
                } catch {
                    // Cancelled download sheet, missing model, or the task ended: put the page back.
                    guard generation == translationGeneration, !Task.isCancelled else { return }
                    Self.log.error("Translation failed: \(error.localizedDescription, privacy: .public)")
                    showOriginal()
                    return
                }
            }
        }
    }

    /// Sends `nodes` through the AI engine, with `translator` for the batches the model fails on.
    private func translate(_ nodes: [TranslationNode], with ai: AIPageTranslator, onDevice translator: TranslationSession?, generation: Int) async {
        var onDevice: AIPageTranslator.Translate?
        if let translator {
            onDevice = { batch in
                let responses = try await translator.translations(from: batch.map {
                    TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
                })
                return Dictionary(responses.compactMap { response in response.clientIdentifier.map { ($0, response.targetText) } },
                                  uniquingKeysWith: { first, _ in first })
            }
        }
        let work = Task {
            await ai.translate(nodes, onDevice: onDevice) { [weak self] pairs in
                guard let self, generation == self.translationGeneration, !Task.isCancelled else { return }
                _ = await self.callTranslateScript("apply(pairs)", arguments: ["pairs": pairs.map { [$0.id, $0.text] }])
            }
        }
        aiTranslationWork = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    // MARK: - Script

    private func detectSourceLanguage(minimumLength: Int) async -> Locale.Language? {
        guard let sample = await callTranslateScript("sample()") as? [String: Any],
              let text = sample["text"] as? String, text.count >= minimumLength
        else { return nil }
        return PageLanguage.detect(sample: text, declared: sample["lang"] as? String)
    }

    /// Matches the renderer's retained-original limits, including UTF-16
    /// accounting; UTF-8 would reject supported non-ASCII documents early.
    private func appendNativeTranslationBacklog(_ batch: [[String: Any]]) -> Bool {
        // start() replays unapplied originals, including packets queued while
        // this page was hidden. Merge by document-stable id; retain new nodes.
        var ids = Set(translationBacklog.compactMap { $0["id"] as? String })
        let added = batch.filter { node in
            guard let id = node["id"] as? String else { return false }
            return ids.insert(id).inserted
        }
        let characters = translationBacklog.reduce(0) {
            $0 + (($1["text"] as? String)?.utf16.count ?? 0)
        } + added.reduce(0) {
            $0 + (($1["text"] as? String)?.utf16.count ?? 0)
        }
        guard translationBacklog.count + added.count <= 4096,
              characters <= 2 * 1024 * 1024 else { return false }
        translationBacklog += added
        return true
    }

    /// Sends one translation command to the current document's native owner.
    func callTranslateScript(_ call: String, arguments: [String: Any] = [:]) async -> Any? {
        guard let page = navigation, page.supportsTranslation else { return nil }
        let command: PageTranslationCommand
        switch call {
        case "sample()": command = .sample
        case "start()": command = .start
        case "restore()": command = .restore
        case "apply(pairs)":
            guard let pairs = arguments["pairs"] as? [[String]], pairs.count <= 128,
                  pairs.allSatisfy({ $0.count == 2 }) else { return nil }
            command = .apply(pairs.map { PageTranslationNode(id: $0[0], text: $0[1]) })
        default: return nil
        }
        let generation = translationGeneration
        if call == "start()" {
            page.onTranslationNodes = { [weak self, weak page] nodes in
                guard let self, let page, self.navigation === page,
                      generation == self.translationGeneration, self.isTranslated else { return }
                guard let nodes else { self.showOriginal(); return }
                guard nodes.count <= 128,
                      nodes.reduce(0, { $0 + $1.id.utf8.count + $1.text.utf8.count }) <= 512 * 1024 else {
                    self.showOriginal(); return
                }
                let batch = nodes.map { ["id": $0.id, "text": $0.text] }
                if let feed = self.translationFeed {
                    switch feed.yield(batch) {
                    case .enqueued: return
                    case .dropped: self.showOriginal(); return
                    case .terminated: break
                    @unknown default: self.showOriginal(); return
                    }
                }
                if !self.appendNativeTranslationBacklog(batch) { self.showOriginal() }
            }
        }
        let result = await withCheckedContinuation { continuation in
            if !page.translate(command, completion: { continuation.resume(returning: $0) }) {
                continuation.resume(returning: nil)
            }
        }
        guard navigation === page, generation == translationGeneration,
              let result else { return nil }
        if call == "sample()" { return ["text": result.text, "lang": result.lang] }
        return result.nodes.map { ["id": $0.id, "text": $0.text] }
    }
}
