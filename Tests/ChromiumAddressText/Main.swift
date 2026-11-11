// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped rule verbatim.
import Foundation

@main enum Check {
    static func main() {
        func shown(_ string: String, developer: Bool = false) -> String { URLBarView.shownPath(of: URL(string: string)!, developerPage: developer) }
        precondition(shown("https://github.com/nook/pulls?q=open") == "", "a page shows its host alone, as Arc's address does")
        precondition(shown("https://github.com/") == "")
        precondition(shown("http://localhost:3000/checkout?step=2", developer: true) == "/checkout?step=2", "a developer's own server keeps its path and query")
        precondition(shown("http://localhost:3000/checkout", developer: true) == "/checkout")
        precondition(shown("http://localhost:3000/", developer: true) == "", "nor a bare slash")
        precondition(shown("http://localhost:3000/?step=2", developer: true) == "/?step=2", "the slash stays before a query")
        precondition(shown("about:blank", developer: true) == "", "nothing after a page with no host")
        print("Address: a page shows its host alone; a developer's server keeps its path and query")
    }
}
