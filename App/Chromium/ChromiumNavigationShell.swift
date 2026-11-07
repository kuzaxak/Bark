import NookWeb
import SwiftUI

/// Uses the existing page model and Chromium-owned document. The engine keeps
/// the web surface; this view supplies native navigation controls only.
struct ChromiumNavigationShell: View {
    @Bindable var page: PageSession
    @State private var address = ""
    @State private var addressEdited = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { page.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!page.canGoBack)
                    .accessibilityLabel("Back")
                Button { page.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!page.canGoForward)
                    .accessibilityLabel("Forward")
                Button { page.isLoading ? page.stop() : page.refresh() } label: {
                    Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
                }
                .accessibilityLabel(page.isLoading ? "Stop" : "Reload")
            }
            TextField("Address", text: Binding(
                get: { address },
                set: { address = $0; addressEdited = true }
            ))
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit {
                    page.navigate(to: address)
                    addressEdited = false
                    address = page.url.absoluteString
                }
                .accessibilityIdentifier("nook-chromium-address")
            Text(page.title).lineLimit(2)
            if page.isLoading { ProgressView().controlSize(.small) }
            Spacer()
        }
        .padding(12)
        .onAppear { address = page.url.absoluteString }
        .onChange(of: page.url) { _, url in
            if !addressFocused && !addressEdited { address = url.absoluteString }
        }
        .onChange(of: addressFocused) { _, focused in
            if !focused {
                addressEdited = false
                address = page.url.absoluteString
            }
        }
    }
}
