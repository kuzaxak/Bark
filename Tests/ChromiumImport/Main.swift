// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped importers and writes Arc and Dia fixtures; nothing here reads a real browser's data.
import Foundation

@main enum Check {
    static func main() async {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let sources = ImportManager.Sources.fixtures(in: root)
        for url in [sources.arc, sources.dia] {
            precondition(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"), "a verification run reads only under its own data directory: \(url.path)")
        }
        let importer = ImportManager(sources: sources)

        let arc = await importer.importArcSidebarData()
        precondition(arc.spaces.map(\.title) == ["Fixture Space"], "Arc's spaces come in: \(arc.spaces.map(\.title))")
        let space = arc.spaces[0]
        precondition(space.emoji == "🧪" && space.accentHex != nil, "with their icon and colour")
        precondition(space.pinned == [.tab(url: "https://fixture.test/pinned", title: "Pinned", customTitle: "Mine"),
                                      .folder(title: "Reading", children: [.tab(url: "https://fixture.test/read", title: "Read", customTitle: nil)])],
                     "pinned tabs and folders in order: \(space.pinned)")
        precondition(space.unpinned == [.tab(url: "https://fixture.test/today", title: "Today", customTitle: nil)], "and Today's tabs")
        precondition(arc.favorites["default"] == [.tab(url: "https://fixture.test/favorite", title: "Favorite", customTitle: nil)], "and the profile's favorites")
        precondition(arc.profileNames["default"] == "Fixture Person", "the profile keeps Arc's name")

        let dia = await importer.importDiaData()
        precondition(dia.favoriteTabs.map(\.url) == ["https://fixture.test/dia-favorite"] && dia.windowTabs.map(\.url) == ["https://fixture.test/dia-window"],
                     "Dia's favorites and window tabs come in")

        let empty = ImportManager(sources: .fixtures(in: root.appendingPathComponent("nothing")))
        let nothing = await empty.importArcSidebarData(), noDia = await empty.importDiaData()
        precondition(nothing.spaces.isEmpty && noDia.windowTabs.isEmpty, "a source with nothing in it imports nothing")
        let tabs = root.appendingPathComponent("App/Tabs", isDirectory: true)
        try? FileManager.default.createDirectory(at: tabs, withIntermediateDirectories: true)
        func files() -> Set<String> {
            Set((FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? [])
        }
        let before = files()
        importer.saveArcMembershipCard(nextTo: tabs)
        let card = root.appendingPathComponent("App/ArcMembershipCard.json")
        let saved = (try? Data(contentsOf: card)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        precondition(saved?["memberNumber"] as? Int == 42 && saved?["name"] as? String == "Fixture Member",
                     "Arc's member card, with the person's Arc name, lands beside the run's tabs")
        precondition(files().subtracting(before) == ["App/ArcMembershipCard.json"], "and nothing else is written in the run")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in ["ee.qdo.bark", "Nook"] {
            precondition(!FileManager.default.fileExists(atPath: support.appendingPathComponent(name).appendingPathComponent("ArcMembershipCard.json").path),
                         "nor in Application Support's \(name) folder")
        }
        print("Import: Arc and Dia come in from the source the importer is given, and Arc's member card stays in the run")
    }
}
