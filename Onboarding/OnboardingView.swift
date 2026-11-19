// Licensed under GPL-3.0. See LICENSE.
//
//  OnboardingView.swift
//  Nook
//
//  Created by Maciek Bagiński on 19/02/2026.
//

import NookDesign
import SwiftUI

struct OnboardingView: View {
    @Environment(\.nookSettings) var nookSettings
    @EnvironmentObject var browserManager: BrowserManager

    @State private var currentStage: Int = 0
    @State private var selectedBrowser: Browsers = .arc
    @State private var isLoading: Bool = false
    @State private var showSafariImportFlow: Bool = false

    private var session: BrowserImportSession { browserManager.importSession }

    var body: some View {
        ZStack {
            // A fixed dark backdrop: the stages draw white text. The old blur showed glass while
            // the window was key and plain white once it was not.
            NookDesign.Surface.onboardingBackdrop
                .overlay {
                    Image(.noiseTexture)
                        .resizable(resizingMode: .tile)
                        .opacity(NookDesign.Surface.grainOpacity)
                        .blendMode(.overlay)
                }
                .ignoresSafeArea()

            VStack {
                StageIndicator(stages: 3, activeStage: currentStage)
                Spacer()
                stageView
                    .transition(.slideAndBlur)
                Spacer()
                if !showSafariImportFlow {
                    StageFooter(
                        currentStage: currentStage,
                        totalStages: 3,
                        isLoading: isLoading || session.isRunning,
                        onContinue: advance,
                        onBack: goBack,
                        onSkip: skipImport,
                        onCancel: session.isRunning ? { session.stop() } : nil,
                        continueText: continueText
                    )
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            if !isLoading && !session.isRunning && !showSafariImportFlow {
                advance()
                return .handled
            }
            return .ignored
        }
    }

    private var continueText: String? {
        switch currentStage {
        case 1 where session.summary?.foundNothing == false: return "Continue"
        case 2: return "Start Browsing Locally"
        default: return nil
        }
    }

    @ViewBuilder
    private var stageView: some View {
        if showSafariImportFlow {
            SafariImportFlow(
                isLoading: $isLoading,
                onBack: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showSafariImportFlow = false
                    }
                },
                onComplete: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showSafariImportFlow = false
                        currentStage += 1
                    }
                }
            )
        } else {
            switch currentStage {
            case 0: HelloStage()
            case 1:
                if let summary = session.summary, !summary.foundNothing {
                    VStack(spacing: 24) {
                        Text("From \(summary.browser.name)")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                        BrowserImportResultView(summary: summary) { item in
                            browserManager.browserImporter(progress: session.progress).openWebStorePage(item)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: 480)
                    }
                } else {
                    VStack(spacing: 16) {
                        ImportStage(selectedBrowser: $selectedBrowser, message: session.summary?.nothingFoundMessage)
                        if session.isRunning, let browser = session.browser {
                            BrowserImportProgressView(browser: browser, progress: session.progress)
                                .foregroundStyle(.white)
                        }
                    }
                }
            case 2: FinalStage()
            default: EmptyView()
            }
        }
    }

    private func advance() {
        guard currentStage < 3 else { return }
        if currentStage == 2 {
            nookSettings.didFinishOnboarding = true
            return
        }

        if currentStage == 1 {
            switch OnboardingImportStep.next(choice: selectedBrowser, shown: session.summary) {
            case .moveOn:
                withAnimation(.easeInOut(duration: 0.25)) {
                    session.dismiss()
                    currentStage += 1
                }
            case .start(let browser):
                session.dismiss()
                browserManager.startImport(browser)
            case .safariFlow:
                session.dismiss()
                withAnimation(.easeInOut(duration: 0.25)) {
                    showSafariImportFlow = true
                }
            case .otherImport:
                session.dismiss()
                withAnimation(.easeInOut(duration: 0.25)) {
                    isLoading = true
                }
                performImport {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentStage += 1
                        isLoading = false
                    }
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                currentStage += 1
            }
        }
    }

    private func performImport(completion: @escaping () -> Void) {
        Task {
            if selectedBrowser == .dia { await browserManager.importDiaData() }
            await MainActor.run {
                completion()
            }
        }
    }

    private func skipImport() {
        withAnimation(.easeInOut(duration: 0.25)) {
            session.dismiss()
            currentStage = 2
        }
    }

    private func goBack() {
        guard currentStage > 0 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            currentStage -= 1
        }
    }

}
