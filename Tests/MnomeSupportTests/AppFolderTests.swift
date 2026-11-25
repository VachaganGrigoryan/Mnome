import XCTest
@testable import MnomeSupport

final class AppFolderTests: XCTestCase {
    private let apps = [("/A/Calculator.app", "Calculator"), ("/A/Utilities/Terminal.app", "Terminal"), ("/A/Utilities/Disk Utility.app", "Disk Utility"), ("/A/Safari.app", "Safari"), ("/A/Notes.app", "Notes")].map { (id: $0.0, name: $0.1) }
    func testFoldersSitAmongAppsByNameAndHideTheirApps() {
        let folders = AppFolders.seed(apps: apps.map(\.id))
        XCTAssertEqual(folders.map(\.name), ["Utilities"])
        XCTAssertEqual(AppFolders.entries(apps: apps, folders: folders).map(\.id), ["/A/Calculator.app", "/A/Notes.app", "/A/Safari.app", "folder:utilities"])
    }
    func testAFolderOfOneInstalledAppIsNotShown() {
        let folders = [AppFolder(id: "f", name: "Old", apps: ["/A/Notes.app", "/gone/Deleted.app"])]
        XCTAssertFalse(AppFolders.entries(apps: apps, folders: folders).contains { if case .folder = $0 { true } else { false } })
        XCTAssertTrue(AppFolders.entries(apps: apps, folders: folders).contains(.app("/A/Notes.app")))
    }
    func testMakeAddRemoveAndRename() {
        var folders = AppFolders.make("/A/Notes.app", "/A/Safari.app", id: "n", in: [])
        XCTAssertEqual(folders, [AppFolder(id: "n", name: "Unnamed Folder", apps: ["/A/Safari.app", "/A/Notes.app"])])
        folders = AppFolders.add("/A/Calculator.app", to: "n", in: folders)
        XCTAssertEqual(folders.first?.apps.last, "/A/Calculator.app")
        folders = AppFolders.make("/A/Calculator.app", "/A/Utilities/Terminal.app", id: "m", in: folders)
        XCTAssertEqual(folders.first { $0.id == "n" }?.apps, ["/A/Safari.app", "/A/Notes.app"], "taken out of the first folder")
        folders = AppFolders.remove("/A/Notes.app", in: folders)
        XCTAssertNil(folders.first { $0.id == "n" }, "down to one app, the folder is gone")
        XCTAssertEqual(AppFolders.rename("m", to: "  Tools ", in: folders).first?.name, "Tools")
        XCTAssertEqual(AppFolders.rename("m", to: "  ", in: folders).first?.name, "Unnamed Folder", "an empty name keeps the old one")
        XCTAssertEqual(AppFolders.make("/A/Notes.app", "/A/Notes.app", id: "x", in: folders), folders)
    }
    func testTheStoreSeedsOnceAndRoundTrips() {
        let defaults = UserDefaults(suiteName: "mnome-folders-\(UUID())")!, store = AppFolderStore(defaults: defaults)
        XCTAssertEqual(store.load { [AppFolder(id: "s", name: "Seed", apps: ["a", "b"])] }.map(\.id), ["s"])
        store.save([])
        XCTAssertEqual(store.load { [AppFolder(id: "s", name: "Seed", apps: ["a", "b"])] }, [], "emptied by the person, it stays empty")
    }
}
